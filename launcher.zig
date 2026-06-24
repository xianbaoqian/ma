// multi-account launcher — one engine, two roles.
//
// The invariant this whole program serves:
//   an isolated account = a set of env vars pointed at one directory, then exec the binary.
//
// Role 1, the KERNEL (`launch`): runs when invoked through a per-account symlink that is
//   named after the program, e.g. `claude-1-thorson/claude`. It derives the account from
//   its own invocation path, sets the program's config env var(s) to dirs inside that
//   folder, and execs the real binary. That is the invariant, executed.
//
// Role 2, the ADD-ONS (`dispatch`): runs when invoked by the engine's own name `ma`.
//   `ma new`, `ma ls`, and `ma PROGRAM NAME|ID ...` build, inspect, and reach the
//   structure the kernel runs on. They reuse the kernel's parse + manifest helpers.
//
// K&R discipline: smallest correct program, every fallible call checked, failures go to
// stderr with a precise line and a non-zero exit. Standard library only (Zig 0.16 Io API).

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const path = std.fs.path;

const Pair = struct { name: []const u8, dir: []const u8 };
const Program = struct { name: []const u8, binary: []const u8, pairs: []Pair };
const Parsed = struct { program: *const Program, id: u32, account: []const u8 };

// Globals set once in main, so helpers stay K&R-short instead of threading them everywhere.
var io: Io = undefined;
var gpa: Allocator = undefined;
var env: *std.process.Environ.Map = undefined;
// Install dir: where `ma` and programs.conf live. Account folders live here too, so the
// add-ons work from any cwd (e.g. when `ma` is aliased). Set once in loadManifest.
var root: []const u8 = undefined;

// ---- output / failure (write straight to fd 1/2; immune to std.io churn) ----

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "ma: " ++ fmt ++ "\n", args) catch "ma: error\n";
    std.Io.File.stderr().writeStreamingAll(io, s) catch {};
    std.process.exit(1);
}

fn join(parts: []const []const u8) []const u8 {
    return path.join(gpa, parts) catch fail("out of memory", .{});
}

// Canonical absolute path: resolve "." and ".." against cwd so the folder's
// basename is always the real PROGRAM-ID-ACCOUNT name (e.g. "." -> the cwd's name).
fn absolutize(p: []const u8) []const u8 {
    const cwd = std.process.currentPathAlloc(io, gpa) catch |e|
        fail("cannot read current directory: {s}", .{@errorName(e)});
    return path.resolve(gpa, &.{ cwd, p }) catch fail("out of memory", .{});
}

// ---- manifest ----

fn loadManifest() []Program {
    // MA_HOME, when set by the cross-platform polyglot wrapper, is the real install dir.
    // Without it (native binary run directly) we self-locate from our own exec path.
    root = if (env.get("MA_HOME")) |h| (gpa.dupe(u8, h) catch fail("out of memory", .{})) else std.process.executableDirPathAlloc(io, gpa) catch |e|
        fail("cannot find own path: {s}", .{@errorName(e)});
    const file = join(&.{ root, "programs.conf" });
    const data = Dir.cwd().readFileAlloc(io, file, gpa, .limited(1 << 20)) catch |e|
        fail("cannot read manifest '{s}': {s}", .{ file, @errorName(e) });

    var list: std.ArrayList(Program) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, line, '|');
        const name = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const binary = std.mem.trim(u8, fields.next() orelse
            fail("manifest line missing binary: '{s}'", .{line}), " \t");
        const pairs_field = std.mem.trim(u8, fields.next() orelse
            fail("manifest line missing VAR=dir pairs: '{s}'", .{line}), " \t");
        if (name.len == 0 or binary.len == 0)
            fail("manifest line has empty name or binary: '{s}'", .{line});

        var pairs: std.ArrayList(Pair) = .empty;
        var toks = std.mem.tokenizeScalar(u8, pairs_field, ' ');
        while (toks.next()) |tok| {
            const eq = std.mem.indexOfScalar(u8, tok, '=') orelse
                fail("manifest pair '{s}' is not VAR=dir (line: '{s}')", .{ tok, line });
            if (eq == 0 or eq == tok.len - 1)
                fail("manifest pair '{s}' has empty side (line: '{s}')", .{ tok, line });
            pairs.append(gpa, .{ .name = tok[0..eq], .dir = tok[eq + 1 ..] }) catch
                fail("out of memory", .{});
        }
        if (pairs.items.len == 0) fail("program '{s}' has no VAR=dir pairs", .{name});

        list.append(gpa, .{
            .name = name,
            .binary = binary,
            .pairs = pairs.toOwnedSlice(gpa) catch fail("out of memory", .{}),
        }) catch fail("out of memory", .{});
    }
    if (list.items.len == 0) fail("manifest is empty", .{});
    return list.toOwnedSlice(gpa) catch fail("out of memory", .{});
}

fn findProgram(programs: []Program, name: []const u8) ?*Program {
    for (programs) |*p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

fn knownList(programs: []Program) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    for (programs, 0..) |p, i| {
        if (i != 0) b.appendSlice(gpa, ", ") catch return "";
        b.appendSlice(gpa, p.name) catch return "";
    }
    return b.toOwnedSlice(gpa) catch "";
}

// PROGRAM = longest manifest entry that is a prefix followed by '-';
// ID = next '-'-segment, must be a base-10 integer; ACCOUNT = the remainder.
fn parse(programs: []Program, name: []const u8) Parsed {
    var best: ?*Program = null;
    for (programs) |*p| {
        if (name.len > p.name.len and std.mem.startsWith(u8, name, p.name) and name[p.name.len] == '-') {
            if (best == null or p.name.len > best.?.name.len) best = p;
        }
    }
    const p = best orelse
        fail("folder '{s}': no known program prefix (known: {s})", .{ name, knownList(programs) });

    const rest = name[p.name.len + 1 ..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse
        fail("folder '{s}': expected PROGRAM-ID-ACCOUNT", .{name});
    const id = std.fmt.parseInt(u32, rest[0..dash], 10) catch
        fail("folder '{s}': id '{s}' is not an integer", .{ name, rest[0..dash] });
    const account = rest[dash + 1 ..];
    if (account.len == 0) fail("folder '{s}': empty account name", .{name});
    return .{ .program = p, .id = id, .account = account };
}

// PATH search, skipping the account folder so we never re-exec our own symlink.
fn which(binary: []const u8, skip_dir: []const u8) ?[]const u8 {
    const p = env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, p, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or std.mem.eql(u8, dir, skip_dir)) continue;
        const cand = join(&.{ dir, binary });
        Dir.cwd().access(io, cand, .{ .execute = true }) catch continue;
        return cand;
    }
    return null;
}

// Replace this process image with argv (argv[0] must be an absolute/relative path,
// not a bare name, so PATH is not consulted). Never returns on success.
fn exec(argv: []const []const u8) noreturn {
    const e = std.process.replace(io, .{ .argv = argv, .environ_map = env });
    fail("exec '{s}' failed: {s}", .{ argv[0], @errorName(e) });
}

// ---- KERNEL ----

fn launch(programs: []Program, args: [][]const u8, argv0: []const u8, arg0base: []const u8) noreturn {
    if (std.mem.indexOfScalar(u8, argv0, '/') == null)
        fail("run the account launcher by path, e.g. ./claude-1-thorson/{s}", .{arg0base});

    const folder = absolutize(path.dirname(argv0).?);
    const fname = path.basename(folder);

    const p = parse(programs, fname);
    if (!std.mem.eql(u8, arg0base, p.program.name))
        fail("launcher '{s}' in folder '{s}' should be named '{s}'", .{ arg0base, fname, p.program.name });

    for (p.program.pairs) |pair|
        env.put(pair.name, join(&.{ folder, pair.dir })) catch fail("out of memory", .{});

    const real = which(p.program.binary, folder) orelse
        fail("binary '{s}' not found in PATH", .{p.program.binary});

    const argv = gpa.alloc([]const u8, args.len) catch fail("out of memory", .{});
    argv[0] = real;
    for (args[1..], 1..) |a, i| argv[i] = a;
    exec(argv);
}

// ---- ADD-ONS ----

// Visit every account folder for one program in the install dir.
fn forEachAccount(programs: []Program, prog: *const Program, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8, Parsed) void) void {
    var dir = Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e|
        fail("cannot open install dir '{s}': {s}", .{ root, @errorName(e) });
    var it = dir.iterate();
    while (it.next(io) catch |e| fail("cannot scan directory: {s}", .{@errorName(e)})) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, prog.name)) continue;
        if (entry.name.len <= prog.name.len or entry.name[prog.name.len] != '-') continue;
        const p = parse(programs, entry.name);
        if (p.program != prog) continue;
        f(ctx, entry.name, p);
    }
}

const RunFind = struct { key: []const u8, key_id: ?u32, matches: *std.ArrayList([]const u8) };

fn collectRun(ctx: *RunFind, name: []const u8, p: Parsed) void {
    const hit = if (ctx.key_id) |k| p.id == k else std.mem.eql(u8, p.account, ctx.key);
    if (hit) ctx.matches.append(gpa, gpa.dupe(u8, name) catch fail("out of memory", .{})) catch
        fail("out of memory", .{});
}

fn cmdRun(programs: []Program, progname: []const u8, key: []const u8, rest: [][]const u8) noreturn {
    const prog = findProgram(programs, progname) orelse
        fail("unknown program '{s}' (known: {s})", .{ progname, knownList(programs) });

    var matches: std.ArrayList([]const u8) = .empty;
    var find = RunFind{ .key = key, .key_id = std.fmt.parseInt(u32, key, 10) catch null, .matches = &matches };
    forEachAccount(programs, prog, &find, collectRun);

    if (matches.items.len == 0)
        fail("no account '{s}' for program '{s}' (try: ma ls)", .{ key, progname });
    if (matches.items.len > 1) {
        var b: std.ArrayList(u8) = .empty;
        for (matches.items) |m| {
            b.appendSlice(gpa, "\n  ") catch {};
            b.appendSlice(gpa, m) catch {};
        }
        fail("'{s} {s}' is ambiguous, matches:{s}", .{ progname, key, b.items });
    }

    // Hand off to the kernel via the per-account symlink; its (absolute) path tells the
    // kernel the folder, so this works regardless of the caller's cwd.
    const launcher = join(&.{ root, matches.items[0], prog.name });
    const argv = gpa.alloc([]const u8, 1 + rest.len) catch fail("out of memory", .{});
    argv[0] = launcher;
    for (rest, 1..) |a, i| argv[i] = a;
    exec(argv);
}

const NewFind = struct { account: []const u8, max_id: u32 = 0, existing: ?[]const u8 = null };

fn collectNew(ctx: *NewFind, name: []const u8, p: Parsed) void {
    if (p.id > ctx.max_id) ctx.max_id = p.id;
    if (std.mem.eql(u8, p.account, ctx.account))
        ctx.existing = gpa.dupe(u8, name) catch fail("out of memory", .{});
}

fn cmdNew(programs: []Program, progname: []const u8, account: []const u8) void {
    const prog = findProgram(programs, progname) orelse
        fail("unknown program '{s}' (known: {s})", .{ progname, knownList(programs) });
    if (account.len == 0 or std.mem.indexOfScalar(u8, account, '/') != null)
        fail("invalid account name '{s}'", .{account});

    var find = NewFind{ .account = account };
    forEachAccount(programs, prog, &find, collectNew);

    var folder: []const u8 = undefined;
    if (find.existing) |ex| {
        folder = ex;
        out("adopting existing {s}\n", .{ex});
    } else {
        folder = std.fmt.allocPrint(gpa, "{s}-{d}-{s}", .{ prog.name, find.max_id + 1, account }) catch
            fail("out of memory", .{});
        Dir.cwd().createDirPath(io, join(&.{ root, folder })) catch |e|
            fail("cannot create '{s}': {s}", .{ folder, @errorName(e) });
        out("created {s}\n", .{folder});
    }
    const folder_path = join(&.{ root, folder });

    for (prog.pairs) |pair| {
        const full = join(&.{ folder_path, pair.dir });
        Dir.cwd().createDirPath(io, full) catch |e|
            fail("cannot create '{s}': {s}", .{ full, @errorName(e) });
    }

    // Program-named launcher symlink -> ../ma (relative, so the install dir relocates).
    const link = join(&.{ folder_path, prog.name });
    Dir.cwd().symLink(io, "../ma", link, .{}) catch |e| switch (e) {
        error.PathAlreadyExists => {}, // idempotent
        else => fail("cannot create symlink '{s}': {s}", .{ link, @errorName(e) }),
    };

    out("\nlog in:   {s} ", .{link});
    if (std.mem.eql(u8, prog.name, "claude")) {
        out("/login\n", .{});
    } else if (std.mem.eql(u8, prog.name, "opencode")) {
        out("auth login\n", .{});
    } else {
        out("    (run the tool's normal login)\n", .{});
    }
    out("launch:   ma {s} {s}\n", .{ prog.name, account });
}

const LsCtx = struct { prog: *const Program, any: *bool };

fn lsRow(ctx: *LsCtx, name: []const u8, p: Parsed) void {
    ctx.any.* = true;
    const first = join(&.{ root, name, ctx.prog.pairs[0].dir });
    var populated = false;
    if (Dir.cwd().openDir(io, first, .{ .iterate = true })) |*d| {
        var dd = d.*;
        var it = dd.iterate();
        populated = (it.next(io) catch null) != null;
    } else |_| {}
    out("{s:<10} id {d:<3} {s:<20} {s}  [{s}]\n", .{
        p.program.name, p.id, p.account, name, if (populated) "logged in" else "empty",
    });
}

fn cmdLs(programs: []Program) void {
    var any = false;
    for (programs) |*prog| {
        var ctx = LsCtx{ .prog = prog, .any = &any };
        forEachAccount(programs, prog, &ctx, lsRow);
    }
    if (!any) out("no accounts yet. create one with:  ./ma new PROGRAM ACCOUNT\n", .{});
}

fn usage(programs: []Program) void {
    out(
        \\ma — multi-account launcher
        \\
        \\  ./ma new PROGRAM ACCOUNT      create an isolated account folder
        \\  ./ma PROGRAM NAME|ID [args]   launch an account (args pass through)
        \\  ./ma ls                       list accounts and login state
        \\  ./PROGRAM-ID-ACCOUNT/PROGRAM  launch directly (named after the program)
        \\
        \\known programs:
    , .{});
    out(" {s}\n", .{knownList(programs)});
}

fn dispatch(programs: []Program, args: [][]const u8) void {
    if (args.len < 2) return usage(programs);
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help"))
        return usage(programs);
    if (std.mem.eql(u8, cmd, "ls")) return cmdLs(programs);
    if (std.mem.eql(u8, cmd, "new")) {
        if (args.len != 4) fail("usage: ma new PROGRAM ACCOUNT", .{});
        return cmdNew(programs, args[2], args[3]);
    }
    if (args.len < 3) fail("usage: ma PROGRAM NAME|ID [args...]", .{});
    cmdRun(programs, args[1], args[2], args[3..]);
}

pub fn main(init: std.process.Init) void {
    io = init.io;
    gpa = init.arena.allocator();
    env = init.environ_map;

    var args: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |a| args.append(gpa, a) catch fail("out of memory", .{});
    if (args.items.len == 0) fail("no argv[0]", .{});

    const programs = loadManifest();
    // The polyglot wrapper runs the real binary from a cache dir, so args[0] no longer
    // points at the account symlink. The wrapper passes the true invocation path in
    // MA_ARGV0; fall back to args[0] for a directly-run native binary.
    const argv0 = env.get("MA_ARGV0") orelse args.items[0];
    const arg0base = path.basename(argv0);
    if (std.mem.eql(u8, arg0base, "ma")) {
        dispatch(programs, args.items);
    } else {
        launch(programs, args.items, argv0, arg0base);
    }
}
