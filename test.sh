#!/bin/sh
set -eu

# Print a test failure and exit non-zero.
# Example: die "missing file" prints "test: missing file" and exits 1.
die() {
  echo "test: $*" >&2
  exit 1
}

# Print one passing test step.
# Example: say "creates accounts" prints "ok - creates accounts".
say() {
  printf 'ok - %s\n' "$1"
}

# Require a path to exist.
# Example: assert_file "$ROOT/claude-1-cn/.claude" succeeds when that directory exists.
assert_file() {
  test -e "$1" || die "missing expected path: $1"
}

# Require a path not to exist.
# Example: assert_no_file "$HOME/.claude/session.jsonl" succeeds after a move.
assert_no_file() {
  test ! -e "$1" || die "unexpected path still exists: $1"
}

# Require a file to contain a fixed string.
# Example: assert_grep "$LOG" "CODEX_HOME=$DST_CODEX" verifies the launched env.
assert_grep() {
  grep -F "$2" "$1" >/dev/null || die "missing '$2' in $1"
}

# Require a fixed string to appear a precise number of times.
# Example: assert_count history.jsonl "$CODEX_ID" 2 verifies two history rows moved.
assert_count() {
  count="$(grep -F -c "$2" "$1" || true)"
  test "$count" = "$3" || die "expected $3 matches for '$2' in $1, got $count"
}

# Require a file to have a precise line count.
# Example: assert_lines session.jsonl 5 verifies a multi-turn session stayed intact.
assert_lines() {
  count="$(wc -l < "$1" | tr -d ' ')"
  test "$count" = "$2" || die "expected $2 lines in $1, got $count"
}

# Run the temporary ma with fake tool binaries and isolated HOME.
# Example: run_ma new claude cn creates "$ROOT/claude-1-cn".
run_ma() {
  PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" "$ROOT/ma" "$@"
}

# Run the temporary ma and require the fake tool to log its received env/argv.
# Example: run_ma_logged codex cn resume "$CODEX_ID" appends CODEX_HOME to "$LOG".
run_ma_logged() {
  PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" MA_TEST_LOG="$LOG" "$ROOT/ma" "$@"
}

unset MA_HOME MA_ARGV0 CODEX_HOME CLAUDE_CONFIG_DIR

tmp_parent="${TMPDIR:-/tmp}"
tmp_parent="${tmp_parent%/}"
ROOT="$(mktemp -d "$tmp_parent/ma-test.XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
CASE="$ROOT/case"
FAKEBIN="$CASE/fakebin"
HOME_DIR="$CASE/home"
LOG="$CASE/exec.log"

CLAUDE_ID=11111111-2222-4333-8444-555555555555
CLAUDE_ENV_ID=22222222-3333-4444-8555-666666666666
CODEX_ID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
DECLINE_ID=bbbbbbbb-cccc-4ddd-8eee-ffffffffffff
PS_ID_OLD=33333333-4444-4555-8666-777777777777
PS_ID_NEW=44444444-5555-4666-8777-888888888888
CODEX_PS_ID=55555555-6666-4777-8888-999999999999

trap 'rm -rf "$ROOT"' EXIT INT HUP TERM

mkdir -p "$FAKEBIN" "$HOME_DIR"
cp programs.conf "$ROOT/programs.conf"

ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/zig-global}" \
ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$ROOT/zig-local}" \
  zig build-exe src/launcher.zig -femit-bin="$ROOT/ma" -O Debug

cat > "$FAKEBIN/claude" <<'SH'
#!/bin/sh
: "${MA_TEST_LOG:?MA_TEST_LOG is required}"
{
  printf 'program=claude\n'
  printf 'CLAUDE_CONFIG_DIR=%s\n' "$CLAUDE_CONFIG_DIR"
  printf 'args=%s\n' "$*"
} >> "$MA_TEST_LOG"
SH

cat > "$FAKEBIN/codex" <<'SH'
#!/bin/sh
: "${MA_TEST_LOG:?MA_TEST_LOG is required}"
{
  printf 'program=codex\n'
  printf 'CODEX_HOME=%s\n' "$CODEX_HOME"
  printf 'args=%s\n' "$*"
} >> "$MA_TEST_LOG"
SH

chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex"

run_ma new claude cn >/dev/null
run_ma new codex inferact >/dev/null
run_ma new codex cn >/dev/null
say "creates isolated account folders"

mkdir -p "$HOME_DIR/.claude/projects/-tmp-work/$CLAUDE_ID"
cat > "$HOME_DIR/.claude/projects/-tmp-work/$CLAUDE_ID.jsonl" <<EOF2
{"type":"user","sessionId":"$CLAUDE_ID","message":{"content":"turn one"}}
{"type":"assistant","sessionId":"$CLAUDE_ID","message":{"content":"reply one"}}
{"type":"user","sessionId":"$CLAUDE_ID","message":{"content":"turn two"}}
{"type":"assistant","sessionId":"$CLAUDE_ID","message":{"content":"reply two"}}
EOF2
printf 'tool-result\n' > "$HOME_DIR/.claude/projects/-tmp-work/$CLAUDE_ID/tool.txt"
cat > "$HOME_DIR/.claude/history.jsonl" <<EOF2
{"display":"unrelated","sessionId":"00000000-0000-4000-8000-000000000000"}
{"display":"turn one","project":"/tmp/work","sessionId":"$CLAUDE_ID"}
{"display":"turn two","project":"/tmp/work","sessionId":"$CLAUDE_ID"}
EOF2
printf '{"display":"target-old","sessionId":"99999999-9999-4999-8999-999999999999"}\n' \
  > "$ROOT/claude-1-cn/.claude/history.jsonl"

printf 'y\n' | run_ma_logged claude cn --resume "$CLAUDE_ID" >/dev/null

assert_no_file "$HOME_DIR/.claude/projects/-tmp-work/$CLAUDE_ID.jsonl"
assert_file "$ROOT/claude-1-cn/.claude/projects/-tmp-work/$CLAUDE_ID.jsonl"
assert_file "$ROOT/claude-1-cn/.claude/projects/-tmp-work/$CLAUDE_ID/tool.txt"
assert_lines "$ROOT/claude-1-cn/.claude/projects/-tmp-work/$CLAUDE_ID.jsonl" 4
assert_count "$ROOT/claude-1-cn/.claude/history.jsonl" "$CLAUDE_ID" 2
assert_count "$HOME_DIR/.claude/history.jsonl" "$CLAUDE_ID" 0
assert_grep "$LOG" "CLAUDE_CONFIG_DIR=$ROOT/claude-1-cn/.claude"
assert_grep "$LOG" "args=--resume $CLAUDE_ID"
say "moves multi-turn Claude resume from HOME into target account"

CUSTOM_CLAUDE="$CASE/custom-claude-state"
mkdir -p "$CUSTOM_CLAUDE/deep/sub/path"
cat > "$CUSTOM_CLAUDE/deep/sub/path/$CLAUDE_ENV_ID.jsonl" <<EOF2
{"type":"user","sessionId":"$CLAUDE_ENV_ID","message":{"content":"env turn one"}}
{"type":"assistant","sessionId":"$CLAUDE_ENV_ID","message":{"content":"env reply one"}}
EOF2
cat > "$CUSTOM_CLAUDE/history.jsonl" <<EOF2
{"display":"env one","sessionId":"$CLAUDE_ENV_ID"}
{"display":"env two","sessionId":"$CLAUDE_ENV_ID"}
EOF2

printf 'y\n' | PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CUSTOM_CLAUDE" \
  MA_TEST_LOG="$LOG" "$ROOT/ma" claude cn --resume "$CLAUDE_ENV_ID" >/dev/null

assert_no_file "$CUSTOM_CLAUDE/deep/sub/path/$CLAUDE_ENV_ID.jsonl"
assert_file "$ROOT/claude-1-cn/.claude/deep/sub/path/$CLAUDE_ENV_ID.jsonl"
assert_count "$ROOT/claude-1-cn/.claude/history.jsonl" "$CLAUDE_ENV_ID" 2
assert_count "$CUSTOM_CLAUDE/history.jsonl" "$CLAUDE_ENV_ID" 0
say "searches custom Claude state recursively before falling back"

SRC_CODEX="$ROOT/codex-1-inferact/.codex"
DST_CODEX="$ROOT/codex-2-cn/.codex"
CODEX_REL=sessions/2026/06/24/rollout-2026-06-24T10-29-04-$CODEX_ID.jsonl
mkdir -p "$SRC_CODEX/$(dirname "$CODEX_REL")"
cat > "$SRC_CODEX/$CODEX_REL" <<EOF2
{"type":"session_meta","payload":{"session_id":"$CODEX_ID","cwd":"/tmp/work"}}
{"type":"user_message","payload":{"text":"turn one"}}
{"type":"agent_message","payload":{"text":"reply one"}}
{"type":"user_message","payload":{"text":"turn two"}}
{"type":"agent_message","payload":{"text":"reply two"}}
EOF2
cat > "$SRC_CODEX/history.jsonl" <<EOF2
{"display":"codex one","sessionId":"$CODEX_ID"}
{"display":"codex two","sessionId":"$CODEX_ID"}
EOF2
printf '{"display":"codex target old","sessionId":"99999999-9999-4999-8999-999999999999"}\n' \
  > "$DST_CODEX/history.jsonl"

printf 'y\n' | run_ma_logged codex cn resume "$CODEX_ID" continue >/dev/null

assert_no_file "$SRC_CODEX/$CODEX_REL"
assert_file "$DST_CODEX/$CODEX_REL"
assert_lines "$DST_CODEX/$CODEX_REL" 5
assert_count "$DST_CODEX/history.jsonl" "$CODEX_ID" 2
assert_count "$SRC_CODEX/history.jsonl" "$CODEX_ID" 0
assert_grep "$LOG" "CODEX_HOME=$DST_CODEX"
assert_grep "$LOG" "args=resume $CODEX_ID continue"
say "moves multi-turn Codex resume and history between accounts"

mkdir -p "$HOME_DIR/.claude/projects/-tmp-decline"
printf '{"sessionId":"%s"}\n' "$DECLINE_ID" > "$HOME_DIR/.claude/projects/-tmp-decline/$DECLINE_ID.jsonl"
if printf 'n\n' | run_ma_logged claude cn --resume "$DECLINE_ID" >/dev/null 2>&1; then
  die "declined adoption unexpectedly succeeded"
fi
assert_file "$HOME_DIR/.claude/projects/-tmp-decline/$DECLINE_ID.jsonl"
assert_no_file "$ROOT/claude-1-cn/.claude/projects/-tmp-decline/$DECLINE_ID.jsonl"
say "leaves source session untouched when adoption is declined"

run_ma new claude 中文 >/dev/null
run_ma_logged claude 中文 ping >/dev/null
run_ma ls > "$CASE/list.out"

assert_file "$ROOT/claude-2-中文/.claude"
assert_grep "$LOG" "CLAUDE_CONFIG_DIR=$ROOT/claude-2-中文/.claude"
assert_grep "$LOG" "args=ping"
assert_grep "$CASE/list.out" "claude-2-中文"
say "supports non-ASCII account names"

PROJECT_DIR="$CASE/project"
PROJECT_KEY="$(printf '%s' "$PROJECT_DIR" | tr '/' '-')"
mkdir -p "$PROJECT_DIR" \
  "$ROOT/claude-1-cn/.claude/projects/$PROJECT_KEY" \
  "$ROOT/claude-2-中文/.claude/projects/$PROJECT_KEY"
cat > "$ROOT/claude-1-cn/.claude/projects/$PROJECT_KEY/$PS_ID_OLD.jsonl" <<EOF2
{"type":"user","timestamp":"2026-06-24T10:00:00.000Z","message":{"content":"older topic"}}
{"type":"assistant","timestamp":"2026-06-24T10:05:30.000Z","message":{"content":"older reply"}}
EOF2
cat > "$ROOT/claude-2-中文/.claude/projects/$PROJECT_KEY/$PS_ID_NEW.jsonl" <<EOF2
{"type":"user","timestamp":"2026-06-24T11:00:00.000Z","message":{"content":[{"type":"text","text":"newer topic from array"}]}}
{"type":"summary","timestamp":"2026-06-24T11:15:00.000Z","summary":"newer summary"}
EOF2
mkdir -p "$ROOT/codex-2-cn/.codex/sessions/2026/06/24"
cat > "$ROOT/codex-2-cn/.codex/sessions/2026/06/24/rollout-2026-06-24T12-00-00-$CODEX_PS_ID.jsonl" <<EOF2
{"timestamp":"2026-06-24T12:00:00.000Z","type":"session_meta","payload":{"session_id":"$CODEX_PS_ID","cwd":"$PROJECT_DIR"}}
{"timestamp":"2026-06-24T12:01:00.000Z","type":"user_message","payload":{"text":"codex ps topic"}}
{"timestamp":"2026-06-24T12:04:00.000Z","type":"agent_message","payload":{"text":"codex ps reply"}}
EOF2
(cd "$PROJECT_DIR" && run_ma claude ps) > "$CASE/claude-ps.out"
(cd "$PROJECT_DIR" && run_ma codex ps) > "$CASE/codex-ps.out"

assert_grep "$CASE/claude-ps.out" "ACCOUNT"
assert_grep "$CASE/claude-ps.out" "$PS_ID_OLD"
assert_grep "$CASE/claude-ps.out" "$PS_ID_NEW"
assert_grep "$CASE/claude-ps.out" "cn"
assert_grep "$CASE/claude-ps.out" "中文"
assert_grep "$CASE/claude-ps.out" "2026-06-24 11:15Z"
assert_grep "$CASE/claude-ps.out" "15m00s"
assert_grep "$CASE/claude-ps.out" "newer summary"
first_session="$(awk 'NR==2 {print $2}' "$CASE/claude-ps.out")"
test "$first_session" = "$PS_ID_NEW" || die "expected newest session first, got $first_session"
assert_grep "$CASE/codex-ps.out" "$CODEX_PS_ID"
assert_grep "$CASE/codex-ps.out" "codex ps topic"
assert_grep "$CASE/codex-ps.out" "4m00s"
say "lists current-folder sessions across Claude and Codex accounts"

echo "all tests passed"
