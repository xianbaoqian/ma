const std = @import("std");
const manifest = @import("manifest.zig");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const path = std.fs.path;

const Program = manifest.Program;
const Parsed = manifest.Parsed;

pub const Context = struct {
    io: Io,
    gpa: Allocator,
    env: *std.process.Environ.Map,
    install_root: []const u8,
};

const Variant = struct {
    name: []const u8,
    added_at: i64,
    last_rotated_at: i64,
    implicit: bool = false,
};

const State = struct {
    current: ?[]const u8 = null,
    variants: *[max_auth_tokens]Variant,
    len: usize = 0,
};

const Account = struct {
    folder: []const u8,
    account: []const u8,
    path: []const u8,
};

const AccountFind = struct {
    key: ?[]const u8,
    key_id: ?u32,
    count: usize = 0,
    first: ?Account = null,
    second_folder: ?[]const u8 = null,
    first_folder_buf: [max_account_folder_len]u8 = undefined,
    first_account_buf: [max_account_folder_len]u8 = undefined,
    second_folder_buf: [max_account_folder_len]u8 = undefined,
};

const AccountCount = struct { key: []const u8, key_id: ?u32, count: usize = 0 };

const codex_artifacts = [_][]const u8{"auth.json"};
const claude_artifacts = [_][]const u8{".credentials.json"};
pub const codex_file_auth_override = "cli_auth_credentials_store=file";
const codex_cred_env = [_][]const u8{ "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN" };
const claude_cred_env = [_][]const u8{
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_FOUNDRY_API_KEY",
    "ANTHROPIC_AWS_API_KEY",
    "ANTHROPIC_BEDROCK_MANTLE_API_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
    "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
    "CLAUDE_CODE_OAUTH_SCOPES",
    "CLAUDE_CODE_OAUTH_CLIENT_ID",
    "CLAUDE_CODE_SESSION_ACCESS_TOKEN",
};
const claude_secure_storage_env = "CLAUDE_SECURESTORAGE_CONFIG_DIR";
const claude_metadata_fields = [_][]const u8{
    "emailAddress",
    "displayName",
    "accountUuid",
    "organizationUuid",
    "organizationName",
    "organizationRole",
    "workspaceUuid",
    "workspaceName",
    "subscriptionType",
    "billingType",
    "kind",
};
pub const claude_config_scan_limit = 512 << 10;
pub const auth_file_read_limit = 16 << 20;
pub const max_auth_tokens = 4096;
pub const max_token_name_len = 256;
const max_account_folder_len = 1024;
const max_accounts_overflow = std.math.maxInt(usize);
const recent_window_secs = 10 * 60;
const check_timeout: Io.Timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 30 * std.time.ns_per_s }, .clock = .real } };
const ping_timeout: Io.Timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .real } };
const short_fingerprint_len = 8;
const auto_stage_variant = ".new-token";
const claude_file_auth_bin = ".ma-file-auth-bin";
const claude_file_auth_log_env = "MA_CLAUDE_FILE_AUTH_LOG";
const ping_prompt = "Reply exactly with the single word: pong";

const CheckStatus = enum {
    ok,
    limited,
    invalid,
    unknown,
};

const CheckResult = struct {
    status: CheckStatus,
    identity: []const u8 = "unknown",
    message: []const u8 = "",
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

const ObjectRange = struct {
    start: usize,
    end: usize,
};

const NextVariant = struct {
    idx: ?usize = null,
    saw_cooldown: bool = false,
    saw_duplicate: bool = false,
    saw_invalid: bool = false,
};

/// Print an auth/module error to stderr and exit with status 1.
/// Example: die(ctx, "unknown program", .{}) prints "ma: unknown program".
fn die(ctx: Context, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "ma: " ++ fmt ++ "\n", args) catch "ma: error\n";
    std.Io.File.stderr().writeStreamingAll(ctx.io, s) catch {};
    std.process.exit(1);
}

/// Print an auth warning to stderr.
/// Example: warn(ctx, "rotated {s}", .{"codex"}) prints a ma-prefixed warning.
fn warn(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "ma: " ++ fmt ++ "\n", args) catch "ma: warning\n";
    std.Io.File.stderr().writeStreamingAll(ctx.io, s) catch {};
}

/// Write formatted text to stdout.
/// Example: out(ctx, "added {s}\n", .{"work"}) prints a status line.
fn out(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(ctx.io, s) catch {};
}

/// Join path fragments using the auth context allocator.
/// Example: join(ctx, &.{"a","b"}) returns "a/b".
fn join(ctx: Context, parts: []const []const u8) []const u8 {
    return path.join(ctx.gpa, parts) catch die(ctx, "static workspace exhausted", .{});
}

/// Return the manifest context used by account parsing helpers.
/// Example: manifestContext(ctx) points manifest at the install root.
fn manifestContext(ctx: Context) manifest.Context {
    return .{ .io = ctx.io, .gpa = ctx.gpa, .root = ctx.install_root };
}

/// Return whether a program supports file-backed auth tokens.
/// Example: supported("codex") and supported("claude") return true.
fn supported(program: []const u8) bool {
    return std.mem.eql(u8, program, "codex") or std.mem.eql(u8, program, "claude");
}

/// Return auth artifact names for a supported program.
/// Example: artifacts("codex") returns auth.json.
fn artifacts(program: []const u8) []const []const u8 {
    if (std.mem.eql(u8, program, "codex")) return &codex_artifacts;
    if (std.mem.eql(u8, program, "claude")) return &claude_artifacts;
    return &.{};
}

/// Return credential environment variables that make file rotation unsafe.
/// Example: credentialEnv("claude") includes ANTHROPIC_API_KEY.
fn credentialEnv(program: []const u8) []const []const u8 {
    if (std.mem.eql(u8, program, "codex")) return &codex_cred_env;
    if (std.mem.eql(u8, program, "claude")) return &claude_cred_env;
    return &.{};
}

/// Return the single state dir for a program account.
/// Example: stateRoot(ctx, codex, "codex-1-work") returns ".../.codex".
fn stateRoot(ctx: Context, program: *const Program, account_dir: []const u8) []const u8 {
    if (program.pairs.len != 1) die(ctx, "'{s}' auth rotation needs exactly one state dir", .{program.name});
    return join(ctx, &.{ account_dir, program.pairs[0].dir });
}

/// Validate a token slot name before it becomes a path segment.
/// Example: "work" is valid; "../work" is rejected.
fn validateVariant(ctx: Context, variant: []const u8) void {
    if (variant.len == 0 or std.mem.eql(u8, variant, ".") or std.mem.eql(u8, variant, ".."))
        die(ctx, "invalid auth token slot '{s}'", .{variant});
    if (variant.len > max_token_name_len)
        die(ctx, "auth token slot '{s}' is too long (max {d} bytes)", .{ variant, max_token_name_len });
    for (variant) |c| {
        if (c == '/' or c == '\\' or c == '\t' or c == '\n' or c == '\r')
            die(ctx, "invalid auth token slot '{s}'", .{variant});
    }
}

/// Return whether a token slot name is valid without reporting an error.
/// Example: variantNameOk("a/b") returns false.
fn variantNameOk(variant: []const u8) bool {
    if (variant.len == 0 or std.mem.eql(u8, variant, ".") or std.mem.eql(u8, variant, "..")) return false;
    for (variant) |c| {
        if (c == '/' or c == '\\' or c == '\t' or c == '\n' or c == '\r') return false;
    }
    return true;
}

/// Test whether a path exists.
/// Example: exists(ctx, "/tmp/auth.json") returns true after the file is written.
fn exists(ctx: Context, p: []const u8) bool {
    Dir.cwd().access(ctx.io, p, .{}) catch return false;
    return true;
}

/// Read a file if it exists, returning null for FileNotFound.
/// Example: readOpt(ctx, "missing") returns null.
fn readOpt(ctx: Context, p: []const u8) ?[]const u8 {
    return Dir.cwd().readFileAlloc(ctx.io, p, ctx.gpa, .limited(auth_file_read_limit)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => die(ctx, "cannot read '{s}': {s}", .{ p, @errorName(e) }),
    };
}

/// Create the parent directory for a path, if any.
/// Example: ensureParent(ctx, "/a/b/c") creates "/a/b".
fn ensureParent(ctx: Context, p: []const u8) void {
    const d = path.dirname(p) orelse return;
    Dir.cwd().createDirPath(ctx.io, d) catch |e| die(ctx, "cannot create '{s}': {s}", .{ d, @errorName(e) });
}

/// Copy one auth artifact without touching unrelated settings files.
/// Example: copyFile(ctx, "token/auth.json", "state/auth.json") overwrites auth only.
fn copyFile(ctx: Context, src: []const u8, dst: []const u8) void {
    const data = readOpt(ctx, src) orelse die(ctx, "missing auth artifact '{s}'", .{src});
    ensureParent(ctx, dst);
    Dir.cwd().writeFile(ctx.io, .{ .sub_path = dst, .data = data }) catch |e|
        die(ctx, "cannot write '{s}': {s}", .{ dst, @errorName(e) });
}

/// Remove a directory tree if present.
/// Example: removeTree(ctx, ".codex/ma-auth/bad") ignores a missing token slot.
fn removeTree(ctx: Context, p: []const u8) void {
    if (!exists(ctx, p)) return;
    Dir.cwd().deleteTree(ctx.io, p) catch |e|
        die(ctx, "cannot remove '{s}': {s}", .{ p, @errorName(e) });
}

/// Move a directory tree to a new path without overwriting.
/// Example: renameTree(ctx, "ma-auth/.new-token", "ma-auth/user") makes the slot final.
fn renameTree(ctx: Context, src: []const u8, dst: []const u8) void {
    if (exists(ctx, dst)) die(ctx, "refusing to overwrite '{s}'", .{dst});
    ensureParent(ctx, dst);
    Dir.renameAbsolute(src, dst, ctx.io) catch |e|
        die(ctx, "cannot move '{s}' to '{s}': {s}", .{ src, dst, @errorName(e) });
}

/// Remove an active auth artifact if present.
/// Example: removeFile(ctx, ".codex/auth.json") ignores missing files.
fn removeFile(ctx: Context, p: []const u8) void {
    Dir.cwd().deleteFile(ctx.io, p) catch |e| switch (e) {
        error.FileNotFound => {},
        else => die(ctx, "cannot remove '{s}': {s}", .{ p, @errorName(e) }),
    };
}

/// Return whether a path is a symlink.
/// Example: live Codex auth.json is a symlink after ma rotation.
fn isSymlink(ctx: Context, p: []const u8) bool {
    var buf: [4096]u8 = undefined;
    _ = Dir.cwd().readLink(ctx.io, p, &buf) catch return false;
    return true;
}

/// Return a token with surrounding whitespace trimmed.
/// Example: trimToken(" abc\n") returns "abc".
fn trimToken(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Find a needle in ASCII text without case sensitivity.
/// Example: asciiIndexOfIgnoreCase("Weekly Limit", "limit") returns an index.
fn asciiIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return i;
    }
    return null;
}

/// Duplicate a JSON string field from an object.
/// Example: jsonStringField(ctx, obj, "email") returns an owned email string.
fn jsonStringField(ctx: Context, obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return ctx.gpa.dupe(u8, v.string) catch die(ctx, "static workspace exhausted", .{});
}

/// Parse a JSON object file if it exists.
/// Example: readJsonObject(ctx, "auth.json") returns its object root.
fn readJsonObject(ctx: Context, p: []const u8) ?std.json.Value {
    const data = readOpt(ctx, p) orelse return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.gpa, data, .{}) catch return null;
    if (v != .object) return null;
    return v;
}

/// Return the byte range of a JSON object value after a key.
/// Example: objectValueRange(data, "\"oauthAccount\"") locates its object value.
fn objectValueRange(data: []const u8, key: []const u8) ?ObjectRange {
    const key_pos = std.mem.indexOf(u8, data, key) orelse return null;
    const colon_rel = std.mem.indexOfScalar(u8, data[key_pos + key.len ..], ':') orelse return null;
    var i = key_pos + key.len + colon_rel + 1;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\r' or data[i] == '\n')) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return null;

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var j = i;
    while (j < data.len) : (j += 1) {
        const c = data[j];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return .{ .start = i, .end = j + 1 };
        }
    }
    return null;
}

/// Return a small JSON object slice starting at a key's object value.
/// Example: objectValueSlice(data, "\"oauthAccount\"") returns {"emailAddress":...}.
fn objectValueSlice(data: []const u8, key: []const u8) ?[]const u8 {
    const r = objectValueRange(data, key) orelse return null;
    return data[r.start..r.end];
}

/// Read just Claude's oauthAccount object without parsing a large config file.
/// Example: readClaudeOauth(ctx, ".claude/.claude.json") returns selected account JSON.
fn readClaudeOauth(ctx: Context, p: []const u8) ?std.json.Value {
    const data = Dir.cwd().readFileAlloc(ctx.io, p, ctx.gpa, .limited(claude_config_scan_limit)) catch |e| switch (e) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => die(ctx, "cannot read '{s}': {s}", .{ p, @errorName(e) }),
    };
    const oauth_slice = objectValueSlice(data, "\"oauthAccount\"") orelse return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.gpa, oauth_slice, .{}) catch return null;
    if (v != .object) return null;
    return v;
}

/// Write selected Claude oauthAccount fields as a small standalone config artifact.
/// Example: writeClaudeOauthArtifact(ctx, oauth, dst) writes {"oauthAccount":{...}}.
fn writeClaudeOauthArtifact(ctx: Context, oauth: std.json.Value, dst: []const u8) void {
    var out_buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);
    var js: std.json.Stringify = .{ .writer = &writer };
    js.beginObject() catch die(ctx, "cannot encode Claude auth metadata", .{});
    js.objectField("oauthAccount") catch die(ctx, "cannot encode Claude auth metadata", .{});
    js.beginObject() catch die(ctx, "cannot encode Claude auth metadata", .{});
    for (claude_metadata_fields) |field| {
        if (oauth.object.get(field)) |value| {
            if (value != .string or value.string.len == 0) continue;
            js.objectField(field) catch die(ctx, "cannot encode Claude auth metadata", .{});
            js.write(value.string) catch die(ctx, "cannot encode Claude auth metadata", .{});
        }
    }
    js.endObject() catch die(ctx, "cannot encode Claude auth metadata", .{});
    js.endObject() catch die(ctx, "cannot encode Claude auth metadata", .{});
    writer.writeByte('\n') catch die(ctx, "cannot encode Claude auth metadata", .{});

    ensureParent(ctx, dst);
    Dir.cwd().writeFile(ctx.io, .{ .sub_path = dst, .data = writer.buffered() }) catch |e|
        die(ctx, "cannot write '{s}': {s}", .{ dst, @errorName(e) });
}

/// Replace only Claude's shared oauthAccount object, preserving other config fields.
/// Example: applyClaudeMetadata(ctx, root, slot) updates root/.claude.json from slot/.claude.json.
fn applyClaudeMetadata(ctx: Context, root: []const u8, src_dir: []const u8) void {
    const src = join(ctx, &.{ src_dir, ".claude.json" });
    const src_data = readOpt(ctx, src) orelse return;
    const src_range = objectValueRange(src_data, "\"oauthAccount\"") orelse return;
    const oauth = readClaudeOauth(ctx, src) orelse return;
    const live = join(ctx, &.{ root, ".claude.json" });
    const live_data = readOpt(ctx, live);
    if (live_data) |data| {
        if (objectValueRange(data, "\"oauthAccount\"")) |r| {
            var b: std.ArrayList(u8) = .empty;
            b.appendSlice(ctx.gpa, data[0..r.start]) catch die(ctx, "static workspace exhausted", .{});
            b.appendSlice(ctx.gpa, src_data[src_range.start..src_range.end]) catch die(ctx, "static workspace exhausted", .{});
            b.appendSlice(ctx.gpa, data[r.end..]) catch die(ctx, "static workspace exhausted", .{});
            Dir.cwd().writeFile(ctx.io, .{ .sub_path = live, .data = b.items }) catch |e|
                die(ctx, "cannot write '{s}': {s}", .{ live, @errorName(e) });
            return;
        }
        var start: usize = 0;
        while (start < data.len and (data[start] == ' ' or data[start] == '\t' or data[start] == '\r' or data[start] == '\n')) : (start += 1) {}
        var end = data.len;
        while (end > start and (data[end - 1] == ' ' or data[end - 1] == '\t' or data[end - 1] == '\r' or data[end - 1] == '\n')) : (end -= 1) {}
        if (end >= start + 2 and data[start] == '{' and data[end - 1] == '}') {
            var b: std.ArrayList(u8) = .empty;
            b.appendSlice(ctx.gpa, data[0 .. end - 1]) catch die(ctx, "static workspace exhausted", .{});
            if (std.mem.trim(u8, data[start + 1 .. end - 1], " \t\r\n").len != 0)
                b.append(ctx.gpa, ',') catch die(ctx, "static workspace exhausted", .{});
            b.appendSlice(ctx.gpa, "\"oauthAccount\":") catch die(ctx, "static workspace exhausted", .{});
            b.appendSlice(ctx.gpa, src_data[src_range.start..src_range.end]) catch die(ctx, "static workspace exhausted", .{});
            b.appendSlice(ctx.gpa, data[end - 1 ..]) catch die(ctx, "static workspace exhausted", .{});
            Dir.cwd().writeFile(ctx.io, .{ .sub_path = live, .data = b.items }) catch |e|
                die(ctx, "cannot write '{s}': {s}", .{ live, @errorName(e) });
            return;
        }
    }
    writeClaudeOauthArtifact(ctx, oauth, live);
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
    }) catch die(ctx, "static workspace exhausted", .{});
}

/// Return a short, non-secret display prefix.
/// Example: shortPrefix("abcdef", 4) returns "abcd".
fn shortPrefix(s: []const u8, comptime n: usize) []const u8 {
    if (s.len <= n) return s;
    return s[0..n];
}

/// Return an 8-byte hex digest for a local auth file.
/// Example: fileDigest(ctx, "auth.json") returns a local fingerprint, not the token.
fn fileDigest(ctx: Context, p: []const u8) []const u8 {
    const data = readOpt(ctx, p) orelse return "-";
    const h = std.hash.Wyhash.hash(0, data);
    return std.fmt.allocPrint(ctx.gpa, "{x:0>16}", .{h}) catch die(ctx, "static workspace exhausted", .{});
}

/// Return Codex's strongest local credential string from auth.json.
/// Example: prefer refresh_token, then access_token, then id_token.
fn codexCredential(ctx: Context, dir: []const u8) ?[]const u8 {
    const v = readJsonObject(ctx, join(ctx, &.{ dir, "auth.json" })) orelse return null;
    const tokens = if (v.object.get("tokens")) |t| t else return null;
    if (tokens != .object) return null;
    return codexRefreshCredential(ctx, dir) orelse
        jsonStringField(ctx, tokens, "access_token") orelse
        jsonStringField(ctx, tokens, "id_token");
}

/// Return Codex's refresh-capable device-login credential from auth.json.
/// Example: device auth writes tokens.refresh_token.
fn codexRefreshCredential(ctx: Context, dir: []const u8) ?[]const u8 {
    const v = readJsonObject(ctx, join(ctx, &.{ dir, "auth.json" })) orelse return null;
    const tokens = if (v.object.get("tokens")) |t| t else return null;
    if (tokens != .object) return null;
    return jsonStringField(ctx, tokens, "refresh_token");
}

/// Return why a Codex auth slot is not a rotatable subscription/device login.
/// Example: API keys and personal access tokens cannot fall back by auth rotation.
fn codexAuthProblem(ctx: Context, dir: []const u8) ?[]const u8 {
    const v = readJsonObject(ctx, join(ctx, &.{ dir, "auth.json" })) orelse return "missing auth.json";
    if (hasApiKeyAuth(ctx, dir)) return "API-key auth is not rotatable";
    if (v.object.get("personal_access_token")) |_| return "personal access token auth is not rotatable";
    if (v.object.get("agent_identity")) |_| return "agent identity auth is not rotatable";
    if (v.object.get("bedrock_api_key")) |_| return "Bedrock API-key auth is not rotatable";
    if (v.object.get("auth_mode")) |mode| {
        if (mode != .string) return "Codex auth has invalid auth_mode";
        if (!std.ascii.eqlIgnoreCase(mode.string, "chatgpt"))
            return "Codex auth is not a refresh-capable device login";
    }
    if (codexRefreshCredential(ctx, dir) == null) return "missing Codex refresh token";
    return null;
}

/// Return Claude's refresh-capable local credential from .credentials.json.
/// Example: prefer refreshToken, then accessToken.
fn claudeCredential(ctx: Context, dir: []const u8) ?[]const u8 {
    const v = readJsonObject(ctx, join(ctx, &.{ dir, ".credentials.json" })) orelse return null;
    if (v.object.get("claudeAiOauth")) |oauth| {
        if (oauth == .object) {
            return jsonStringField(ctx, oauth, "refreshToken") orelse
                jsonStringField(ctx, oauth, "accessToken");
        }
    }
    return jsonStringField(ctx, v, "refreshToken") orelse
        jsonStringField(ctx, v, "accessToken");
}

/// Return whether two token slots contain the same login credential.
/// Example: two Claude slots with the same refresh token are equivalent.
fn sameAuthCredential(ctx: Context, program: []const u8, a_dir: []const u8, b_dir: []const u8) bool {
    if (std.mem.eql(u8, program, "claude")) {
        const a = claudeCredential(ctx, a_dir) orelse return false;
        const b = claudeCredential(ctx, b_dir) orelse return false;
        return a.len != 0 and std.mem.eql(u8, a, b);
    }
    if (std.mem.eql(u8, program, "codex")) {
        if (codexCredential(ctx, a_dir)) |a| {
            if (codexCredential(ctx, b_dir)) |b| return std.mem.eql(u8, a, b);
        }
        const a = readOpt(ctx, join(ctx, &.{ a_dir, "auth.json" })) orelse return false;
        const b = readOpt(ctx, join(ctx, &.{ b_dir, "auth.json" })) orelse return false;
        return a.len != 0 and std.mem.eql(u8, a, b);
    }
    return false;
}

/// Return an existing token slot with the same credential as a staged login.
/// Example: duplicateAuthToken(..., ".new-token") returns "default" for the same token.
fn duplicateAuthToken(ctx: Context, program: []const u8, root: []const u8, st: State, staged_dir: []const u8) ?[]const u8 {
    for (stateItems(st)) |v| {
        if (sameAuthCredential(ctx, program, variantDir(ctx, root, v.name), staged_dir)) return v.name;
    }
    return null;
}

/// Re-apply the current Claude token metadata after a temporary login run.
/// Example: a duplicate add restores the old oauthAccount before exiting.
fn restoreCurrentClaudeMetadata(ctx: Context, program: []const u8, root: []const u8, st: State) void {
    if (!std.mem.eql(u8, program, "claude")) return;
    const cur = st.current orelse return;
    installVariant(ctx, program, root, variantDir(ctx, root, cur));
}

/// Decode a JWT payload segment into JSON.
/// Example: identityFromJwt(ctx, "x.payload.y") reads email/name fields from payload.
fn jwtPayloadObject(ctx: Context, token: []const u8) ?std.json.Value {
    const first = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const rest = token[first + 1 ..];
    const second_rel = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const payload = rest[0..second_rel];
    if (payload.len == 0) return null;
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return null;
    var decoded_buf: [16 << 10]u8 = undefined;
    if (size > decoded_buf.len) return null;
    const decoded = decoded_buf[0..size];
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.gpa, decoded, .{}) catch return null;
    if (v != .object) return null;
    return v;
}

/// Infer a user label from common OAuth/JWT payload fields.
/// Example: prefer email, then preferred_username, then name, then sub.
fn identityFromJwt(ctx: Context, token: []const u8) ?[]const u8 {
    const v = jwtPayloadObject(ctx, token) orelse return null;
    return jsonStringField(ctx, v, "email") orelse
        jsonStringField(ctx, v, "preferred_username") orelse
        jsonStringField(ctx, v, "username") orelse
        jsonStringField(ctx, v, "name") orelse
        jsonStringField(ctx, v, "sub");
}

/// Return the stored current token slot name from a state.tsv buffer.
/// Example: "current\twork\n" returns "work".
fn currentFromState(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next() orelse continue;
        if (!std.mem.eql(u8, kind, "current")) continue;
        const cur = fields.next() orelse return null;
        if (cur.len == 0) return null;
        return cur;
    }
    return null;
}

/// Remove credential environment that would override a selected file-backed login.
/// Example: scrubCredentialEnv(child, "claude") removes CLAUDE_CODE_OAUTH_TOKEN.
fn scrubCredentialEnv(child_env: *std.process.Environ.Map, program: []const u8) void {
    for (credentialEnv(program)) |name| _ = child_env.swapRemove(name);
}

/// Create a PATH shim that makes Claude's macOS Keychain helper unavailable.
/// Example: ensureClaudeFileAuthPath(ctx, root) returns a bin dir containing "security".
fn ensureClaudeFileAuthPath(ctx: Context, root: []const u8) []const u8 {
    const bin = claudeFileAuthBin(ctx, root);
    Dir.cwd().createDirPath(ctx.io, bin) catch |e|
        die(ctx, "cannot create '{s}': {s}", .{ bin, @errorName(e) });
    const shim = join(ctx, &.{ bin, "security" });
    const data =
        "#!/bin/sh\n" ++
        "log_op() {\n" ++
        "  if [ -n \"${MA_CLAUDE_FILE_AUTH_LOG:-}\" ]; then\n" ++
        "    umask 077\n" ++
        "    printf '%s\\n' \"$1\" >> \"$MA_CLAUDE_FILE_AUTH_LOG\" 2>/dev/null || :\n" ++
        "  fi\n" ++
        "}\n" ++
        "decode_hex() {\n" ++
        "  h=$1\n" ++
        "  out=$2\n" ++
        "  case \"$h\" in ''|*[!0123456789abcdefABCDEF]*) return 1 ;; esac\n" ++
        "  [ $(( ${#h} % 2 )) -eq 0 ] || return 1\n" ++
        "  : > \"$out\" || return 1\n" ++
        "  while [ -n \"$h\" ]; do\n" ++
        "    p=${h%${h#??}}\n" ++
        "    h=${h#??}\n" ++
        "    printf '%b' \"\\\\x$p\" >> \"$out\" || return 1\n" ++
        "  done\n" ++
        "}\n" ++
        "capture_credentials() {\n" ++
        "  [ -n \"${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}\" ] || return 1\n" ++
        "  [ -n \"$1\" ] || return 1\n" ++
        "  umask 077\n" ++
        "  mkdir -p \"$CLAUDE_SECURESTORAGE_CONFIG_DIR\" || return 1\n" ++
        "  tmp=\"$CLAUDE_SECURESTORAGE_CONFIG_DIR/.credentials.json.tmp.$$\"\n" ++
        "  decode_hex \"$1\" \"$tmp\" || { rm -f \"$tmp\"; return 1; }\n" ++
        "  grep -F '\"claudeAiOauth\"' \"$tmp\" >/dev/null 2>&1 || { rm -f \"$tmp\"; return 1; }\n" ++
        "  chmod 600 \"$tmp\" 2>/dev/null || :\n" ++
        "  mv -f \"$tmp\" \"$CLAUDE_SECURESTORAGE_CONFIG_DIR/.credentials.json\" || { rm -f \"$tmp\"; return 1; }\n" ++
        "  log_op write-credentials\n" ++
        "}\n" ++
        "stdin_cmd=\n" ++
        "op=${1:-}\n" ++
        "hex=\n" ++
        "if [ \"$op\" = -i ]; then\n" ++
        "  IFS= read -r stdin_cmd || stdin_cmd=\n" ++
        "  while IFS= read -r _; do :; done\n" ++
        "  case \"$stdin_cmd\" in\n" ++
        "    add-generic-password*) op=add-generic-password ;;\n" ++
        "    delete-generic-password*) op=delete-generic-password ;;\n" ++
        "    find-generic-password*) op=find-generic-password ;;\n" ++
        "  esac\n" ++
        "  if [ \"$op\" = add-generic-password ]; then\n" ++
        "    hex=$(printf '%s\\n' \"$stdin_cmd\" | sed -n 's/.* -X \"\\([0-9A-Fa-f][0-9A-Fa-f]*\\)\".*/\\1/p')\n" ++
        "  fi\n" ++
        "elif [ \"$op\" = add-generic-password ]; then\n" ++
        "  want=\n" ++
        "  for arg in \"$@\"; do\n" ++
        "    if [ \"$want\" = 1 ]; then hex=$arg; break; fi\n" ++
        "    [ \"$arg\" = -X ] && want=1\n" ++
        "  done\n" ++
        "fi\n" ++
        "case \"$op\" in\n" ++
        "  find-generic-password|show-keychain-info|add-generic-password|delete-generic-password) safe_op=$op ;;\n" ++
        "  *) safe_op=other ;;\n" ++
        "esac\n" ++
        "log_op \"$safe_op\"\n" ++
        "case \"$op\" in\n" ++
        "  find-generic-password)\n" ++
        "    echo 'security: SecKeychainSearchCreateFromAttributes: One or more parameters passed to a function were not valid.' >&2\n" ++
        "    echo 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.' >&2\n" ++
        "    exit 44\n" ++
        "    ;;\n" ++
        "  show-keychain-info)\n" ++
        "    echo 'security: SecKeychainCopySettings <NULL>: One or more parameters passed to a function were not valid.' >&2\n" ++
        "    exit 206\n" ++
        "    ;;\n" ++
        "  delete-generic-password)\n" ++
        "    echo 'security: SecKeychainSearchCreateFromAttributes: One or more parameters passed to a function were not valid.' >&2\n" ++
        "    echo 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.' >&2\n" ++
        "    exit 44\n" ++
        "    ;;\n" ++
        "  add-generic-password)\n" ++
        "    capture_credentials \"$hex\" || :\n" ++
        "    echo 'security: SecKeychainItemCreateFromContent (<default>): Unable to obtain authorization for this operation.' >&2\n" ++
        "    exit 152\n" ++
        "    ;;\n" ++
        "esac\n" ++
        "echo 'security: unsupported operation' >&2\n" ++
        "exit 1\n";
    Dir.cwd().writeFile(ctx.io, .{ .sub_path = shim, .data = data }) catch |e|
        die(ctx, "cannot write '{s}': {s}", .{ shim, @errorName(e) });
    Dir.cwd().setFilePermissions(ctx.io, shim, .fromMode(0o700), .{}) catch |e|
        die(ctx, "cannot chmod '{s}': {s}", .{ shim, @errorName(e) });
    return bin;
}

/// Prepend a directory to PATH for a child environment.
/// Example: prependPath(ctx, env, "/tmp/bin") makes that bin searched first.
fn prependPath(ctx: Context, child_env: *std.process.Environ.Map, bin: []const u8) void {
    const old = child_env.get("PATH") orelse "";
    const next = if (old.len == 0)
        bin
    else
        std.fmt.allocPrint(ctx.gpa, "{s}:{s}", .{ bin, old }) catch die(ctx, "static workspace exhausted", .{});
    child_env.put("PATH", next) catch die(ctx, "static workspace exhausted", .{});
}

/// Force Claude child processes to use file-backed secure storage when possible.
/// Example: applyClaudeFileAuth(ctx, env, root) sets PATH so "security" fails.
fn applyClaudeFileAuth(ctx: Context, child_env: *std.process.Environ.Map, root: []const u8) void {
    prependPath(ctx, child_env, ensureClaudeFileAuthPath(ctx, root));
}

/// Return the non-secret trace log for Claude secure-storage shim calls.
/// Example: claudeFileAuthLog(ctx, ".claude") returns ".../.ma-file-auth-bin/security.log".
fn claudeFileAuthLog(ctx: Context, root: []const u8) []const u8 {
    return join(ctx, &.{ claudeFileAuthBin(ctx, root), "security.log" });
}

/// Return whether the security shim trace contains one operation.
/// Example: traceHasSecurityOp("find-generic-password\n", "find-generic-password") returns true.
fn traceHasSecurityOp(trace: []const u8, op: []const u8) bool {
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, op)) return true;
    }
    return false;
}

/// Prove that Claude resolves "security" through the private PATH shim before browser login.
/// Example: auth status should read secure storage and hit find-generic-password.
fn probeClaudeFileAuth(ctx: Context, program: *const Program, login_dir: []const u8, dst_dir: []const u8) void {
    const log_path = claudeFileAuthLog(ctx, login_dir);
    removeFile(ctx, log_path);
    var child_env = ctx.env.clone(ctx.gpa) catch die(ctx, "static workspace exhausted", .{});
    scrubCredentialEnv(&child_env, program.name);
    applyClaudeFileAuth(ctx, &child_env, login_dir);
    child_env.put(program.pairs[0].name, login_dir) catch die(ctx, "static workspace exhausted", .{});
    child_env.put(claude_secure_storage_env, dst_dir) catch die(ctx, "static workspace exhausted", .{});
    child_env.put(claude_file_auth_log_env, log_path) catch die(ctx, "static workspace exhausted", .{});
    child_env.put("NO_COLOR", "1") catch die(ctx, "static workspace exhausted", .{});
    child_env.put("TERM", "dumb") catch die(ctx, "static workspace exhausted", .{});

    const argv = [_][]const u8{ program.binary, "auth", "status", "--json" };
    _ = runCheckProcess(ctx, &argv, &child_env, check_timeout);

    const trace = readOpt(ctx, log_path) orelse
        die(ctx, "claude file-backed auth preflight did not reach the private security shim; this Claude build may bypass PATH and cannot be rotated safely by ma", .{});
    if (!traceHasSecurityOp(trace, "find-generic-password") and !traceHasSecurityOp(trace, "show-keychain-info"))
        die(ctx, "claude file-backed auth preflight reached the shim but did not read secure storage; refusing to run browser login because the resulting auth may not be rotatable", .{});
}

/// Apply a stored Claude OAuth storage slot to a launch environment, if configured.
/// Example: current=work sets CLAUDE_SECURESTORAGE_CONFIG_DIR to ma-auth/work.
pub fn applyLaunchEnv(ctx: Context, program: *const Program, account_dir: []const u8) void {
    if (std.mem.eql(u8, program.name, "codex")) {
        if (launchNeedsCodexFileAuthOverride(ctx, program, account_dir))
            scrubCredentialEnv(ctx.env, program.name);
        return;
    }
    if (!std.mem.eql(u8, program.name, "claude")) return;
    _ = ctx.env.swapRemove(claude_secure_storage_env);
    const root = stateRoot(ctx, program, account_dir);
    const data = readOpt(ctx, statePath(ctx, root)) orelse return;
    const cur = currentFromState(data) orelse return;
    const dir = variantDir(ctx, root, cur);
    if (!variantUsableLocal(ctx, program.name, dir)) return;
    scrubCredentialEnv(ctx.env, program.name);
    applyClaudeFileAuth(ctx, ctx.env, root);
    ctx.env.put(claude_secure_storage_env, dir) catch die(ctx, "static workspace exhausted", .{});
}

/// Return whether Codex launch should force file-backed auth storage.
/// Example: current ma-auth token needs refreshes to update auth.json, not keyring.
pub fn launchNeedsCodexFileAuthOverride(ctx: Context, program: *const Program, account_dir: []const u8) bool {
    if (!std.mem.eql(u8, program.name, "codex")) return false;
    const root = stateRoot(ctx, program, account_dir);
    const data = readOpt(ctx, statePath(ctx, root)) orelse return false;
    const cur = currentFromState(data) orelse return false;
    return variantUsableLocal(ctx, program.name, variantDir(ctx, root, cur));
}

/// Return whether any known auth artifact exists in a directory.
/// Example: hasAuth(ctx, codex, ".codex") detects auth.json.
fn hasAuth(ctx: Context, program: []const u8, root: []const u8) bool {
    for (artifacts(program)) |name| {
        if (exists(ctx, join(ctx, &.{ root, name }))) return true;
    }
    return false;
}

/// Return whether an artifact name is API-key auth rather than subscription auth.
/// Example: Claude's .api_key is rejected.
fn isApiKeyArtifact(name: []const u8) bool {
    return std.mem.eql(u8, name, ".api_key") or std.mem.eql(u8, name, "api_key") or std.mem.eql(u8, name, "api-key");
}

/// Test whether a JSON key names API-key auth.
/// Example: api_key and OPENAI_API_KEY return true.
fn apiKeyName(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, "api_key") or
        std.ascii.eqlIgnoreCase(s, "apikey") or
        std.ascii.eqlIgnoreCase(s, "apiKey") or
        std.ascii.eqlIgnoreCase(s, "OPENAI_API_KEY") or
        std.ascii.eqlIgnoreCase(s, "ANTHROPIC_API_KEY");
}

/// Recursively detect a non-empty API key field in parsed JSON.
/// Example: {"api_key":"sk-..."} returns true.
fn jsonHasApiKey(v: std.json.Value) bool {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                if (apiKeyName(entry.key_ptr.*)) switch (entry.value_ptr.*) {
                    .string => |s| if (s.len != 0) return true,
                    else => return true,
                };
                if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "auth_method") or std.ascii.eqlIgnoreCase(entry.key_ptr.*, "authMethod")) {
                    if (entry.value_ptr.* == .string and std.mem.indexOf(u8, entry.value_ptr.string, "api") != null) return true;
                }
                if (jsonHasApiKey(entry.value_ptr.*)) return true;
            }
        },
        .array => |a| for (a.items) |item| if (jsonHasApiKey(item)) return true,
        else => {},
    }
    return false;
}

/// Detect active API-key auth that cannot participate in subscription fallback rotation.
/// Example: a Codex auth.json containing OPENAI_API_KEY is rejected.
fn hasApiKeyAuth(ctx: Context, root: []const u8) bool {
    var dir = Dir.cwd().openDir(ctx.io, root, .{ .iterate = true }) catch return false;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (isApiKeyArtifact(entry.name)) return true;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const p = join(ctx, &.{ root, entry.name });
        const data = readOpt(ctx, p) orelse continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.gpa, data, .{}) catch continue;
        if (jsonHasApiKey(v)) return true;
    }
    return false;
}

/// Fail if a credential environment variable would bypass file-backed auth.
/// Example: OPENAI_API_KEY blocks Codex auth add/rotate.
fn blockCredentialEnv(ctx: Context, program: []const u8) void {
    for (credentialEnv(program)) |name| {
        if (ctx.env.get(name)) |_|
            die(ctx, "{s} is set; ma auth only rotates subscription logins stored in files, not API/env credentials", .{name});
    }
}

/// Record at most enough matching account folders to resolve or report ambiguity.
/// Example: key "work" records the first match and notes if a second exists.
fn collectAccount(ctx: *AccountFind, name: []const u8, p: Parsed) void {
    const hit = if (ctx.key) |key|
        if (ctx.key_id) |id| p.id == id else std.mem.eql(u8, p.account, key)
    else
        true;
    if (!hit) return;
    ctx.count += 1;
    if (ctx.count == 1) {
        if (name.len > ctx.first_folder_buf.len or p.account.len > ctx.first_account_buf.len) {
            ctx.count = max_accounts_overflow;
            return;
        }
        @memcpy(ctx.first_folder_buf[0..name.len], name);
        @memcpy(ctx.first_account_buf[0..p.account.len], p.account);
        ctx.first = .{
            .folder = ctx.first_folder_buf[0..name.len],
            .account = ctx.first_account_buf[0..p.account.len],
            .path = "",
        };
    } else if (ctx.count == 2) {
        if (name.len > ctx.second_folder_buf.len) {
            ctx.count = max_accounts_overflow;
            return;
        }
        @memcpy(ctx.second_folder_buf[0..name.len], name);
        ctx.second_folder = ctx.second_folder_buf[0..name.len];
    }
}

/// Count account folders matching a token without storing their names.
/// Example: key "work" increments count for each matching account.
fn countAccount(ctx: *AccountCount, _: []const u8, p: Parsed) void {
    const hit = if (ctx.key_id) |id| p.id == id else std.mem.eql(u8, p.account, ctx.key);
    if (hit) ctx.count += 1;
}

/// Resolve PROGRAM plus optional account name/id into one account folder.
/// Example: resolveAccount(..., "codex", "1") returns codex-1-work.
fn resolveProgram(ctx: Context, programs: []Program, progname: []const u8) *Program {
    const program = manifest.find(programs, progname) orelse
        die(ctx, "unknown program '{s}' (known: {s})", .{ progname, manifest.knownList(manifestContext(ctx), programs) });
    if (!supported(program.name)) die(ctx, "'{s}' auth is not supported (supported: claude, codex)", .{program.name});
    return program;
}

/// Count accounts that match a name or numeric id.
/// Example: accountMatchCount(..., "work") is used to parse optional ACCOUNT.
fn accountMatchCount(ctx: Context, programs: []Program, program: *const Program, key: []const u8) usize {
    var count = AccountCount{ .key = key, .key_id = std.fmt.parseInt(u32, key, 10) catch null };
    manifest.forEachAccount(manifestContext(ctx), programs, program, &count, countAccount);
    return count.count;
}

/// Resolve PROGRAM plus optional account name/id into one account folder.
/// Example: resolveAccount(..., "codex", "1") returns codex-1-work.
fn resolveAccount(ctx: Context, programs: []Program, progname: []const u8, key: ?[]const u8) struct { program: *Program, account: Account } {
    const program = resolveProgram(ctx, programs, progname);

    var find = AccountFind{
        .key = key,
        .key_id = if (key) |k| std.fmt.parseInt(u32, k, 10) catch null else null,
    };
    manifest.forEachAccount(manifestContext(ctx), programs, program, &find, collectAccount);

    if (find.count == max_accounts_overflow)
        die(ctx, "{s} account folder name is too long for one command to load (max {d} bytes)", .{ progname, max_account_folder_len });
    if (find.count == 0) {
        if (key) |k| die(ctx, "no account '{s}' for program '{s}' (try: ma ls)", .{ k, progname });
        die(ctx, "no accounts for program '{s}' (create one with: ma new {s} ACCOUNT)", .{ progname, progname });
    }
    if (find.count > 1) {
        if (find.second_folder) |second|
            die(ctx, "'auth {s}' needs an account, matches:\n  {s}\n  {s}", .{ progname, find.first.?.folder, second });
        die(ctx, "'auth {s}' needs an account", .{progname});
    }
    var account = find.first.?;
    account.folder = ctx.gpa.dupe(u8, account.folder) catch die(ctx, "static workspace exhausted", .{});
    account.account = ctx.gpa.dupe(u8, account.account) catch die(ctx, "static workspace exhausted", .{});
    account.path = join(ctx, &.{ ctx.install_root, account.folder });
    return .{ .program = program, .account = account };
}

/// Return current POSIX time in seconds.
/// Example: nowSecs(ctx) is used for add/rotate metadata.
fn nowSecs(ctx: Context) i64 {
    const ns = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

/// Return the ma-auth directory under a state root.
/// Example: authDir(ctx, ".codex") returns ".codex/ma-auth".
fn authDir(ctx: Context, root: []const u8) []const u8 {
    return join(ctx, &.{ root, "ma-auth" });
}

/// Return the metadata file path under a state root.
/// Example: statePath(ctx, ".codex") returns ".codex/ma-auth/state.tsv".
fn statePath(ctx: Context, root: []const u8) []const u8 {
    return join(ctx, &.{ authDir(ctx, root), "state.tsv" });
}

/// Return the private bin directory used to force Claude's file-backed OAuth fallback.
/// Example: claudeFileAuthBin(ctx, root) returns ".claude/ma-auth/.ma-file-auth-bin".
fn claudeFileAuthBin(ctx: Context, root: []const u8) []const u8 {
    return join(ctx, &.{ authDir(ctx, root), claude_file_auth_bin });
}

/// Return the directory where a token slot's auth artifacts are stored.
/// Example: variantDir(ctx, ".codex", "work") returns ".codex/ma-auth/work".
fn variantDir(ctx: Context, root: []const u8, variant: []const u8) []const u8 {
    return join(ctx, &.{ authDir(ctx, root), variant });
}

/// Return whether a name is the legacy bootstrap token slot.
/// Example: isDefault("default") returns true.
fn isDefault(name: []const u8) bool {
    return std.mem.eql(u8, name, "default");
}

/// Return the loaded token slice for iteration.
/// Example: stateItems(st) returns only initialized variants.
fn stateItems(st: State) []const Variant {
    return st.variants[0..st.len];
}

/// Return the mutable loaded token slice for updates.
/// Example: stateItemsMut(&st)[0].last_rotated_at = now.
fn stateItemsMut(st: *State) []Variant {
    return st.variants[0..st.len];
}

/// Append one token to bounded auth state.
/// Example: stateAppend(&st, v) fails at the documented 4096-token RAM limit.
fn stateAppend(ctx: Context, root: []const u8, st: *State, v: Variant) void {
    if (st.len == max_auth_tokens)
        die(ctx, "too many auth tokens for one command to load from '{s}' (max {d}; disk storage is not limited)", .{ statePath(ctx, root), max_auth_tokens });
    st.variants[st.len] = v;
    st.len += 1;
}

/// Remove one token from bounded auth state, preserving order.
/// Example: stateRemove(&st, 0) shifts later tokens left.
fn stateRemove(st: *State, idx: usize) Variant {
    const removed = st.variants[idx];
    var i = idx;
    while (i + 1 < st.len) : (i += 1) st.variants[i] = st.variants[i + 1];
    st.len -= 1;
    return removed;
}

/// Load ma-auth/state.tsv metadata into caller-provided fixed storage.
/// Example: loadState(ctx, root, &buf) returns token slots in file order.
fn loadState(ctx: Context, root: []const u8, variants: *[max_auth_tokens]Variant) State {
    var st = State{ .variants = variants };
    const data = readOpt(ctx, statePath(ctx, root)) orelse return st;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next() orelse continue;
        if (std.mem.eql(u8, kind, "current")) {
            const cur = fields.next() orelse continue;
            if (cur.len != 0) st.current = ctx.gpa.dupe(u8, cur) catch die(ctx, "static workspace exhausted", .{});
        } else if (std.mem.eql(u8, kind, "variant")) {
            const name = fields.next() orelse continue;
            validateVariant(ctx, name);
            const added = std.fmt.parseInt(i64, fields.next() orelse "0", 10) catch 0;
            const rotated = std.fmt.parseInt(i64, fields.next() orelse "0", 10) catch 0;
            const source = fields.next() orelse "login";
            stateAppend(ctx, root, &st, .{
                .name = ctx.gpa.dupe(u8, name) catch die(ctx, "static workspace exhausted", .{}),
                .added_at = added,
                .last_rotated_at = rotated,
                .implicit = std.mem.eql(u8, source, "implicit"),
            });
        }
    }
    return st;
}

/// Write ma-auth/state.tsv metadata.
/// Example: saveState(ctx, ".codex", st) persists current and rotation times.
fn saveState(ctx: Context, root: []const u8, st: State) void {
    var b: std.ArrayList(u8) = .empty;
    b.appendSlice(ctx.gpa, "# ma auth state v1\n") catch die(ctx, "static workspace exhausted", .{});
    if (st.current) |cur| {
        b.appendSlice(ctx.gpa, "current\t") catch die(ctx, "static workspace exhausted", .{});
        b.appendSlice(ctx.gpa, cur) catch die(ctx, "static workspace exhausted", .{});
        b.append(ctx.gpa, '\n') catch die(ctx, "static workspace exhausted", .{});
    }
    for (stateItems(st)) |v| {
        b.appendSlice(ctx.gpa, "variant\t") catch die(ctx, "static workspace exhausted", .{});
        b.appendSlice(ctx.gpa, v.name) catch die(ctx, "static workspace exhausted", .{});
        const line = std.fmt.allocPrint(ctx.gpa, "\t{d}\t{d}\t{s}\n", .{
            v.added_at,
            v.last_rotated_at,
            if (v.implicit) "implicit" else "login",
        }) catch die(ctx, "static workspace exhausted", .{});
        b.appendSlice(ctx.gpa, line) catch die(ctx, "static workspace exhausted", .{});
    }
    const p = statePath(ctx, root);
    ensureParent(ctx, p);
    Dir.cwd().writeFile(ctx.io, .{ .sub_path = p, .data = b.items }) catch |e|
        die(ctx, "cannot write '{s}': {s}", .{ p, @errorName(e) });
}

/// Return the variant index by name.
/// Example: variantIndex(st, "work") returns its position if present.
fn variantIndex(st: State, name: []const u8) ?usize {
    for (stateItems(st), 0..) |v, i| {
        if (std.mem.eql(u8, v.name, name)) return i;
    }
    return null;
}

/// Collapse an inferred user identity into a readable path-safe token slot name.
/// Example: "Jane Doe@example.com" becomes "jane-doe@example.com".
fn tokenNameFromIdentity(ctx: Context, identity: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    var last_dash = false;
    for (std.mem.trim(u8, identity, " \t\r\n")) |raw| {
        const c = std.ascii.toLower(raw);
        const keep = std.ascii.isAlphanumeric(c) or c == '@' or c == '.' or c == '_' or c == '-';
        if (keep) {
            b.append(ctx.gpa, c) catch die(ctx, "static workspace exhausted", .{});
            last_dash = false;
        } else if (!last_dash and b.items.len != 0) {
            b.append(ctx.gpa, '-') catch die(ctx, "static workspace exhausted", .{});
            last_dash = true;
        }
    }
    while (b.items.len != 0 and (b.items[b.items.len - 1] == '-' or b.items[b.items.len - 1] == '.')) {
        _ = b.pop();
    }
    while (b.items.len != 0 and (b.items[0] == '-' or b.items[0] == '.')) {
        _ = b.orderedRemove(0);
    }
    if (b.items.len == 0 or !variantNameOk(b.items)) return "user-token";
    return b.toOwnedSlice(ctx.gpa) catch die(ctx, "static workspace exhausted", .{});
}

/// Return whether a token slot name is unused both in state and on disk.
/// Example: tokenNameFree(ctx, root, st, "user") rejects stale directories too.
fn tokenNameFree(ctx: Context, root: []const u8, st: State, name: []const u8) bool {
    return variantIndex(st, name) == null and !exists(ctx, variantDir(ctx, root, name));
}

/// Return a unique token slot name by appending -N as needed.
/// Example: uniqueTokenName("alice", existing alice) returns alice-2.
fn uniqueTokenName(ctx: Context, root: []const u8, st: State, base: []const u8) []const u8 {
    if (tokenNameFree(ctx, root, st, base)) return base;
    var n: usize = 2;
    while (true) : (n += 1) {
        const name = std.fmt.allocPrint(ctx.gpa, "{s}-{d}", .{ base, n }) catch die(ctx, "static workspace exhausted", .{});
        if (tokenNameFree(ctx, root, st, name)) return name;
    }
}

/// Save the current live auth files as an implicit legacy default token slot.
/// Example: existing .codex/auth.json becomes ma-auth/default/auth.json.
fn captureLiveDefault(ctx: Context, program: []const u8, root: []const u8, st: *State) void {
    if (st.len != 0 or !hasAuth(ctx, program, root)) return;
    const dst = variantDir(ctx, root, "default");
    Dir.cwd().createDirPath(ctx.io, dst) catch |e| die(ctx, "cannot create '{s}': {s}", .{ dst, @errorName(e) });
    captureArtifacts(ctx, program, root, dst);
    if (std.mem.eql(u8, program, "claude")) captureClaudeMetadata(ctx, root, dst);
    stateAppend(ctx, root, st, .{
        .name = ctx.gpa.dupe(u8, "default") catch die(ctx, "static workspace exhausted", .{}),
        .added_at = nowSecs(ctx),
        .last_rotated_at = 0,
        .implicit = true,
    });
    st.current = ctx.gpa.dupe(u8, "default") catch die(ctx, "static workspace exhausted", .{});
}

/// Remove an untouched implicit default before the first explicit token slot is added.
/// Example: adding "work" after bootstrap drops ma-auth/default.
fn dropUntouchedDefault(ctx: Context, root: []const u8, st: *State, new_variant: []const u8) bool {
    if (isDefault(new_variant)) return false;
    if (st.len != 1) return false;
    const idx = variantIndex(st.*, "default") orelse return false;
    const v = stateItems(st.*)[idx];
    if (!v.implicit or v.last_rotated_at != 0) return false;
    _ = stateRemove(st, idx);
    if (st.current) |cur| {
        if (isDefault(cur)) st.current = null;
    }
    Dir.cwd().deleteTree(ctx.io, variantDir(ctx, root, "default")) catch |e|
        die(ctx, "cannot remove implicit default auth token: {s}", .{@errorName(e)});
    return true;
}

/// Return whether a token slot has locally usable subscription auth artifacts.
/// Example: Claude requires refresh-capable .credentials.json, not setup-token output.
fn variantUsableLocal(ctx: Context, program: []const u8, variant_dir: []const u8) bool {
    if (std.mem.eql(u8, program, "claude")) {
        if (!exists(ctx, join(ctx, &.{ variant_dir, ".credentials.json" }))) return false;
        if (hasApiKeyAuth(ctx, variant_dir)) return false;
        return claudeCredential(ctx, variant_dir) != null;
    }
    if (std.mem.eql(u8, program, "codex")) {
        if (!exists(ctx, join(ctx, &.{ variant_dir, "auth.json" }))) return false;
        return codexAuthProblem(ctx, variant_dir) == null;
    }
    return false;
}

/// Return whether the state's current token is locally installable.
/// Example: current=<token> for Claude returns false.
fn currentUsableLocal(ctx: Context, program: []const u8, root: []const u8, st: State) bool {
    const cur = st.current orelse return false;
    if (variantIndex(st, cur) == null) return false;
    return variantUsableLocal(ctx, program, variantDir(ctx, root, cur));
}

/// Preserve a Codex refresh written to the live root by older non-symlink installs.
/// Example: root/auth.json refreshed by Codex is copied back into ma-auth/current.
fn syncLiveCodexCurrent(ctx: Context, program: []const u8, root: []const u8, st: State) void {
    if (!std.mem.eql(u8, program, "codex")) return;
    const cur = st.current orelse return;
    if (variantIndex(st, cur) == null) return;
    if (isSymlink(ctx, join(ctx, &.{ root, "auth.json" }))) return;
    if (codexAuthProblem(ctx, root) != null) return;
    copyFile(ctx, join(ctx, &.{ root, "auth.json" }), join(ctx, &.{ variantDir(ctx, root, cur), "auth.json" }));
}

/// Choose the current token if usable, otherwise the first locally usable slot.
/// Example: after pruning the current token, this advances to a remaining valid slot.
fn usableCurrent(ctx: Context, program: []const u8, root: []const u8, st: *State) ?[]const u8 {
    if (st.current) |cur| {
        if (variantIndex(st.*, cur) != null and variantUsableLocal(ctx, program, variantDir(ctx, root, cur)))
            return cur;
    }
    for (stateItems(st.*)) |v| {
        if (variantUsableLocal(ctx, program, variantDir(ctx, root, v.name))) {
            st.current = v.name;
            return v.name;
        }
    }
    st.current = null;
    return null;
}

/// Install a stored token slot's auth artifacts into the live state root.
/// Example: installVariant(ctx, codex, ".codex", ".codex/ma-auth/work") writes auth.json only.
fn installVariant(ctx: Context, program: []const u8, root: []const u8, src_dir: []const u8) void {
    if (std.mem.eql(u8, program, "claude")) {
        if (!variantUsableLocal(ctx, program, src_dir))
            die(ctx, "auth token '{s}' has no refresh-capable Claude OAuth credentials", .{path.basename(src_dir)});
        copyFile(ctx, join(ctx, &.{ src_dir, ".credentials.json" }), join(ctx, &.{ root, ".credentials.json" }));
        applyClaudeMetadata(ctx, root, src_dir);
        return;
    }
    if (std.mem.eql(u8, program, "codex")) {
        if (!variantUsableLocal(ctx, program, src_dir))
            die(ctx, "auth token '{s}' has no refresh-capable Codex device auth", .{path.basename(src_dir)});
        const dst = join(ctx, &.{ root, "auth.json" });
        const rel = std.fmt.allocPrint(ctx.gpa, "ma-auth/{s}/auth.json", .{path.basename(src_dir)}) catch die(ctx, "static workspace exhausted", .{});
        removeFile(ctx, dst);
        Dir.cwd().symLink(ctx.io, rel, dst, .{}) catch |e|
            die(ctx, "cannot select Codex auth token '{s}': {s}", .{ path.basename(src_dir), @errorName(e) });
        return;
    }
    var copied = false;
    for (artifacts(program)) |name| {
        const src = join(ctx, &.{ src_dir, name });
        const dst = join(ctx, &.{ root, name });
        if (exists(ctx, src)) {
            copyFile(ctx, src, dst);
            copied = true;
        } else {
            removeFile(ctx, dst);
        }
    }
    if (!copied) die(ctx, "auth token '{s}' has no {s} subscription auth files", .{ path.basename(src_dir), program });
}

/// Infer a Claude account label from the shared account config.
/// Example: prefer emailAddress, then displayName, then accountUuid.
fn inferClaudeIdentityFromFile(ctx: Context, file_path: []const u8) []const u8 {
    const oauth = readClaudeOauth(ctx, file_path) orelse return "unknown";
    return jsonStringField(ctx, oauth, "emailAddress") orelse
        jsonStringField(ctx, oauth, "displayName") orelse
        jsonStringField(ctx, oauth, "accountUuid") orelse
        "unknown";
}

/// Infer a Claude account label from the shared account config.
/// Example: prefer emailAddress, then displayName, then accountUuid.
fn inferClaudeIdentity(ctx: Context, root: []const u8) []const u8 {
    return inferClaudeIdentityFromFile(ctx, join(ctx, &.{ root, ".claude.json" }));
}

/// Infer a Codex account label from auth.json without exposing tokens.
/// Example: prefer tokens.account_id when present.
fn inferCodexIdentity(ctx: Context, variant_dir: []const u8) []const u8 {
    const v = readJsonObject(ctx, join(ctx, &.{ variant_dir, "auth.json" })) orelse return "unknown";
    const tokens = if (v.object.get("tokens")) |t| t else return "unknown";
    if (tokens == .object) {
        if (tokens.object.get("id_token")) |t| {
            if (t == .string) if (identityFromJwt(ctx, t.string)) |id| return id;
        }
        if (tokens.object.get("access_token")) |t| {
            if (t == .string) if (identityFromJwt(ctx, t.string)) |id| return id;
        }
    }
    return jsonStringField(ctx, tokens, "account_id") orelse "unknown";
}

/// Run a bounded child command and return whether it exited zero.
/// Example: runCheckProcess(..., &.{"codex","login","status"}, env, check_timeout).
fn runCheckProcess(ctx: Context, argv: []const []const u8, child_env: *std.process.Environ.Map, timeout: Io.Timeout) CheckResult {
    const res = std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv,
        .environ_map = child_env,
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
        .timeout = timeout,
    }) catch |e| return .{ .status = .unknown, .message = @errorName(e) };
    switch (res.term) {
        .exited => |code| if (code == 0)
            return .{ .status = .ok, .stdout = res.stdout, .stderr = res.stderr }
        else
            return .{ .status = .unknown, .message = "command failed", .stdout = res.stdout, .stderr = res.stderr },
        .signal => return .{ .status = .unknown, .message = "command signaled", .stderr = res.stderr },
        .stopped => return .{ .status = .unknown, .message = "command stopped", .stderr = res.stderr },
        .unknown => return .{ .status = .unknown, .message = "command failed", .stderr = res.stderr },
    }
}

/// Return whether the provider response contains a standalone-ish pong.
/// Example: "pong\n" passes, but "ping" does not.
fn hasPong(stdout: []const u8) bool {
    if (stdout.len < 4) return false;
    var i: usize = 0;
    while (i + 4 <= stdout.len) : (i += 1) {
        if (std.ascii.toLower(stdout[i]) == 'p' and
            std.ascii.toLower(stdout[i + 1]) == 'o' and
            std.ascii.toLower(stdout[i + 2]) == 'n' and
            std.ascii.toLower(stdout[i + 3]) == 'g')
            return true;
    }
    return false;
}

/// Return whether text looks like a quota/saturation response rather than bad auth.
/// Example: "weekly limit resets Jun 27" returns true.
fn looksLimitedText(s: []const u8) bool {
    if (s.len == 0) return false;
    return asciiIndexOfIgnoreCase(s, "weekly limit") != null or
        asciiIndexOfIgnoreCase(s, "usage limit") != null or
        asciiIndexOfIgnoreCase(s, "rate limit") != null or
        asciiIndexOfIgnoreCase(s, "quota") != null or
        asciiIndexOfIgnoreCase(s, "too many requests") != null or
        asciiIndexOfIgnoreCase(s, "try again") != null or
        asciiIndexOfIgnoreCase(s, "resets") != null or
        asciiIndexOfIgnoreCase(s, "reset") != null;
}

/// Return whether a child result proves the token is saturated but authenticated.
/// Example: Claude's weekly-limit message can arrive on stdout or stderr.
fn looksLimitedResult(res: CheckResult) bool {
    return looksLimitedText(res.stdout) or looksLimitedText(res.stderr);
}

/// Return whether text is a clear authentication failure.
/// Example: "invalid token" returns true.
fn looksInvalidAuthText(s: []const u8) bool {
    if (s.len == 0) return false;
    return asciiIndexOfIgnoreCase(s, "invalid token") != null or
        asciiIndexOfIgnoreCase(s, "invalid api key") != null or
        asciiIndexOfIgnoreCase(s, "unauthorized") != null or
        asciiIndexOfIgnoreCase(s, "unauthenticated") != null or
        asciiIndexOfIgnoreCase(s, "not logged in") != null or
        asciiIndexOfIgnoreCase(s, "\"loggedIn\":false") != null or
        asciiIndexOfIgnoreCase(s, "\"authMethod\":\"none\"") != null or
        asciiIndexOfIgnoreCase(s, "login required") != null or
        asciiIndexOfIgnoreCase(s, "authentication failed") != null or
        asciiIndexOfIgnoreCase(s, "expired") != null or
        asciiIndexOfIgnoreCase(s, "revoked") != null;
}

/// Return whether a child result clearly proves bad credentials.
/// Example: status stderr saying "not logged in" is invalid.
fn looksInvalidAuthResult(res: CheckResult) bool {
    return looksInvalidAuthText(res.stdout) or looksInvalidAuthText(res.stderr);
}

/// Convert a child failure into a short check message.
/// Example: pingFailure("provider ping", res) returns an invalid/limited/unknown result.
fn pingFailure(ctx: Context, label: []const u8, res: CheckResult) CheckResult {
    if (looksLimitedResult(res)) return .{ .status = .limited, .message = "auth valid; provider reports usage limit" };
    if (looksInvalidAuthResult(res)) return .{ .status = .invalid, .message = "invalid auth; provider rejected login" };
    if (res.message.len != 0)
        return .{ .status = .unknown, .message = std.fmt.allocPrint(ctx.gpa, "{s}: {s}", .{ label, res.message }) catch die(ctx, "static workspace exhausted", .{}) };
    return .{ .status = .unknown, .message = label };
}

/// Mark a status command failure without leaking provider output.
/// Example: statusFailure(ctx, "Claude status", res) keeps only a short reason.
fn statusFailure(ctx: Context, label: []const u8, res: CheckResult) CheckResult {
    if (looksLimitedResult(res)) return .{ .status = .limited, .message = "auth valid; provider reports usage limit" };
    if (looksInvalidAuthResult(res)) return .{ .status = .invalid, .message = "invalid auth; provider rejected login" };
    if (res.message.len != 0)
        return .{ .status = .unknown, .message = std.fmt.allocPrint(ctx.gpa, "{s}: {s}", .{ label, res.message }) catch die(ctx, "static workspace exhausted", .{}) };
    return .{ .status = .unknown, .message = label };
}

/// Short label printed by `ma auth check`.
/// Example: .limited prints as "limit".
fn checkStatusLabel(status: CheckStatus) []const u8 {
    return switch (status) {
        .ok => "ok",
        .limited => "limit",
        .invalid => "bad",
        .unknown => "unk",
    };
}

/// Return whether --prune may delete this check result.
/// Example: quota-limited tokens are not pruned because auth still works.
fn checkPrunable(res: CheckResult) bool {
    return res.status == .invalid;
}

/// Check one Claude refresh-capable OAuth slot.
/// Example: validates with status, then asks Claude to reply pong.
fn checkClaudeVariant(ctx: Context, program: *const Program, root: []const u8, variant_dir: []const u8) CheckResult {
    if (!exists(ctx, join(ctx, &.{ variant_dir, ".credentials.json" })))
        return .{ .status = .invalid, .message = "missing .credentials.json" };
    if (hasApiKeyAuth(ctx, variant_dir))
        return .{ .status = .invalid, .identity = variantIdentity(ctx, program.name, root, variant_dir), .message = "API-key auth is not rotatable" };
    if (claudeCredential(ctx, variant_dir) == null)
        return .{ .status = .invalid, .identity = variantIdentity(ctx, program.name, root, variant_dir), .message = "missing Claude refresh credential" };
    const identity = variantIdentity(ctx, program.name, root, variant_dir);
    var child_env = ctx.env.clone(ctx.gpa) catch die(ctx, "static workspace exhausted", .{});
    scrubCredentialEnv(&child_env, program.name);
    applyClaudeFileAuth(ctx, &child_env, root);
    child_env.put(program.pairs[0].name, root) catch die(ctx, "static workspace exhausted", .{});
    child_env.put(claude_secure_storage_env, variant_dir) catch die(ctx, "static workspace exhausted", .{});
    child_env.put("NO_COLOR", "1") catch die(ctx, "static workspace exhausted", .{});
    child_env.put("TERM", "dumb") catch die(ctx, "static workspace exhausted", .{});

    const status_argv = [_][]const u8{ program.binary, "auth", "status", "--json" };
    const status = runCheckProcess(ctx, &status_argv, &child_env, check_timeout);
    if (status.status != .ok) {
        var res = statusFailure(ctx, "status failed", status);
        res.identity = identity;
        return res;
    }

    const ping_argv = [_][]const u8{
        program.binary,
        "--safe-mode",
        "--no-session-persistence",
        "--output-format",
        "text",
        "--permission-mode",
        "dontAsk",
        "--tools",
        "",
        "-p",
        ping_prompt,
    };
    const ping = runCheckProcess(ctx, &ping_argv, &child_env, ping_timeout);
    if (ping.status != .ok) {
        var res = pingFailure(ctx, "provider ping failed", ping);
        res.identity = identity;
        return res;
    }
    if (!hasPong(ping.stdout)) {
        if (looksLimitedResult(ping)) return .{ .status = .limited, .identity = identity, .message = "auth valid; provider reports usage limit" };
        if (looksInvalidAuthResult(ping)) return .{ .status = .invalid, .identity = identity, .message = "invalid auth; provider rejected login" };
        return .{ .status = .unknown, .identity = identity, .message = "provider ping inconclusive; auth not pruned" };
    }
    return .{ .status = .ok, .identity = identity };
}

/// Check one Codex auth.json token slot.
/// Example: validates with status, then asks Codex to reply pong.
fn checkCodexVariant(ctx: Context, program: *const Program, variant_dir: []const u8) CheckResult {
    if (!exists(ctx, join(ctx, &.{ variant_dir, "auth.json" })))
        return .{ .status = .invalid, .message = "missing auth.json" };
    if (codexAuthProblem(ctx, variant_dir)) |problem|
        return .{ .status = .invalid, .identity = inferCodexIdentity(ctx, variant_dir), .message = problem };
    const identity = inferCodexIdentity(ctx, variant_dir);
    var child_env = ctx.env.clone(ctx.gpa) catch die(ctx, "static workspace exhausted", .{});
    scrubCredentialEnv(&child_env, program.name);
    child_env.put(program.pairs[0].name, variant_dir) catch die(ctx, "static workspace exhausted", .{});
    child_env.put("NO_COLOR", "1") catch die(ctx, "static workspace exhausted", .{});
    child_env.put("TERM", "dumb") catch die(ctx, "static workspace exhausted", .{});

    const status_argv = [_][]const u8{ program.binary, "-c", codex_file_auth_override, "login", "status" };
    const status = runCheckProcess(ctx, &status_argv, &child_env, check_timeout);
    if (status.status != .ok) {
        var res = statusFailure(ctx, "status failed", status);
        res.identity = identity;
        return res;
    }

    const ping_argv = [_][]const u8{
        program.binary,
        "-c",
        codex_file_auth_override,
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--ignore-rules",
        "--ignore-user-config",
        "--sandbox",
        "read-only",
        ping_prompt,
    };
    const ping = runCheckProcess(ctx, &ping_argv, &child_env, ping_timeout);
    if (ping.status != .ok) {
        var res = pingFailure(ctx, "provider ping failed", ping);
        res.identity = identity;
        return res;
    }
    if (!hasPong(ping.stdout)) {
        if (looksLimitedResult(ping)) return .{ .status = .limited, .identity = identity, .message = "auth valid; provider reports usage limit" };
        if (looksInvalidAuthResult(ping)) return .{ .status = .invalid, .identity = identity, .message = "invalid auth; provider rejected login" };
        return .{ .status = .unknown, .identity = identity, .message = "provider ping inconclusive; auth not pruned" };
    }
    return .{ .status = .ok, .identity = identity };
}

/// Remove one token slot from state by index and adjust current if needed.
/// Example: pruning current=bad advances to the first remaining variant.
fn pruneVariant(ctx: Context, root: []const u8, st: *State, idx: usize) void {
    const removed = stateItems(st.*)[idx].name;
    removeTree(ctx, variantDir(ctx, root, removed));
    _ = stateRemove(st, idx);
    if (st.len == 0) {
        st.current = null;
    } else if (st.current == null or std.mem.eql(u8, st.current.?, removed)) {
        st.current = stateItems(st.*)[0].name;
    }
}

/// Apply the current token after a removal, or clear live Codex auth if none remain.
/// Example: after deleting current=bad, this installs the next current token.
fn installCurrentOrClear(ctx: Context, program: []const u8, root: []const u8, st: *State) void {
    if (usableCurrent(ctx, program, root, st)) |cur| {
        installVariant(ctx, program, root, variantDir(ctx, root, cur));
        return;
    }
    for (artifacts(program)) |name| removeFile(ctx, join(ctx, &.{ root, name }));
}

/// Return a local fingerprint for one auth token slot.
/// Example: Claude shows token:abc123; Codex shows auth:<file-digest>.
fn variantFingerprint(ctx: Context, program: []const u8, variant_dir: []const u8) []const u8 {
    if (std.mem.eql(u8, program, "claude")) {
        if (claudeCredential(ctx, variant_dir)) |cred| {
            if (identityFromJwt(ctx, cred)) |id|
                return std.fmt.allocPrint(ctx.gpa, "account:{s}", .{shortPrefix(id, short_fingerprint_len)}) catch die(ctx, "static workspace exhausted", .{});
        }
        const digest = fileDigest(ctx, join(ctx, &.{ variant_dir, ".credentials.json" }));
        if (std.mem.eql(u8, digest, "-")) return "-";
        return std.fmt.allocPrint(ctx.gpa, "oauth:{s}", .{shortPrefix(digest, short_fingerprint_len)}) catch die(ctx, "static workspace exhausted", .{});
    }
    if (std.mem.eql(u8, program, "codex")) {
        const auth_path = join(ctx, &.{ variant_dir, "auth.json" });
        const id = inferCodexIdentity(ctx, variant_dir);
        if (!std.mem.eql(u8, id, "unknown"))
            return std.fmt.allocPrint(ctx.gpa, "account:{s}", .{shortPrefix(id, short_fingerprint_len)}) catch die(ctx, "static workspace exhausted", .{});
        const digest = fileDigest(ctx, auth_path);
        if (std.mem.eql(u8, digest, "-")) return "-";
        return std.fmt.allocPrint(ctx.gpa, "auth:{s}", .{shortPrefix(digest, short_fingerprint_len)}) catch die(ctx, "static workspace exhausted", .{});
    }
    return "-";
}

/// Return a local identity label for one auth token slot.
/// Example: Claude uses shared .claude.json; Codex uses auth.json tokens.account_id.
fn variantIdentity(ctx: Context, program: []const u8, root: []const u8, variant_dir: []const u8) []const u8 {
    if (std.mem.eql(u8, program, "claude")) {
        const artifact_id = inferClaudeIdentityFromFile(ctx, join(ctx, &.{ variant_dir, ".claude.json" }));
        if (!std.mem.eql(u8, artifact_id, "unknown")) return artifact_id;
        if (claudeCredential(ctx, variant_dir)) |cred| {
            if (identityFromJwt(ctx, cred)) |id| return id;
        }
        return inferClaudeIdentity(ctx, root);
    }
    if (std.mem.eql(u8, program, "codex")) return inferCodexIdentity(ctx, variant_dir);
    return "unknown";
}

/// Pick a readable token slot name after login artifacts have been captured.
/// Example: prefer email/name identity; fall back to user-token-N.
fn finalAutoTokenName(ctx: Context, program: []const u8, root: []const u8, st: State, staged_dir: []const u8) []const u8 {
    const id = variantIdentity(ctx, program, root, staged_dir);
    const base = if (std.mem.eql(u8, id, "unknown")) "user-token" else tokenNameFromIdentity(ctx, id);
    return uniqueTokenName(ctx, root, st, base);
}

/// Confirm a successful login wrote file-backed subscription auth.
/// Example: captureArtifacts(ctx, "codex", tmp, variant) copies auth.json into the variant dir.
fn captureArtifacts(ctx: Context, program: []const u8, login_dir: []const u8, dst_dir: []const u8) void {
    var copied = false;
    for (artifacts(program)) |name| {
        const src = join(ctx, &.{ login_dir, name });
        if (!exists(ctx, src)) continue;
        copyFile(ctx, src, join(ctx, &.{ dst_dir, name }));
        copied = true;
    }
    if (!copied)
        die(ctx, "{s} login finished but did not write subscription auth files under '{s}'", .{ program, login_dir });
    if (hasApiKeyAuth(ctx, dst_dir))
        die(ctx, "{s} login wrote API-key auth; ma auth only supports subscription/device logins", .{program});
    if (std.mem.eql(u8, program, "codex")) {
        if (codexAuthProblem(ctx, dst_dir)) |problem|
            die(ctx, "codex login did not write refresh-capable device auth under '{s}' ({s})", .{ dst_dir, problem });
    }
}

/// Store a Claude metadata artifact with only selected oauthAccount fields.
/// Example: captureClaudeMetadata(ctx, root, dst) writes dst/.claude.json if identity exists.
fn captureClaudeMetadata(ctx: Context, login_dir: []const u8, dst_dir: []const u8) void {
    const oauth = readClaudeOauth(ctx, join(ctx, &.{ login_dir, ".claude.json" })) orelse return;
    writeClaudeOauthArtifact(ctx, oauth, join(ctx, &.{ dst_dir, ".claude.json" }));
}

/// Capture refresh-capable Claude OAuth credentials from a per-slot secure-storage dir.
/// Example: captureClaudeArtifacts(ctx, root, slot) stores .credentials.json and metadata.
fn captureClaudeArtifacts(ctx: Context, login_dir: []const u8, dst_dir: []const u8) void {
    const src = join(ctx, &.{ dst_dir, ".credentials.json" });
    if (!exists(ctx, src))
        die(ctx, "claude login finished but did not write file-backed OAuth credentials under '{s}' (missing .credentials.json); keychain-only Claude auth cannot be rotated by ma", .{dst_dir});
    if (claudeCredential(ctx, dst_dir) == null)
        die(ctx, "claude login wrote .credentials.json without refresh-capable OAuth credentials", .{});
    captureClaudeMetadata(ctx, login_dir, dst_dir);
    if (hasApiKeyAuth(ctx, dst_dir))
        die(ctx, "claude login wrote API-key auth; ma auth only supports subscription OAuth logins", .{});
}

/// Spawn and wait for a login command with its config dir redirected to login_dir.
/// Example: spawnLogin(ctx, codex, &.{"codex","login","--device-auth"}, dir).
fn spawnLogin(ctx: Context, program: *const Program, argv: []const []const u8, login_dir: []const u8) void {
    var child_env = ctx.env.clone(ctx.gpa) catch die(ctx, "static workspace exhausted", .{});
    scrubCredentialEnv(&child_env, program.name);
    child_env.put(program.pairs[0].name, login_dir) catch die(ctx, "static workspace exhausted", .{});
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .environ_map = &child_env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| die(ctx, "cannot run '{s}': {s}", .{ program.binary, @errorName(e) });
    const term = child.wait(ctx.io) catch |e| die(ctx, "waiting for '{s}' failed: {s}", .{ program.binary, @errorName(e) });
    switch (term) {
        .exited => |code| if (code != 0) die(ctx, "{s} login exited with status {d}", .{ program.name, code }),
        .signal => |sig| die(ctx, "{s} login terminated by signal {d}", .{ program.name, @intFromEnum(sig) }),
        .stopped => |sig| die(ctx, "{s} login stopped by signal {d}", .{ program.name, @intFromEnum(sig) }),
        .unknown => |code| die(ctx, "{s} login ended unexpectedly ({d})", .{ program.name, code }),
    }
}

/// Spawn Claude's refresh-capable subscription login into a selected storage slot.
/// Example: spawnClaudeLogin(ctx, claude, root, slot) writes slot/.credentials.json.
fn spawnClaudeLogin(ctx: Context, program: *const Program, login_dir: []const u8, dst_dir: []const u8) void {
    probeClaudeFileAuth(ctx, program, login_dir, dst_dir);
    const log_path = claudeFileAuthLog(ctx, login_dir);
    var child_env = ctx.env.clone(ctx.gpa) catch die(ctx, "static workspace exhausted", .{});
    scrubCredentialEnv(&child_env, program.name);
    applyClaudeFileAuth(ctx, &child_env, login_dir);
    child_env.put(program.pairs[0].name, login_dir) catch die(ctx, "static workspace exhausted", .{});
    child_env.put(claude_secure_storage_env, dst_dir) catch die(ctx, "static workspace exhausted", .{});
    child_env.put(claude_file_auth_log_env, log_path) catch die(ctx, "static workspace exhausted", .{});
    const argv = [_][]const u8{ program.binary, "auth", "login", "--claudeai" };
    var child = std.process.spawn(ctx.io, .{
        .argv = &argv,
        .environ_map = &child_env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| die(ctx, "cannot run '{s} auth login': {s}", .{ program.binary, @errorName(e) });
    const term = child.wait(ctx.io) catch |e| die(ctx, "waiting for '{s}' failed: {s}", .{ program.binary, @errorName(e) });
    switch (term) {
        .exited => |code| if (code != 0) die(ctx, "claude auth login exited with status {d}", .{code}),
        .signal => |sig| die(ctx, "claude auth login terminated by signal {d}", .{@intFromEnum(sig)}),
        .stopped => |sig| die(ctx, "claude auth login stopped by signal {d}", .{@intFromEnum(sig)}),
        .unknown => |code| die(ctx, "claude auth login ended unexpectedly ({d})", .{code}),
    }
    const trace = readOpt(ctx, log_path) orelse
        die(ctx, "claude login did not reach the private security shim; this login may have been saved outside '{s}'", .{dst_dir});
    if (!traceHasSecurityOp(trace, "add-generic-password"))
        die(ctx, "claude login did not try to save OAuth credentials through secure storage; this Claude build did not produce a rotatable login under '{s}'", .{dst_dir});
    if (!traceHasSecurityOp(trace, "write-credentials") and !exists(ctx, join(ctx, &.{ dst_dir, ".credentials.json" })))
        die(ctx, "claude login sent OAuth credentials to secure storage, but ma could not decode/write them under '{s}'", .{dst_dir});
    captureClaudeArtifacts(ctx, login_dir, dst_dir);
}

/// Run the real tool login interactively with its config dir redirected to login_dir.
/// Example: Codex uses `codex login --device-auth`.
fn runLogin(ctx: Context, program: *const Program, login_dir: []const u8, dst_dir: []const u8) void {
    if (std.mem.eql(u8, program.name, "codex")) {
        const argv = [_][]const u8{ program.binary, "-c", codex_file_auth_override, "login", "--device-auth" };
        return spawnLogin(ctx, program, &argv, login_dir);
    }
    if (std.mem.eql(u8, program.name, "claude")) {
        return spawnClaudeLogin(ctx, program, login_dir, dst_dir);
    }
    die(ctx, "'{s}' auth is not supported", .{program.name});
}

/// Return the config dir where the interactive login should run.
/// Example: Claude subscription login runs in the shared account .claude root.
fn loginRoot(ctx: Context, program: []const u8, root: []const u8, dst: []const u8) []const u8 {
    _ = ctx;
    if (std.mem.eql(u8, program, "claude")) return root;
    return dst;
}

/// Add one subscription login token for an account/profile.
/// Example: `ma auth add codex work sub1` stores ma-auth/sub1/auth.json.
pub fn cmdAdd(ctx: Context, programs: []Program, progname: []const u8, account_key: ?[]const u8, variant_arg: ?[]const u8) void {
    if (variant_arg) |v| validateVariant(ctx, v);
    const resolved = resolveAccount(ctx, programs, progname, account_key);
    blockCredentialEnv(ctx, resolved.program.name);
    const root = stateRoot(ctx, resolved.program, resolved.account.path);
    Dir.cwd().createDirPath(ctx.io, root) catch |e| die(ctx, "cannot create '{s}': {s}", .{ root, @errorName(e) });
    if (hasApiKeyAuth(ctx, root))
        die(ctx, "{s} account '{s}' has API-key auth; ma auth only rotates subscription/device logins", .{ resolved.program.name, resolved.account.account });

    var state_buf: [max_auth_tokens]Variant = undefined;
    var st = loadState(ctx, root, &state_buf);
    if (variant_arg == null or !isDefault(variant_arg.?)) captureLiveDefault(ctx, resolved.program.name, root, &st);
    syncLiveCodexCurrent(ctx, resolved.program.name, root, st);
    if (st.len >= max_auth_tokens)
        die(ctx, "{s} account '{s}' already has the maximum auth tokens one command will load ({d}; disk storage is not limited)", .{
            resolved.program.name,
            resolved.account.account,
            max_auth_tokens,
        });
    const explicit = variant_arg != null;
    const staged_name = if (explicit) variant_arg.? else auto_stage_variant;
    validateVariant(ctx, staged_name);
    if (explicit and variantIndex(st, staged_name) != null)
        die(ctx, "{s} auth token '{s}' already exists for profile '{s}'", .{ resolved.program.name, staged_name, resolved.account.account });

    const staged = variantDir(ctx, root, staged_name);
    if (!explicit) removeTree(ctx, staged);
    if (exists(ctx, staged)) die(ctx, "{s} auth token '{s}' already exists for profile '{s}'", .{ resolved.program.name, staged_name, resolved.account.account });
    Dir.cwd().createDirPath(ctx.io, staged) catch |e| die(ctx, "cannot create '{s}': {s}", .{ staged, @errorName(e) });
    const login_dir = loginRoot(ctx, resolved.program.name, root, staged);
    runLogin(ctx, resolved.program, login_dir, staged);
    if (!std.mem.eql(u8, resolved.program.name, "claude"))
        captureArtifacts(ctx, resolved.program.name, login_dir, staged);
    if (duplicateAuthToken(ctx, resolved.program.name, root, st, staged)) |dupe| {
        const staged_fp = variantFingerprint(ctx, resolved.program.name, staged);
        const dupe_fp = variantFingerprint(ctx, resolved.program.name, variantDir(ctx, root, dupe));
        removeTree(ctx, staged);
        restoreCurrentClaudeMetadata(ctx, resolved.program.name, root, st);
        die(ctx, "{s} login produced the same auth token as existing token '{s}' for profile '{s}' ({s} == {s}); switch provider accounts before adding another token", .{
            resolved.program.name,
            dupe,
            resolved.account.account,
            staged_fp,
            dupe_fp,
        });
    }

    const variant = if (explicit) staged_name else finalAutoTokenName(ctx, resolved.program.name, root, st, staged);
    if (!explicit) renameTree(ctx, staged, variantDir(ctx, root, variant));
    const dropped_current_default = if (explicit) dropUntouchedDefault(ctx, root, &st, variant) else false;

    stateAppend(ctx, root, &st, .{
        .name = ctx.gpa.dupe(u8, variant) catch die(ctx, "static workspace exhausted", .{}),
        .added_at = nowSecs(ctx),
        .last_rotated_at = 0,
        .implicit = false,
    });
    if (dropped_current_default or st.current == null or !currentUsableLocal(ctx, resolved.program.name, root, st) or (!std.mem.eql(u8, resolved.program.name, "claude") and !hasAuth(ctx, resolved.program.name, root))) {
        installVariant(ctx, resolved.program.name, root, variantDir(ctx, root, variant));
        st.current = ctx.gpa.dupe(u8, variant) catch die(ctx, "static workspace exhausted", .{});
    } else if (std.mem.eql(u8, resolved.program.name, "claude")) {
        installVariant(ctx, resolved.program.name, root, variantDir(ctx, root, st.current.?));
    }
    saveState(ctx, root, st);
    out(ctx, "added {s} auth token '{s}' for profile '{s}'\n", .{ resolved.program.name, variant, resolved.account.account });
}

/// Parse optional ACCOUNT and TOKEN after `ma auth add PROGRAM`.
/// Example: [] auto-names a token; ["work"] is account if it matches, otherwise token name.
pub fn cmdAddArgs(ctx: Context, programs: []Program, progname: []const u8, args: [][]const u8) void {
    if (args.len == 0) return cmdAdd(ctx, programs, progname, null, null);
    if (args.len == 2) return cmdAdd(ctx, programs, progname, args[0], args[1]);
    if (args.len != 1) die(ctx, "usage: ma auth add PROGRAM [ACCOUNT] [TOKEN]", .{});

    const program = resolveProgram(ctx, programs, progname);
    if (accountMatchCount(ctx, programs, program, args[0]) != 0)
        return cmdAdd(ctx, programs, progname, args[0], null);
    return cmdAdd(ctx, programs, progname, null, args[0]);
}

/// Choose the next token slot after current whose rotation time is outside the cooldown.
/// Example: nextVariant(..., current="a") returns b before wrapping to a.
fn nextVariant(ctx: Context, program: []const u8, root: []const u8, st: State, now: i64) NextVariant {
    if (st.len == 0) return .{};
    const start = if (st.current) |cur| (variantIndex(st, cur) orelse st.len - 1) + 1 else 0;
    const cur_dir = if (st.current) |cur| variantDir(ctx, root, cur) else null;
    var result = NextVariant{};
    var offset: usize = 0;
    while (offset < st.len) : (offset += 1) {
        const i = (start + offset) % st.len;
        const v = stateItems(st)[i];
        if (!variantUsableLocal(ctx, program, variantDir(ctx, root, v.name))) {
            result.saw_invalid = true;
            continue;
        }
        if (cur_dir) |dir| {
            if (std.mem.eql(u8, v.name, st.current.?)) continue;
            if (sameAuthCredential(ctx, program, dir, variantDir(ctx, root, v.name))) {
                result.saw_duplicate = true;
                continue;
            }
        }
        if (v.last_rotated_at != 0 and now - v.last_rotated_at < recent_window_secs) {
            result.saw_cooldown = true;
            continue;
        }
        result.idx = i;
        return result;
    }
    return result;
}

/// Rotate one account to the next available subscription login token.
/// Example: `ma auth rotate codex work` swaps the live auth.json to the next token.
pub fn cmdRotate(ctx: Context, programs: []Program, progname: []const u8, account_key: ?[]const u8) void {
    const resolved = resolveAccount(ctx, programs, progname, account_key);
    blockCredentialEnv(ctx, resolved.program.name);
    const root = stateRoot(ctx, resolved.program, resolved.account.path);
    if (hasApiKeyAuth(ctx, root))
        die(ctx, "{s} account '{s}' has API-key auth; ma auth only rotates subscription/device logins", .{ resolved.program.name, resolved.account.account });

    var state_buf: [max_auth_tokens]Variant = undefined;
    var st = loadState(ctx, root, &state_buf);
    captureLiveDefault(ctx, resolved.program.name, root, &st);
    syncLiveCodexCurrent(ctx, resolved.program.name, root, st);
    if (st.len < 2)
        die(ctx, "{s} account '{s}' needs at least two auth tokens to rotate", .{ resolved.program.name, resolved.account.account });
    const now = nowSecs(ctx);
    const next = nextVariant(ctx, resolved.program.name, root, st, now);
    const idx = next.idx orelse {
        if (next.saw_cooldown)
            warn(ctx, "all {s} auth tokens for account '{s}' were rotated within the last 10 minutes; double-check usage or rest before rotating again", .{ resolved.program.name, resolved.account.account })
        else if (next.saw_duplicate)
            warn(ctx, "all other {s} auth tokens for account '{s}' are the same credential as the current token; remove duplicates or add a different login", .{ resolved.program.name, resolved.account.account })
        else if (next.saw_invalid)
            warn(ctx, "{s} account '{s}' has no other locally valid auth token; run 'ma auth check {s} {s} --prune' or add a fresh login", .{
                resolved.program.name,
                resolved.account.account,
                resolved.program.name,
                resolved.account.account,
            })
        else
            warn(ctx, "{s} account '{s}' has no other usable auth token", .{ resolved.program.name, resolved.account.account });
        std.process.exit(1);
    };
    const v = &stateItemsMut(&st)[idx];
    const src = variantDir(ctx, root, v.name);
    installVariant(ctx, resolved.program.name, root, src);
    v.last_rotated_at = now;
    st.current = v.name;
    saveState(ctx, root, st);
    out(ctx, "rotated {s} account '{s}' to auth token '{s}'\n", .{ resolved.program.name, resolved.account.account, v.name });
}

/// Remove one stored auth token slot from an account/profile.
/// Example: `ma auth remove claude work bad` deletes ma-auth/bad.
pub fn cmdRemove(ctx: Context, programs: []Program, progname: []const u8, account_key: ?[]const u8, token: []const u8) void {
    validateVariant(ctx, token);
    const resolved = resolveAccount(ctx, programs, progname, account_key);
    const root = stateRoot(ctx, resolved.program, resolved.account.path);
    var state_buf: [max_auth_tokens]Variant = undefined;
    var st = loadState(ctx, root, &state_buf);
    syncLiveCodexCurrent(ctx, resolved.program.name, root, st);
    const idx = variantIndex(st, token) orelse
        die(ctx, "{s} account '{s}' has no auth token '{s}'", .{ resolved.program.name, resolved.account.account, token });
    if (st.len == 1)
        die(ctx, "{s} account '{s}' has only one auth token; use 'ma auth clear {s} {s}' to remove the token set intentionally", .{
            resolved.program.name,
            resolved.account.account,
            resolved.program.name,
            resolved.account.account,
        });
    pruneVariant(ctx, root, &st, idx);
    installCurrentOrClear(ctx, resolved.program.name, root, &st);
    saveState(ctx, root, st);
    out(ctx, "removed {s} auth token '{s}' from profile '{s}'\n", .{ resolved.program.name, token, resolved.account.account });
}

/// Parse ACCOUNT and TOKEN after `ma auth remove PROGRAM`.
/// Example: ["work","old"] removes token old from account work.
pub fn cmdRemoveArgs(ctx: Context, programs: []Program, progname: []const u8, args: [][]const u8) void {
    if (args.len == 1) return cmdRemove(ctx, programs, progname, null, args[0]);
    if (args.len == 2) return cmdRemove(ctx, programs, progname, args[0], args[1]);
    die(ctx, "usage: ma auth remove PROGRAM [ACCOUNT] TOKEN", .{});
}

/// Remove all stored auth token slots for one account/profile.
/// Example: `ma auth clear codex work` deletes ma-auth and live auth.json.
pub fn cmdClear(ctx: Context, programs: []Program, progname: []const u8, account_key: ?[]const u8) void {
    const resolved = resolveAccount(ctx, programs, progname, account_key);
    const root = stateRoot(ctx, resolved.program, resolved.account.path);
    removeTree(ctx, authDir(ctx, root));
    for (artifacts(resolved.program.name)) |name| removeFile(ctx, join(ctx, &.{ root, name }));
    out(ctx, "cleared {s} auth tokens for profile '{s}'\n", .{ resolved.program.name, resolved.account.account });
}

/// Check stored auth tokens and optionally remove the ones that fail.
/// Example: `ma auth check claude work --prune` validates and deletes broken tokens.
pub fn cmdCheck(ctx: Context, programs: []Program, progname: []const u8, account_key: ?[]const u8, prune: bool) void {
    const resolved = resolveAccount(ctx, programs, progname, account_key);
    blockCredentialEnv(ctx, resolved.program.name);
    const root = stateRoot(ctx, resolved.program, resolved.account.path);
    var state_buf: [max_auth_tokens]Variant = undefined;
    var st = loadState(ctx, root, &state_buf);
    captureLiveDefault(ctx, resolved.program.name, root, &st);
    syncLiveCodexCurrent(ctx, resolved.program.name, root, st);
    if (st.len == 0)
        die(ctx, "{s} account '{s}' has no auth tokens to check", .{ resolved.program.name, resolved.account.account });

    var i: usize = 0;
    var failed: usize = 0;
    while (i < st.len) {
        const v = stateItems(st)[i];
        const dir = variantDir(ctx, root, v.name);
        const res = if (std.mem.eql(u8, resolved.program.name, "claude"))
            checkClaudeVariant(ctx, resolved.program, root, dir)
        else
            checkCodexVariant(ctx, resolved.program, dir);
        const prunable = checkPrunable(res);
        out(ctx, "{s:<5} {s:<16} {s}", .{ checkStatusLabel(res.status), v.name, res.identity });
        if (res.status != .ok and res.message.len != 0) out(ctx, "  {s}", .{res.message});
        if (prune and res.status != .ok) {
            if (prunable) {
                out(ctx, "  pruned", .{});
            } else {
                out(ctx, "  kept", .{});
            }
        }
        out(ctx, "\n", .{});
        if (res.status != .ok) {
            failed += 1;
            if (prune and prunable) {
                pruneVariant(ctx, root, &st, i);
                continue;
            }
        }
        i += 1;
    }
    if (prune) {
        installCurrentOrClear(ctx, resolved.program.name, root, &st);
        saveState(ctx, root, st);
    }
    if (failed != 0) std.process.exit(1);
}

/// Parse optional ACCOUNT and --prune after `ma auth check PROGRAM`.
/// Example: ["work","--prune"] checks account work and removes failed tokens.
pub fn cmdCheckArgs(ctx: Context, programs: []Program, progname: []const u8, args: [][]const u8) void {
    var prune = false;
    var account: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--prune")) {
            prune = true;
        } else if (account == null) {
            account = arg;
        } else {
            die(ctx, "usage: ma auth check PROGRAM [ACCOUNT] [--prune]", .{});
        }
    }
    cmdCheck(ctx, programs, progname, account, prune);
}

/// List stored auth tokens without contacting the upstream service.
/// Example: `ma auth ls codex work` prints current token, identity, and metadata.
pub fn cmdList(ctx: Context, programs: []Program, progname: []const u8, account_key: ?[]const u8) void {
    const resolved = resolveAccount(ctx, programs, progname, account_key);
    const root = stateRoot(ctx, resolved.program, resolved.account.path);
    var state_buf: [max_auth_tokens]Variant = undefined;
    const st = loadState(ctx, root, &state_buf);
    syncLiveCodexCurrent(ctx, resolved.program.name, root, st);
    if (st.len == 0)
        die(ctx, "{s} account '{s}' has no auth tokens", .{ resolved.program.name, resolved.account.account });

    out(ctx, "{s} account '{s}' auth tokens\n", .{ resolved.program.name, resolved.account.account });
    out(ctx, "{s:<3} {s:<16} {s:<18} {s:<24} {s:<17} {s:<17} {s}\n", .{
        "CUR", "TOKEN", "FINGERPRINT", "IDENTITY", "ADDED", "ROTATED", "SOURCE",
    });
    for (stateItems(st)) |v| {
        const dir = variantDir(ctx, root, v.name);
        const cur = if (st.current) |c| (if (std.mem.eql(u8, c, v.name)) "*" else "") else "";
        out(ctx, "{s:<3} {s:<16} {s:<18} {s:<24} {s:<17} {s:<17} {s}\n", .{
            cur,
            v.name,
            variantFingerprint(ctx, resolved.program.name, dir),
            variantIdentity(ctx, resolved.program.name, root, dir),
            fmtTime(ctx, v.added_at),
            fmtTime(ctx, v.last_rotated_at),
            if (v.implicit) "implicit" else "login",
        });
    }
}
