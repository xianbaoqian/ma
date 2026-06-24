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
const manifest_mod = @import("manifest.zig");
const resume_mod = @import("resume.zig");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const path = std.fs.path;

const Program = manifest_mod.Program;
const Parsed = manifest_mod.Parsed;

// Globals set once in main, so helpers stay K&R-short instead of threading them everywhere.
var io: Io = undefined;
var gpa: Allocator = undefined;
var env: *std.process.Environ.Map = undefined;
// Install dir: where `ma` and programs.conf live. Account folders live here too, so the
// add-ons work from any cwd (e.g. when `ma` is aliased). Set once in main.
var root: []const u8 = undefined;

// ---- output / failure (write straight to fd 1/2; immune to std.io churn) ----

/// Write formatted text to stdout.
/// Example: out("created {s}\n", .{"claude-1-work"}) prints "created claude-1-work".
fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

/// Print a formatted ma-prefixed error to stderr and exit with status 1.
/// Example: fail("unknown program '{s}'", .{"foo"}) prints "ma: unknown program 'foo'".
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "ma: " ++ fmt ++ "\n", args) catch "ma: error\n";
    std.Io.File.stderr().writeStreamingAll(io, s) catch {};
    std.process.exit(1);
}

/// Join path fragments with the platform separator.
/// Example: join(&.{ "/tmp/accts", "claude-1-work", ".claude" }) returns that path joined.
fn join(parts: []const []const u8) []const u8 {
    return path.join(gpa, parts) catch fail("out of memory", .{});
}

/// Resolve a possibly relative path into a canonical absolute path.
/// Example: from /repo, absolutize("./claude-1-work") returns "/repo/claude-1-work".
fn absolutize(p: []const u8) []const u8 {
    const cwd = std.process.currentPathAlloc(io, gpa) catch |e|
        fail("cannot read current directory: {s}", .{@errorName(e)});
    return path.resolve(gpa, &.{ cwd, p }) catch fail("out of memory", .{});
}

/// Build the manifest module context from launcher globals.
/// Example: if root is "/accounts", this returns a context whose root is "/accounts".
fn manifestContext() manifest_mod.Context {
    return .{ .io = io, .gpa = gpa, .root = root };
}

/// Search PATH for a real executable, ignoring the current account folder.
/// Example: which("claude", "/accounts/claude-1-work") returns "/usr/local/bin/claude".
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

/// Replace this process image with argv; argv[0] must be a path, not a bare command.
/// Example: exec(&.{"/usr/bin/env", "bash"}) never returns if /usr/bin/env starts.
fn exec(argv: []const []const u8) noreturn {
    const e = std.process.replace(io, .{ .argv = argv, .environ_map = env });
    fail("exec '{s}' failed: {s}", .{ argv[0], @errorName(e) });
}

// ---- KERNEL ----

/// Launch one account by deriving PROGRAM-ID-ACCOUNT from the symlink path.
/// Example: argv0="/accounts/claude-1-work/claude" sets CLAUDE_CONFIG_DIR and execs claude.
fn launch(programs: []Program, args: [][]const u8, argv0: []const u8, arg0base: []const u8) noreturn {
    if (std.mem.indexOfScalar(u8, argv0, '/') == null)
        fail("run the account launcher by path, e.g. ./claude-1-thorson/{s}", .{arg0base});

    const folder = absolutize(path.dirname(argv0).?);
    const fname = path.basename(folder);

    const p = manifest_mod.parse(manifestContext(), programs, fname);
    if (!std.mem.eql(u8, arg0base, p.program.name))
        fail("launcher '{s}' in folder '{s}' should be named '{s}'", .{ arg0base, fname, p.program.name });

    if (resume_mod.supports(p.program.name))
        resume_mod.maybeAdopt(.{ .io = io, .gpa = gpa, .env = env, .install_root = root }, p.program, p.account, folder, args);

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

const RunFind = struct { key: []const u8, key_id: ?u32, matches: *std.ArrayList([]const u8) };

/// Record account folders that match a requested account name or numeric id.
/// Example: key="work" records "claude-1-work"; key_id=1 records account id 1.
fn collectRun(ctx: *RunFind, name: []const u8, p: Parsed) void {
    const hit = if (ctx.key_id) |k| p.id == k else std.mem.eql(u8, p.account, ctx.key);
    if (hit) ctx.matches.append(gpa, gpa.dupe(u8, name) catch fail("out of memory", .{})) catch
        fail("out of memory", .{});
}

/// Resolve `ma PROGRAM NAME|ID [args...]` into an account launcher and exec it.
/// Example: cmdRun("claude", "work", &.{"--resume", uuid}) execs claude-1-work/claude.
fn cmdRun(programs: []Program, progname: []const u8, key: []const u8, rest: [][]const u8) noreturn {
    const prog = manifest_mod.find(programs, progname) orelse
        fail("unknown program '{s}' (known: {s})", .{ progname, manifest_mod.knownList(manifestContext(), programs) });

    var matches: std.ArrayList([]const u8) = .empty;
    var find = RunFind{ .key = key, .key_id = std.fmt.parseInt(u32, key, 10) catch null, .matches = &matches };
    manifest_mod.forEachAccount(manifestContext(), programs, prog, &find, collectRun);

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

/// Track the next id and any existing account while creating an account.
/// Example: seeing "claude-3-work" sets max_id=3 and existing if account is "work".
fn collectNew(ctx: *NewFind, name: []const u8, p: Parsed) void {
    if (p.id > ctx.max_id) ctx.max_id = p.id;
    if (std.mem.eql(u8, p.account, ctx.account))
        ctx.existing = gpa.dupe(u8, name) catch fail("out of memory", .{});
}

/// Create or adopt an account folder and its program symlink.
/// Example: cmdNew("claude", "work") creates "claude-1-work/.claude" and "claude".
fn cmdNew(programs: []Program, progname: []const u8, account: []const u8) void {
    const prog = manifest_mod.find(programs, progname) orelse
        fail("unknown program '{s}' (known: {s})", .{ progname, manifest_mod.knownList(manifestContext(), programs) });
    if (account.len == 0 or std.mem.indexOfScalar(u8, account, '/') != null)
        fail("invalid account name '{s}'", .{account});

    var find = NewFind{ .account = account };
    manifest_mod.forEachAccount(manifestContext(), programs, prog, &find, collectNew);

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

    out("\nlaunch:   ma {s} {s}\n", .{ prog.name, account });
}

const LsCtx = struct { prog: *const Program, any: *bool };

/// Print one `ma ls` row for a parsed account folder.
/// Example: "claude-1-work" prints program=claude, id=1, account=work, and login state.
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

/// List every known account folder and whether its first state dir is populated.
/// Example: with "claude-1-work/.claude" non-empty, output marks it "[logged in]".
fn cmdLs(programs: []Program) void {
    var any = false;
    for (programs) |*prog| {
        var ctx = LsCtx{ .prog = prog, .any = &any };
        manifest_mod.forEachAccount(manifestContext(), programs, prog, &ctx, lsRow);
    }
    if (!any) out("no accounts yet. create one with:  ./ma new PROGRAM ACCOUNT\n", .{});
}

const PsCtx = struct { prog: *const Program, cwd: []const u8, rows: *std.ArrayList(resume_mod.PsRow) };

/// Add one account folder's current-project sessions to a `ma PROGRAM ps` listing.
/// Example: "claude-1-work" contributes rows from its .claude/projects/<cwd>/ directory.
fn psRow(ctx: *PsCtx, name: []const u8, p: Parsed) void {
    resume_mod.ps(.{ .io = io, .gpa = gpa, .env = env, .install_root = root }, ctx.prog, join(&.{ root, name }), p.account, ctx.cwd, ctx.rows);
}

/// List all sessions for this current folder across the program's account folders.
/// Example: cmdPs("claude") implements `ma claude ps`.
fn cmdPs(programs: []Program, progname: []const u8) void {
    const prog = manifest_mod.find(programs, progname) orelse
        fail("unknown program '{s}' (known: {s})", .{ progname, manifest_mod.knownList(manifestContext(), programs) });
    if (!resume_mod.supports(prog.name)) fail("'{s} ps' is not supported", .{prog.name});
    const cwd = std.process.currentPathAlloc(io, gpa) catch |e|
        fail("cannot read current directory: {s}", .{@errorName(e)});
    var rows: std.ArrayList(resume_mod.PsRow) = .empty;
    var ctx = PsCtx{ .prog = prog, .cwd = cwd, .rows = &rows };
    manifest_mod.forEachAccount(manifestContext(), programs, prog, &ctx, psRow);
    resume_mod.printPs(.{ .io = io, .gpa = gpa, .env = env, .install_root = root }, prog.name, cwd, rows.items);
}

/// Print command usage and the manifest's known programs.
/// Example: usage(programs) prints "ma new PROGRAM ACCOUNT" and "claude, codex, ...".
fn usage(programs: []Program) void {
    out(
        \\ma — multi-account launcher
        \\
        \\  ./ma new PROGRAM ACCOUNT      create an isolated account folder
        \\  ./ma PROGRAM NAME|ID [args]   launch an account (args pass through)
        \\  ./ma PROGRAM ps               list sessions for the current folder
        \\  ./ma ls                       list accounts and login state
        \\  ./PROGRAM-ID-ACCOUNT/PROGRAM  launch directly (named after the program)
        \\
        \\known programs:
    , .{});
    out(" {s}\n", .{manifest_mod.knownList(manifestContext(), programs)});
}

/// Dispatch the `ma` add-on command line to new, ls, help, or run.
/// Example: args=["ma","claude","work"] calls cmdRun for claude/work.
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
    if (std.mem.eql(u8, args[2], "ps")) {
        if (args.len != 3) fail("usage: ma PROGRAM ps", .{});
        return cmdPs(programs, args[1]);
    }
    cmdRun(programs, args[1], args[2], args[3..]);
}

/// Program entry point; decide whether this invocation is `ma` or an account symlink.
/// Example: argv0="ma" dispatches add-ons; argv0="claude-1-work/claude" launches account.
pub fn main(init: std.process.Init) void {
    io = init.io;
    gpa = init.arena.allocator();
    env = init.environ_map;

    var args: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |a| args.append(gpa, a) catch fail("out of memory", .{});
    if (args.items.len == 0) fail("no argv[0]", .{});

    root = manifest_mod.installRoot(io, gpa, env);
    const programs = manifest_mod.load(manifestContext());
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
