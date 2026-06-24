const std = @import("std");
const manifest = @import("manifest.zig");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const path = std.fs.path;

const Program = manifest.Program;

pub const Context = struct {
    io: Io,
    gpa: Allocator,
    env: *std.process.Environ.Map,
    install_root: []const u8,
};

const Mode = enum { exact_jsonl, contains_jsonl };
const Hit = struct { label: []const u8, root: []const u8, rel: []const u8, sidecar: ?[]const u8 = null };

/// Print a resume/module error to stderr and exit with status 1.
/// Example: die(ctx, "resume adoption declined", .{}) prints that ma-prefixed error.
fn die(ctx: Context, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "ma: " ++ fmt ++ "\n", args) catch "ma: error\n";
    std.Io.File.stderr().writeStreamingAll(ctx.io, s) catch {};
    std.process.exit(1);
}

/// Print a warning or confirmation prompt to stderr.
/// Example: warn(ctx, "move it into '{s}'? [y/N]", .{"work"}) asks for confirmation.
fn warn(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "ma: " ++ fmt ++ "\n", args) catch "ma: warning\n";
    std.Io.File.stderr().writeStreamingAll(ctx.io, s) catch {};
}

/// Join path fragments with the allocator in the resume context.
/// Example: join(ctx, &.{"/accounts/claude-1-work", ".claude"}) returns the state root.
fn join(ctx: Context, parts: []const []const u8) []const u8 {
    return path.join(ctx.gpa, parts) catch die(ctx, "out of memory", .{});
}

/// Return the state directory for an account folder.
/// Example: stateRoot(ctx, claude, "/accounts/claude-1-work") returns ".../.claude".
pub fn stateRoot(ctx: Context, program: *const Program, folder: []const u8) []const u8 {
    if (program.pairs.len != 1) die(ctx, "'{s}' must have exactly one state dir", .{program.name});
    return join(ctx, &.{ folder, program.pairs[0].dir });
}

/// Map a supported program to how its session file is named.
/// Example: mode("claude") is exact_jsonl; mode("codex") is contains_jsonl.
fn mode(program: []const u8) ?Mode {
    if (std.mem.eql(u8, program, "claude")) return .exact_jsonl;
    if (std.mem.eql(u8, program, "codex")) return .contains_jsonl;
    return null;
}

/// Report whether this program has resume adoption support.
/// Example: supports("claude") and supports("codex") return true; "kimi" returns false.
pub fn supports(program: []const u8) bool {
    return mode(program) != null;
}

/// Validate the canonical 36-byte dashed UUID form.
/// Example: isUuid("fbfdb307-0866-4923-9e77-8a2a4274086e") returns true.
fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash and c != '-') return false;
        if (!dash and !std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Extract an explicit resume session id from the program argv.
/// Example: claude args ["claude","--resume",uuid] returns uuid; codex ["codex","resume",uuid] returns uuid.
fn resumeId(m: Mode, args: [][]const u8) ?[]const u8 {
    switch (m) {
        .exact_jsonl => {
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--resume") or std.mem.eql(u8, args[i], "-r")) {
                    if (i + 1 < args.len and isUuid(args[i + 1])) return args[i + 1];
                } else if (std.mem.startsWith(u8, args[i], "--resume=")) {
                    const id = args[i]["--resume=".len..];
                    if (isUuid(id)) return id;
                }
            }
        },
        .contains_jsonl => {
            var saw = false;
            for (args[1..]) |a| {
                if (!saw) {
                    saw = std.mem.eql(u8, a, "resume");
                    continue;
                }
                if (isUuid(a)) return a;
            }
        },
    }
    return null;
}

/// Test whether a JSONL basename belongs to the requested session id.
/// Example: wanted(exact_jsonl, uuid ++ ".jsonl", uuid) returns true for Claude.
fn wanted(m: Mode, basename: []const u8, id: []const u8) bool {
    if (!std.mem.endsWith(u8, basename, ".jsonl")) return false;
    return switch (m) {
        .exact_jsonl => basename.len == id.len + ".jsonl".len and std.mem.startsWith(u8, basename, id),
        .contains_jsonl => std.mem.indexOf(u8, basename, id) != null,
    };
}

/// Recursively find the first matching session JSONL under a state root.
/// Example: find(ctx, ".claude", exact_jsonl, uuid) returns rel "projects/.../uuid.jsonl".
fn find(ctx: Context, root: []const u8, m: Mode, id: []const u8) ?Hit {
    var dir = Dir.cwd().openDir(ctx.io, root, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    var w = dir.walk(ctx.gpa) catch return null;
    defer w.deinit();
    while (w.next(ctx.io) catch null) |e| {
        if (e.kind != .file or !wanted(m, e.basename, id)) continue;
        const sidecar = if (m == .exact_jsonl) blk: {
            const d = path.dirname(e.path) orelse break :blk ctx.gpa.dupe(u8, id) catch die(ctx, "out of memory", .{});
            break :blk join(ctx, &.{ d, id });
        } else null;
        return .{
            .label = "",
            .root = root,
            .rel = ctx.gpa.dupe(u8, e.path) catch die(ctx, "out of memory", .{}),
            .sidecar = sidecar,
        };
    }
    return null;
}

/// Remember a hit from one root, failing if a different root already had the same id.
/// Example: remember(..., "claude-2-cn", src, target, ..., uuid) stores that owner once.
fn remember(ctx: Context, found: *?Hit, label: []const u8, root: []const u8, target: []const u8, m: Mode, id: []const u8) void {
    if (std.mem.eql(u8, root, target)) return;
    if (found.*) |h| if (std.mem.eql(u8, h.root, root)) return;
    const h = find(ctx, root, m, id) orelse return;
    if (found.* != null) die(ctx, "session {s} exists in more than one profile", .{id});
    found.* = .{
        .label = ctx.gpa.dupe(u8, label) catch die(ctx, "out of memory", .{}),
        .root = ctx.gpa.dupe(u8, root) catch die(ctx, "out of memory", .{}),
        .rel = ctx.gpa.dupe(u8, h.rel) catch die(ctx, "out of memory", .{}),
        .sidecar = if (h.sidecar) |s| (ctx.gpa.dupe(u8, s) catch die(ctx, "out of memory", .{})) else null,
    };
}

/// Read a file if it exists; missing files are treated as null.
/// Example: readOpt(ctx, "missing/history.jsonl") returns null.
fn readOpt(ctx: Context, p: []const u8) ?[]const u8 {
    return Dir.cwd().readFileAlloc(ctx.io, p, ctx.gpa, .limited(64 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => die(ctx, "cannot read '{s}': {s}", .{ p, @errorName(e) }),
    };
}

/// Keep either the history lines matching a UUID or the lines not matching it.
/// Example: historyPart(data, uuid, true) returns only history rows for that session.
fn historyPart(ctx: Context, data: []const u8, id: []const u8, want: bool) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if ((std.mem.indexOf(u8, line, id) != null) != want) continue;
        b.appendSlice(ctx.gpa, line) catch die(ctx, "out of memory", .{});
        b.append(ctx.gpa, '\n') catch die(ctx, "out of memory", .{});
    }
    return b.toOwnedSlice(ctx.gpa) catch die(ctx, "out of memory", .{});
}

/// Create the parent directory for a path, if the path has one.
/// Example: ensureParent(ctx, "/a/b/c.jsonl") creates "/a/b".
fn ensureParent(ctx: Context, p: []const u8) void {
    const d = path.dirname(p) orelse return;
    Dir.cwd().createDirPath(ctx.io, d) catch |e| die(ctx, "cannot create '{s}': {s}", .{ d, @errorName(e) });
}

/// Check whether a path exists.
/// Example: exists(ctx, "/tmp/session.jsonl") returns true after the file is created.
fn exists(ctx: Context, p: []const u8) bool {
    Dir.cwd().access(ctx.io, p, .{}) catch return false;
    return true;
}

/// Move one file or directory, refusing to overwrite the destination.
/// Example: moveOne(ctx, "src/session.jsonl", "dst/session.jsonl") renames it.
fn moveOne(ctx: Context, src: []const u8, dst: []const u8) void {
    if (exists(ctx, dst)) die(ctx, "refusing to overwrite '{s}'", .{dst});
    ensureParent(ctx, dst);
    Dir.renameAbsolute(src, dst, ctx.io) catch |e| die(ctx, "cannot move '{s}' to '{s}': {s}", .{ src, dst, @errorName(e) });
}

/// Move matching history.jsonl lines from the source root into the target root.
/// Example: a source history line containing uuid is removed there and appended at target.
fn moveHistory(ctx: Context, src_root: []const u8, dst_root: []const u8, id: []const u8) void {
    const src = join(ctx, &.{ src_root, "history.jsonl" });
    const data = readOpt(ctx, src) orelse return;
    const moved = historyPart(ctx, data, id, true);
    if (moved.len == 0) return;
    Dir.cwd().writeFile(ctx.io, .{ .sub_path = src, .data = historyPart(ctx, data, id, false) }) catch |e|
        die(ctx, "cannot update '{s}': {s}", .{ src, @errorName(e) });

    const dst = join(ctx, &.{ dst_root, "history.jsonl" });
    const old = readOpt(ctx, dst) orelse "";
    if (std.mem.indexOf(u8, old, id) != null) return;
    var b: std.ArrayList(u8) = .empty;
    b.appendSlice(ctx.gpa, old) catch die(ctx, "out of memory", .{});
    if (old.len != 0 and old[old.len - 1] != '\n') b.append(ctx.gpa, '\n') catch die(ctx, "out of memory", .{});
    b.appendSlice(ctx.gpa, moved) catch die(ctx, "out of memory", .{});
    ensureParent(ctx, dst);
    Dir.cwd().writeFile(ctx.io, .{ .sub_path = dst, .data = b.items }) catch |e|
        die(ctx, "cannot update '{s}': {s}", .{ dst, @errorName(e) });
}

/// Ask the user whether a found session should be moved into the selected account.
/// Example: typing "y" returns true; Enter or "n" returns false.
fn confirm(ctx: Context, program: []const u8, account: []const u8, id: []const u8, h: Hit) bool {
    warn(ctx, "{s} session {s} is in {s}, not account '{s}'", .{ program, id, h.label, account });
    warn(ctx, "move it into '{s}'? [y/N]", .{account});
    var buf: [32]u8 = undefined;
    const n = std.Io.File.stdin().readStreaming(ctx.io, &.{buf[0..]}) catch return false;
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return answer.len != 0 and (answer[0] == 'y' or answer[0] == 'Y');
}

/// Move the session JSONL, optional Claude sidecar directory, and history lines.
/// Example: moveHit(..., dst=".claude", uuid) moves projects/.../uuid.jsonl and history.
fn moveHit(ctx: Context, h: Hit, dst_root: []const u8, id: []const u8) void {
    Dir.cwd().createDirPath(ctx.io, dst_root) catch |e| die(ctx, "cannot create '{s}': {s}", .{ dst_root, @errorName(e) });
    moveOne(ctx, join(ctx, &.{ h.root, h.rel }), join(ctx, &.{ dst_root, h.rel }));
    if (h.sidecar) |s| {
        const src = join(ctx, &.{ h.root, s });
        if (exists(ctx, src)) moveOne(ctx, src, join(ctx, &.{ dst_root, s }));
    }
    moveHistory(ctx, h.root, dst_root, id);
}

/// Adopt an explicit resume id into the selected account if it lives in another profile.
/// Example: launching claude-1-work with "--resume UUID" can move UUID from claude-2-cn.
pub fn maybeAdopt(ctx: Context, program: *const Program, account: []const u8, folder: []const u8, args: [][]const u8) void {
    const m = mode(program.name) orelse return;
    const id = resumeId(m, args) orelse return;
    const target = stateRoot(ctx, program, folder);
    if (find(ctx, target, m, id) != null) return;

    var found: ?Hit = null;
    if (program.pairs.len == 1) {
        if (ctx.env.get(program.pairs[0].name)) |r| remember(ctx, &found, r, r, target, m, id);
        if (ctx.env.get("HOME")) |home| {
            const r = join(ctx, &.{ home, program.pairs[0].dir });
            remember(ctx, &found, r, r, target, m, id);
        }
    }
    var d = Dir.cwd().openDir(ctx.io, ctx.install_root, .{ .iterate = true }) catch |e|
        die(ctx, "cannot open install dir '{s}': {s}", .{ ctx.install_root, @errorName(e) });
    var it = d.iterate();
    while (it.next(ctx.io) catch |e| die(ctx, "cannot scan directory: {s}", .{@errorName(e)})) |entry| {
        if (entry.kind != .directory or !manifest.isAccountFolder(program, entry.name)) continue;
        const r = stateRoot(ctx, program, join(ctx, &.{ ctx.install_root, entry.name }));
        remember(ctx, &found, entry.name, r, target, m, id);
    }

    const h = found orelse return;
    if (!confirm(ctx, program.name, account, id, h)) die(ctx, "resume adoption declined", .{});
    moveHit(ctx, h, target, id);
    if (find(ctx, target, m, id) == null) die(ctx, "moved {s}, but target cannot see it", .{id});
    warn(ctx, "moved session {s} from {s} into {s}", .{ id, h.label, account });
}
