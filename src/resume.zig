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
pub const PsRow = struct {
    account: []const u8,
    id: []const u8,
    topic: []const u8,
    start: i64 = 0,
    seen: i64 = 0,
    modified: i64,
};
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

/// Return the state directory for an account folder.
/// Example: stateRoot(ctx, claude, "/accounts/claude-1-work") returns ".../.claude".
pub fn stateRoot(ctx: Context, program: *const Program, folder: []const u8) []const u8 {
    if (program.pairs.len != 1) die(ctx, "'{s}' must have exactly one state dir", .{program.name});
    return join(ctx, &.{ folder, program.pairs[0].dir });
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

/// Read a session-sized file; missing files are ignored because sessions can move.
/// Example: readSession(ctx, "uuid.jsonl") returns its bytes or null.
fn readSession(ctx: Context, p: []const u8) ?[]const u8 {
    return Dir.cwd().readFileAlloc(ctx.io, p, ctx.gpa, .limited(8 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => die(ctx, "cannot read '{s}': {s}", .{ p, @errorName(e) }),
    };
}

/// Collapse whitespace and cap a topic so rows stay one line.
/// Example: topic(ctx, "  hello\nworld") returns "hello world".
fn topic(ctx: Context, raw: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    var prev_space = false;
    var it = std.unicode.Utf8Iterator{ .bytes = std.mem.trim(u8, raw, " \t\r\n"), .i = 0 };
    while (it.nextCodepointSlice()) |cp| {
        const is_space = cp.len == 1 and (cp[0] == ' ' or cp[0] == '\t' or cp[0] == '\r' or cp[0] == '\n');
        if (is_space) {
            if (b.items.len != 0 and !prev_space) b.append(ctx.gpa, ' ') catch die(ctx, "out of memory", .{});
            prev_space = true;
            continue;
        }
        if (b.items.len + cp.len > 52) {
            b.appendSlice(ctx.gpa, "...") catch die(ctx, "out of memory", .{});
            break;
        }
        b.appendSlice(ctx.gpa, cp) catch die(ctx, "out of memory", .{});
        prev_space = false;
    }
    return b.toOwnedSlice(ctx.gpa) catch die(ctx, "out of memory", .{});
}

/// Return a string field from a parsed JSON object.
/// Example: field(v, "timestamp") returns the timestamp string if present.
fn field(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

/// Return the first text string in a Claude user message.
/// Example: userText(v) returns message.content or message.content[].text.
fn userText(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    if (v.object.get("payload")) |payload| if (payload == .object) {
        if (payload.object.get("text")) |t| if (t == .string) return t.string;
    };
    const msg = v.object.get("message") orelse return null;
    if (msg != .object) return null;
    const content = msg.object.get("content") orelse return null;
    switch (content) {
        .string => |s| return s,
        .object => |o| if (o.get("text")) |t| if (t == .string) return t.string,
        .array => |a| for (a.items) |item| {
            if (item != .object) continue;
            if (item.object.get("text")) |t| if (t == .string) return t.string;
        },
        else => {},
    }
    return null;
}

/// Parse the UTC timestamp prefix Claude stores on JSONL rows.
/// Example: iso("2026-06-24T10:29:04.123Z") returns POSIX seconds.
fn iso(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 60) return null;

    var days: i64 = 0;
    var y: u16 = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    if (day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    return (days + day - 1) * std.time.epoch.secs_per_day +
        @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

/// Pull topic and timestamps from one Claude session file.
/// Example: session(ctx, "work", uuid, "uuid.jsonl", 0) returns a ps row.
fn jsonlSession(ctx: Context, account: []const u8, id: []const u8, file_path: []const u8, modified: i64, cwd: ?[]const u8) ?PsRow {
    const data = readSession(ctx, file_path) orelse return null;
    var match_cwd = cwd == null;
    var session_id = id;
    var row = PsRow{
        .account = ctx.gpa.dupe(u8, account) catch die(ctx, "out of memory", .{}),
        .id = "",
        .topic = "",
        .modified = modified,
    };
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.gpa, line, .{}) catch continue;
        if (field(v, "type")) |typ| if (std.mem.eql(u8, typ, "session_meta")) {
            if (v.object.get("payload")) |p| if (p == .object) {
                if (p.object.get("session_id")) |sid| {
                    if (sid == .string) session_id = sid.string;
                }
                if (p.object.get("id")) |sid| {
                    if (sid == .string) session_id = sid.string;
                }
                if (p.object.get("cwd")) |c| {
                    if (c == .string and cwd != null and std.mem.eql(u8, c.string, cwd.?)) match_cwd = true;
                }
                if (p.object.get("timestamp")) |ts| if (ts == .string) if (iso(ts.string)) |t| {
                    if (row.start == 0) row.start = t;
                    row.seen = t;
                };
            };
        };
        if (field(v, "timestamp")) |ts| if (iso(ts)) |t| {
            if (row.start == 0) row.start = t;
            row.seen = t;
        };
        if (field(v, "summary")) |s| row.topic = topic(ctx, s);
        const typ = field(v, "type") orelse "";
        if (row.topic.len == 0 and (std.mem.eql(u8, typ, "user") or std.mem.eql(u8, typ, "user_message"))) {
            if (userText(v)) |s| row.topic = topic(ctx, s);
        }
    }
    row.id = ctx.gpa.dupe(u8, session_id) catch die(ctx, "out of memory", .{});
    return if (match_cwd) row else null;
}

/// Convert the current cwd into Claude's projects/ directory name.
/// Example: projectName(ctx, "/tmp/work") returns "-tmp-work".
fn projectName(ctx: Context, cwd: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    for (cwd) |c| b.append(ctx.gpa, if (c == '/' or c == '\\') '-' else c) catch die(ctx, "out of memory", .{});
    return b.toOwnedSlice(ctx.gpa) catch die(ctx, "out of memory", .{});
}

/// Extract the session id from a Claude session basename.
/// Example: claudeId("UUID.jsonl") returns "UUID".
fn claudeId(basename: []const u8) ?[]const u8 {
    if (basename.len != 36 + ".jsonl".len or !std.mem.endsWith(u8, basename, ".jsonl")) return null;
    return if (isUuid(basename[0..36])) basename[0..36] else null;
}

/// Extract an id from a Codex JSONL basename.
/// Example: codexId("rollout-...-UUID.jsonl") returns the UUID-ish tail.
fn codexId(basename: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, basename, ".jsonl")) return null;
    const stem = basename[0 .. basename.len - ".jsonl".len];
    if (stem.len < 36) return stem;
    var i: usize = 0;
    while (i + 36 <= stem.len) : (i += 1) {
        if (isUuid(stem[i .. i + 36])) return stem[i .. i + 36];
    }
    return stem;
}

/// Format POSIX seconds as compact UTC time.
/// Example: fmtTime(ctx, 1) returns "1970-01-01 00:00Z".
fn fmtTime(ctx: Context, secs: i64) []const u8 {
    if (secs <= 0) return "-";
    const ep = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const yd = ep.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = ep.getDaySeconds();
    return std.fmt.allocPrint(ctx.gpa, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    }) catch die(ctx, "out of memory", .{});
}

/// Format a duration as h/m/s.
/// Example: fmtDuration(ctx, 0, 3661) returns "1h01m".
fn fmtDuration(ctx: Context, start: i64, seen: i64) []const u8 {
    if (start <= 0 or seen < start) return "-";
    var delta: u64 = @intCast(seen - start);
    const days = delta / 86400;
    delta %= 86400;
    const hours = delta / 3600;
    delta %= 3600;
    const minutes = delta / 60;
    const seconds = delta % 60;
    if (days != 0) return std.fmt.allocPrint(ctx.gpa, "{d}d{d:0>2}h", .{ days, hours }) catch die(ctx, "out of memory", .{});
    if (hours != 0) return std.fmt.allocPrint(ctx.gpa, "{d}h{d:0>2}m", .{ hours, minutes }) catch die(ctx, "out of memory", .{});
    if (minutes != 0) return std.fmt.allocPrint(ctx.gpa, "{d}m{d:0>2}s", .{ minutes, seconds }) catch die(ctx, "out of memory", .{});
    return std.fmt.allocPrint(ctx.gpa, "{d}s", .{seconds}) catch die(ctx, "out of memory", .{});
}

/// Append rows from a recursive JSONL session tree.
/// Example: jsonlPs(ctx, codex, ".../.codex", cwd, &rows) scans Codex sessions.
fn jsonlPs(ctx: Context, account: []const u8, root: []const u8, cwd: ?[]const u8, rows: *std.ArrayList(PsRow), comptime idFn: fn ([]const u8) ?[]const u8) void {
    var dir = Dir.cwd().openDir(ctx.io, root, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);
    var w = dir.walk(ctx.gpa) catch return;
    defer w.deinit();
    while (w.next(ctx.io) catch |e| die(ctx, "cannot scan '{s}': {s}", .{ root, @errorName(e) })) |e| {
        if (e.kind != .file) continue;
        const id = idFn(e.basename) orelse continue;
        const file_path = join(ctx, &.{ root, e.path });
        const st = Dir.cwd().statFile(ctx.io, file_path, .{}) catch continue;
        const modified: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
        if (jsonlSession(ctx, account, id, file_path, modified, cwd)) |row|
            rows.append(ctx.gpa, row) catch die(ctx, "out of memory", .{});
    }
}

/// Order sessions by latest activity, newest first.
/// Example: used by `ma claude ps` before printing rows.
fn newer(_: void, a: PsRow, b: PsRow) bool {
    const at = if (a.seen != 0) a.seen else a.modified;
    const bt = if (b.seen != 0) b.seen else b.modified;
    return if (at == bt) std.mem.lessThan(u8, a.id, b.id) else at > bt;
}

/// Add Claude sessions for cwd from one account.
/// Example: ps(ctx, claude, ".../claude-1-work", "work", "/tmp/work", &rows).
pub fn ps(ctx: Context, program: *const Program, account_dir: []const u8, account: []const u8, cwd: []const u8, rows: *std.ArrayList(PsRow)) void {
    if (std.mem.eql(u8, program.name, "claude")) {
        jsonlPs(ctx, account, join(ctx, &.{ stateRoot(ctx, program, account_dir), "projects", projectName(ctx, cwd) }), null, rows, claudeId);
    } else if (std.mem.eql(u8, program.name, "codex")) {
        jsonlPs(ctx, account, join(ctx, &.{ stateRoot(ctx, program, account_dir), "sessions" }), cwd, rows, codexId);
    } else {
        die(ctx, "'{s} ps' is not supported", .{program.name});
    }
}

/// Print collected ps rows as a table.
/// Example: printPs(ctx, "claude", "/repo", rows.items) prints the session list.
pub fn printPs(ctx: Context, program: []const u8, cwd: []const u8, rows: []PsRow) void {
    std.mem.sort(PsRow, rows, {}, newer);
    if (rows.len == 0) {
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "no {s} sessions for {s}\n", .{ program, cwd }) catch return;
        std.Io.File.stdout().writeStreamingAll(ctx.io, s) catch {};
        return;
    }

    var header: [4096]u8 = undefined;
    const hs = std.fmt.bufPrint(&header, "{s:<16} {s:<36} {s:<17} {s:<17} {s:<8} {s}\n", .{
        "ACCOUNT", "SESSION", "LAST SEEN", "START", "DURATION", "TOPIC",
    }) catch return;
    std.Io.File.stdout().writeStreamingAll(ctx.io, hs) catch {};
    for (rows) |row| {
        var line: [4096]u8 = undefined;
        const seen = if (row.seen != 0) row.seen else row.modified;
        const s = std.fmt.bufPrint(&line, "{s:<16} {s:<36} {s:<17} {s:<17} {s:<8} {s}\n", .{
            row.account,
            row.id,
            fmtTime(ctx, seen),
            fmtTime(ctx, row.start),
            fmtDuration(ctx, row.start, row.seen),
            if (row.topic.len == 0) "(untitled)" else row.topic,
        }) catch return;
        std.Io.File.stdout().writeStreamingAll(ctx.io, s) catch {};
    }
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
        const account_dir = join(ctx, &.{ ctx.install_root, entry.name });
        const r = stateRoot(ctx, program, account_dir);
        remember(ctx, &found, entry.name, r, target, m, id);
    }

    const h = found orelse return;
    if (!confirm(ctx, program.name, account, id, h)) die(ctx, "resume adoption declined", .{});
    moveHit(ctx, h, target, id);
    if (find(ctx, target, m, id) == null) die(ctx, "moved {s}, but target cannot see it", .{id});
    warn(ctx, "moved session {s} from {s} into {s}", .{ id, h.label, account });
}
