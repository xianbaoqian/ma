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
const auth_mod = @import("auth.zig");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const path = std.fs.path;

const Program = manifest_mod.Program;
const Parsed = manifest_mod.Parsed;
const max_exec_args = 4096;
const workspace_bytes = 256 << 20;
const max_account_folder_len = 1024;

comptime {
    if (max_exec_args < 4096) @compileError("ma argv capacity must stay at least 4096");
    if (workspace_bytes < manifest_mod.manifest_read_limit + auth_mod.auth_file_read_limit + resume_mod.history_read_limit + resume_mod.session_read_limit)
        @compileError("ma workspace must cover the largest bounded file reads");
    if (workspace_bytes < (@as(usize, manifest_mod.max_accounts_per_program) * 4096))
        @compileError("ma workspace must cover account scan metadata");
    if (workspace_bytes < (@as(usize, auth_mod.max_auth_tokens) * 4096))
        @compileError("ma workspace must cover auth token metadata");
    if (workspace_bytes < (@as(usize, resume_mod.max_session_rows) * 4096))
        @compileError("ma workspace must cover session list metadata");
}

// Globals set once in main, so helpers stay K&R-short instead of threading them everywhere.
var io: Io = undefined;
var gpa: Allocator = undefined;
var env: *std.process.Environ.Map = undefined;
var workspace: [workspace_bytes]u8 = undefined;
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
    return path.join(gpa, parts) catch fail("static workspace exhausted", .{});
}

/// Resolve a possibly relative path into a canonical absolute path.
/// Example: from /repo, absolutize("./claude-1-work") returns "/repo/claude-1-work".
fn absolutize(p: []const u8) []const u8 {
    const cwd = std.process.currentPathAlloc(io, gpa) catch |e|
        fail("cannot read current directory: {s}", .{@errorName(e)});
    return path.resolve(gpa, &.{ cwd, p }) catch fail("static workspace exhausted", .{});
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

/// Return whether a Codex -c value tries to control CLI auth storage.
/// Example: "cli_auth_credentials_store=keyring" is rejected for managed auth.
fn isCodexAuthStoreOverrideValue(arg: []const u8) bool {
    const key = "cli_auth_credentials_store";
    if (!std.mem.startsWith(u8, arg, key)) return false;
    return arg.len == key.len or arg[key.len] == '=';
}

/// Return whether an argv item contains a Codex config override for auth storage.
/// Example: "--config=cli_auth_credentials_store=keyring" returns true.
fn isInlineCodexAuthStoreOverride(arg: []const u8) bool {
    if (std.mem.startsWith(u8, arg, "--config="))
        return isCodexAuthStoreOverrideValue(arg["--config=".len..]);
    if (std.mem.startsWith(u8, arg, "-c="))
        return isCodexAuthStoreOverrideValue(arg["-c=".len..]);
    if (std.mem.startsWith(u8, arg, "-c") and arg.len > 2)
        return isCodexAuthStoreOverrideValue(arg[2..]);
    return false;
}

/// Reject user overrides that would move Codex refreshes away from the selected slot.
/// Example: `ma codex work exec -c cli_auth_credentials_store=keyring hi` fails early.
fn rejectCodexAuthStoreOverride(args: [][]const u8) void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            if (i + 1 < args.len and isCodexAuthStoreOverrideValue(args[i + 1]))
                fail("managed Codex auth requires cli_auth_credentials_store=file; remove the user -c override", .{});
            i += 1;
            continue;
        }
        if (isInlineCodexAuthStoreOverride(arg))
            fail("managed Codex auth requires cli_auth_credentials_store=file; remove the user -c override", .{});
    }
}

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
        env.put(pair.name, join(&.{ folder, pair.dir })) catch fail("static workspace exhausted", .{});
    const force_codex_file_auth = auth_mod.launchNeedsCodexFileAuthOverride(.{ .io = io, .gpa = gpa, .env = env, .install_root = root }, p.program, folder);
    if (force_codex_file_auth) rejectCodexAuthStoreOverride(args);
    auth_mod.applyLaunchEnv(.{ .io = io, .gpa = gpa, .env = env, .install_root = root }, p.program, folder);

    const real = which(p.program.binary, folder) orelse
        fail("binary '{s}' not found in PATH", .{p.program.binary});

    const extra_args: usize = if (force_codex_file_auth) 2 else 0;
    if (args.len + extra_args > max_exec_args) fail("too many command arguments for one request (max {d})", .{max_exec_args});
    var argv_buf: [max_exec_args][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = real;
    argc += 1;
    if (force_codex_file_auth) {
        argv_buf[argc] = "-c";
        argc += 1;
        argv_buf[argc] = auth_mod.codex_file_auth_override;
        argc += 1;
    }
    for (args[1..]) |a| {
        argv_buf[argc] = a;
        argc += 1;
    }
    exec(argv_buf[0..argc]);
}

// ---- ADD-ONS ----

const RunFind = struct {
    key: []const u8,
    key_id: ?u32,
    count: usize = 0,
    first: ?[]const u8 = null,
    second: ?[]const u8 = null,
    first_buf: [max_account_folder_len]u8 = undefined,
    second_buf: [max_account_folder_len]u8 = undefined,
};

/// Record account folders that match a requested account name or numeric id.
/// Example: key="work" records "claude-1-work"; key_id=1 records account id 1.
fn collectRun(ctx: *RunFind, name: []const u8, p: Parsed) void {
    const hit = if (ctx.key_id) |k| p.id == k else std.mem.eql(u8, p.account, ctx.key);
    if (!hit) return;
    ctx.count += 1;
    if (ctx.count == 1) {
        if (name.len > ctx.first_buf.len) fail("account folder name is too long for one command to load (max {d} bytes)", .{max_account_folder_len});
        @memcpy(ctx.first_buf[0..name.len], name);
        ctx.first = ctx.first_buf[0..name.len];
    } else if (ctx.count == 2) {
        if (name.len > ctx.second_buf.len) fail("account folder name is too long for one command to load (max {d} bytes)", .{max_account_folder_len});
        @memcpy(ctx.second_buf[0..name.len], name);
        ctx.second = ctx.second_buf[0..name.len];
    }
}

/// Resolve `ma PROGRAM NAME|ID [args...]` into an account launcher and exec it.
/// Example: cmdRun("claude", "work", &.{"--resume", uuid}) execs claude-1-work/claude.
fn cmdRun(programs: []Program, progname: []const u8, key: []const u8, rest: [][]const u8) noreturn {
    const prog = manifest_mod.find(programs, progname) orelse
        fail("unknown program '{s}' (known: {s})", .{ progname, manifest_mod.knownList(manifestContext(), programs) });

    var find = RunFind{ .key = key, .key_id = std.fmt.parseInt(u32, key, 10) catch null };
    manifest_mod.forEachAccount(manifestContext(), programs, prog, &find, collectRun);

    if (find.count == 0)
        fail("no account '{s}' for program '{s}' (try: ma ls)", .{ key, progname });
    if (find.count > 1) {
        if (find.second) |second|
            fail("'{s} {s}' is ambiguous, matches:\n  {s}\n  {s}", .{ progname, key, find.first.?, second });
        fail("'{s} {s}' is ambiguous", .{ progname, key });
    }

    // Hand off to the kernel via the per-account symlink; its (absolute) path tells the
    // kernel the folder, so this works regardless of the caller's cwd.
    const launcher = join(&.{ root, find.first.?, prog.name });
    if (1 + rest.len > max_exec_args) fail("too many command arguments for one request (max {d})", .{max_exec_args});
    var argv_buf: [max_exec_args][]const u8 = undefined;
    argv_buf[0] = launcher;
    for (rest, 1..) |a, i| argv_buf[i] = a;
    exec(argv_buf[0 .. 1 + rest.len]);
}

const NewFind = struct { account: []const u8, max_id: u32 = 0, existing: ?[]const u8 = null };

/// Track the next id and any existing account while creating an account.
/// Example: seeing "claude-3-work" sets max_id=3 and existing if account is "work".
fn collectNew(ctx: *NewFind, name: []const u8, p: Parsed) void {
    if (p.id > ctx.max_id) ctx.max_id = p.id;
    if (std.mem.eql(u8, p.account, ctx.account))
        ctx.existing = gpa.dupe(u8, name) catch fail("static workspace exhausted", .{});
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
            fail("static workspace exhausted", .{});
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
        \\  ./ma auth add PROGRAM [ACCOUNT] [TOKEN]
        \\  ./ma auth ls PROGRAM [ACCOUNT]
        \\  ./ma auth rotate PROGRAM [ACCOUNT]
        \\  ./ma auth check PROGRAM [ACCOUNT] [--prune]
        \\  ./ma auth remove PROGRAM [ACCOUNT] TOKEN
        \\  ./ma auth clear PROGRAM [ACCOUNT]
        \\  ./ma PROGRAM NAME|ID [args]   launch an account (args pass through)
        \\  ./ma PROGRAM ps               list sessions for the current folder
        \\  ./ma ls                       list accounts and login state
        \\  ./PROGRAM-ID-ACCOUNT/PROGRAM  launch directly (named after the program)
        \\
        \\known programs:
    , .{});
    out(" {s}\n", .{manifest_mod.knownList(manifestContext(), programs)});
}

/// Dispatch `ma auth ...` for file-backed subscription login tokens.
/// Example: `ma auth add codex work sub1` runs Codex device auth into ma-auth/sub1.
fn cmdAuth(programs: []Program, args: [][]const u8) void {
    if (args.len < 4) fail("usage: ma auth add PROGRAM [ACCOUNT] [TOKEN] | ma auth ls PROGRAM [ACCOUNT] | ma auth rotate PROGRAM [ACCOUNT] | ma auth check PROGRAM [ACCOUNT] [--prune] | ma auth remove PROGRAM [ACCOUNT] TOKEN | ma auth clear PROGRAM [ACCOUNT]", .{});
    const sub = args[2];
    const ctx = auth_mod.Context{ .io = io, .gpa = gpa, .env = env, .install_root = root };
    if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 4 or args.len > 6) fail("usage: ma auth add PROGRAM [ACCOUNT] [TOKEN]", .{});
        return auth_mod.cmdAddArgs(ctx, programs, args[3], args[4..]);
    }
    if (std.mem.eql(u8, sub, "ls")) {
        if (args.len == 4) return auth_mod.cmdList(ctx, programs, args[3], null);
        if (args.len == 5) return auth_mod.cmdList(ctx, programs, args[3], args[4]);
        fail("usage: ma auth ls PROGRAM [ACCOUNT]", .{});
    }
    if (std.mem.eql(u8, sub, "rotate")) {
        if (args.len == 4) return auth_mod.cmdRotate(ctx, programs, args[3], null);
        if (args.len == 5) return auth_mod.cmdRotate(ctx, programs, args[3], args[4]);
        fail("usage: ma auth rotate PROGRAM [ACCOUNT]", .{});
    }
    if (std.mem.eql(u8, sub, "check")) {
        if (args.len < 4 or args.len > 6) fail("usage: ma auth check PROGRAM [ACCOUNT] [--prune]", .{});
        return auth_mod.cmdCheckArgs(ctx, programs, args[3], args[4..]);
    }
    if (std.mem.eql(u8, sub, "remove")) {
        if (args.len < 5 or args.len > 6) fail("usage: ma auth remove PROGRAM [ACCOUNT] TOKEN", .{});
        return auth_mod.cmdRemoveArgs(ctx, programs, args[3], args[4..]);
    }
    if (std.mem.eql(u8, sub, "clear")) {
        if (args.len == 4) return auth_mod.cmdClear(ctx, programs, args[3], null);
        if (args.len == 5) return auth_mod.cmdClear(ctx, programs, args[3], args[4]);
        fail("usage: ma auth clear PROGRAM [ACCOUNT]", .{});
    }
    fail("unknown auth command '{s}' (try: ma help)", .{sub});
}

/// Dispatch the `ma` add-on command line to new, ls, help, or run.
/// Example: args=["ma","claude","work"] calls cmdRun for claude/work.
fn dispatch(programs: []Program, args: [][]const u8) void {
    if (args.len < 2) return usage(programs);
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help"))
        return usage(programs);
    if (std.mem.eql(u8, cmd, "ls")) return cmdLs(programs);
    if (std.mem.eql(u8, cmd, "auth")) return cmdAuth(programs, args);
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
    var fixed = std.heap.FixedBufferAllocator.init(&workspace);
    gpa = fixed.allocator();
    env = init.environ_map;

    var args_buf: [max_exec_args][]const u8 = undefined;
    var args_len: usize = 0;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |a| {
        if (args_len == args_buf.len) fail("too many command arguments for one request (max {d})", .{max_exec_args});
        args_buf[args_len] = a;
        args_len += 1;
    }
    const args = args_buf[0..args_len];
    if (args.len == 0) fail("no argv[0]", .{});

    root = manifest_mod.installRoot(io, gpa, env);
    const programs = manifest_mod.load(manifestContext());
    // The polyglot wrapper runs the real binary from a cache dir, so args[0] no longer
    // points at the account symlink. The wrapper passes the true invocation path in
    // MA_ARGV0; fall back to args[0] for a directly-run native binary.
    const argv0 = env.get("MA_ARGV0") orelse args[0];
    const arg0base = path.basename(argv0);
    if (std.mem.eql(u8, arg0base, "ma")) {
        dispatch(programs, args);
    } else {
        launch(programs, args, argv0, arg0base);
    }
}
