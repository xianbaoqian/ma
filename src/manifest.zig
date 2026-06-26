const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const path = std.fs.path;

pub const max_programs = 256;
pub const max_state_env_mappings_per_program = 16;
pub const max_accounts_per_program = 4096;
pub const manifest_read_limit = 1 << 20;

pub const Pair = struct { name: []const u8, dir: []const u8 };
pub const Program = struct { name: []const u8, binary: []const u8, pairs: []Pair };
pub const Parsed = struct { program: *const Program, id: u32, account: []const u8 };

pub const Context = struct {
    io: Io,
    gpa: Allocator,
    root: []const u8,
};

/// Print a manifest/module error to stderr and exit with status 1.
/// Example: die(ctx, "manifest is empty", .{}) prints "ma: manifest is empty".
fn die(ctx: Context, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "ma: " ++ fmt ++ "\n", args) catch "ma: error\n";
    std.Io.File.stderr().writeStreamingAll(ctx.io, s) catch {};
    std.process.exit(1);
}

/// Join path fragments using the allocator in the manifest context.
/// Example: join(ctx, &.{"/accounts", "programs.conf"}) returns "/accounts/programs.conf".
fn join(ctx: Context, parts: []const []const u8) []const u8 {
    return path.join(ctx.gpa, parts) catch die(ctx, "static workspace exhausted", .{});
}

/// Find the install root that contains `ma`, `programs.conf`, and account folders.
/// Example: with MA_HOME=/accounts, installRoot(...) returns "/accounts".
pub fn installRoot(io: Io, gpa: Allocator, env: *std.process.Environ.Map) []const u8 {
    if (env.get("MA_HOME")) |h| return gpa.dupe(u8, h) catch {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "ma: static workspace exhausted\n", .{}) catch "ma: error\n";
        std.Io.File.stderr().writeStreamingAll(io, s) catch {};
        std.process.exit(1);
    };
    return std.process.executableDirPathAlloc(io, gpa) catch |e| {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "ma: cannot find own path: {s}\n", .{@errorName(e)}) catch "ma: error\n";
        std.Io.File.stderr().writeStreamingAll(io, s) catch {};
        std.process.exit(1);
    };
}

/// Read `programs.conf` and return all configured programs.
/// Example: "claude | claude | CLAUDE_CONFIG_DIR=.claude" becomes one Program.
pub fn load(ctx: Context) []Program {
    const file = join(ctx, &.{ ctx.root, "programs.conf" });
    const data = Dir.cwd().readFileAlloc(ctx.io, file, ctx.gpa, .limited(manifest_read_limit)) catch |e|
        die(ctx, "cannot read manifest '{s}': {s}", .{ file, @errorName(e) });

    var list: std.ArrayList(Program) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, line, '|');
        const name = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const binary = std.mem.trim(u8, fields.next() orelse
            die(ctx, "manifest line missing binary: '{s}'", .{line}), " \t");
        const pairs_field = std.mem.trim(u8, fields.next() orelse
            die(ctx, "manifest line missing state env mappings (VAR=dir): '{s}'", .{line}), " \t");
        if (name.len == 0 or binary.len == 0)
            die(ctx, "manifest line has empty name or binary: '{s}'", .{line});

        var pairs: std.ArrayList(Pair) = .empty;
        var toks = std.mem.tokenizeScalar(u8, pairs_field, ' ');
        while (toks.next()) |tok| {
            const eq = std.mem.indexOfScalar(u8, tok, '=') orelse
                die(ctx, "manifest pair '{s}' is not VAR=dir (line: '{s}')", .{ tok, line });
            if (eq == 0 or eq == tok.len - 1)
                die(ctx, "manifest pair '{s}' has empty side (line: '{s}')", .{ tok, line });
            if (pairs.items.len == max_state_env_mappings_per_program)
                die(ctx, "program '{s}' has too many state env mappings for one command to load (max {d}; disk storage is not limited)", .{ name, max_state_env_mappings_per_program });
            pairs.append(ctx.gpa, .{ .name = tok[0..eq], .dir = tok[eq + 1 ..] }) catch
                die(ctx, "static workspace exhausted", .{});
        }
        if (pairs.items.len == 0) die(ctx, "program '{s}' has no state env mappings (VAR=dir)", .{name});
        if (list.items.len == max_programs)
            die(ctx, "too many programs for one command to load (max {d}; disk storage is not limited)", .{max_programs});

        list.append(ctx.gpa, .{
            .name = name,
            .binary = binary,
            .pairs = pairs.toOwnedSlice(ctx.gpa) catch die(ctx, "static workspace exhausted", .{}),
        }) catch die(ctx, "static workspace exhausted", .{});
    }
    if (list.items.len == 0) die(ctx, "manifest is empty", .{});
    return list.toOwnedSlice(ctx.gpa) catch die(ctx, "static workspace exhausted", .{});
}

/// Find a configured program by command name.
/// Example: find(programs, "claude") returns the claude Program; "missing" returns null.
pub fn find(programs: []Program, name: []const u8) ?*Program {
    for (programs) |*p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// Return a comma-separated list of known program names for error messages.
/// Example: knownList(ctx, programs) returns "claude, codex, kimi, opencode".
pub fn knownList(ctx: Context, programs: []Program) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    for (programs, 0..) |p, i| {
        if (i != 0) b.appendSlice(ctx.gpa, ", ") catch return "";
        b.appendSlice(ctx.gpa, p.name) catch return "";
    }
    return b.toOwnedSlice(ctx.gpa) catch "";
}

/// Test whether a folder name has the PROGRAM-ID-ACCOUNT shape for a program.
/// Example: isAccountFolder(claude, "claude-12-中文") returns true.
pub fn isAccountFolder(program: *const Program, name: []const u8) bool {
    if (name.len <= program.name.len + 2) return false;
    if (!std.mem.startsWith(u8, name, program.name) or name[program.name.len] != '-') return false;
    const rest = name[program.name.len + 1 ..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return false;
    _ = std.fmt.parseInt(u32, rest[0..dash], 10) catch return false;
    return dash + 1 < rest.len;
}

/// Parse PROGRAM-ID-ACCOUNT into program pointer, numeric id, and account name.
/// Example: parse(ctx, programs, "claude-12-work") returns id=12 and account="work".
pub fn parse(ctx: Context, programs: []Program, name: []const u8) Parsed {
    var best: ?*Program = null;
    for (programs) |*p| {
        if (name.len > p.name.len and std.mem.startsWith(u8, name, p.name) and name[p.name.len] == '-') {
            if (best == null or p.name.len > best.?.name.len) best = p;
        }
    }
    const p = best orelse
        die(ctx, "folder '{s}': no known program prefix (known: {s})", .{ name, knownList(ctx, programs) });

    const rest = name[p.name.len + 1 ..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse
        die(ctx, "folder '{s}': expected PROGRAM-ID-ACCOUNT", .{name});
    const id = std.fmt.parseInt(u32, rest[0..dash], 10) catch
        die(ctx, "folder '{s}': id '{s}' is not an integer", .{ name, rest[0..dash] });
    const account = rest[dash + 1 ..];
    if (account.len == 0) die(ctx, "folder '{s}': empty account name", .{name});
    return .{ .program = p, .id = id, .account = account };
}

/// Visit each valid account folder in the install root for one program.
/// Example: with claude-1-work and codex-1-work, visiting claude yields only claude-1-work.
pub fn forEachAccount(
    ctx: Context,
    programs: []Program,
    prog: *const Program,
    user_ctx: anytype,
    comptime f: fn (@TypeOf(user_ctx), []const u8, Parsed) void,
) void {
    var dir = Dir.cwd().openDir(ctx.io, ctx.root, .{ .iterate = true }) catch |e|
        die(ctx, "cannot open install dir '{s}': {s}", .{ ctx.root, @errorName(e) });
    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(ctx.io) catch |e| die(ctx, "cannot scan directory: {s}", .{@errorName(e)})) |entry| {
        if (entry.kind != .directory or !isAccountFolder(prog, entry.name)) continue;
        if (count == max_accounts_per_program)
            die(ctx, "too many '{s}' accounts for one command to scan in RAM (max {d}; disk storage is not limited)", .{ prog.name, max_accounts_per_program });
        count += 1;
        const p = parse(ctx, programs, entry.name);
        if (p.program != prog) continue;
        f(user_ctx, entry.name, p);
    }
}
