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
if [ -n "${MA_TEST_LOG:-}" ]; then
  {
    printf 'program=claude\n'
    printf 'CLAUDE_CONFIG_DIR=%s\n' "$CLAUDE_CONFIG_DIR"
    printf 'CLAUDE_SECURESTORAGE_CONFIG_DIR=%s\n' "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}"
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
    printf 'PATH=%s\n' "$PATH"
    printf 'args=%s\n' "$*"
  } >> "$MA_TEST_LOG"
fi
if [ "${1:-}" = auth ] && [ "${2:-}" = login ]; then
  token_id="${MA_TEST_CLAUDE_TOKEN:-$MA_TEST_CLAUDE_VARIANT}"
  cred="$(printf '{"claudeAiOauth":{"accessToken":"access-%s","refreshToken":"refresh-%s","expiresAt":9999999999999,"scopes":["user:profile","user:inference"]}}' "$token_id" "$token_id")"
  hex="$(printf '%s' "$cred" | od -An -tx1 | tr -d ' \n')"
  printf 'add-generic-password -U -a "%s" -s "Claude Code-test" -X "%s"\n' "${USER:-claude-code-user}" "$hex" | security -i >/dev/null 2>&1 || :
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"oauthAccount":{"kind":"subscription","emailAddress":"%s@example.test","displayName":"%s","variant":"%s"},"projects":{"keep":true},"theme":"stable"}\n' "$MA_TEST_CLAUDE_VARIANT" "$MA_TEST_CLAUDE_VARIANT" "$MA_TEST_CLAUDE_VARIANT" \
    > "$CLAUDE_CONFIG_DIR/.claude.json"
fi
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  security find-generic-password -a "${USER:-claude-code-user}" -w -s "Claude Code-test" >/dev/null 2>&1 || :
  cred="$CLAUDE_SECURESTORAGE_CONFIG_DIR/.credentials.json"
  if grep -F '"refreshToken":"refresh-broken"' "$cred" >/dev/null 2>&1; then
    printf '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}\n'
    exit 1
  fi
  test -f "$cred" || exit 1
  printf '{"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}\n'
fi
if [ "${1:-}" = --safe-mode ]; then
  cred="$CLAUDE_SECURESTORAGE_CONFIG_DIR/.credentials.json"
  if grep -F '"refreshToken":"refresh-deadping"' "$cred" >/dev/null 2>&1; then
    printf 'nope\n'
    exit 0
  fi
  if grep -F '"refreshToken":"refresh-limited"' "$cred" >/dev/null 2>&1; then
    printf 'You'\''ve hit your weekly limit · resets Jun 27 at 10am (Asia/Shanghai)\n'
    exit 0
  fi
  if grep -F '"refreshToken":"refresh-' "$cred" >/dev/null 2>&1; then
    printf 'pong\n'
    exit 0
  fi
  exit 1
fi
SH

cat > "$FAKEBIN/codex" <<'SH'
#!/bin/sh
b64url() {
  base64 | tr '+/' '-_' | tr -d '=\n'
}
raw_args="$*"
if [ "${1:-}" = -c ]; then
  test "${2:-}" = cli_auth_credentials_store=file || exit 91
  shift 2
fi
if [ -n "${MA_TEST_LOG:-}" ]; then
  {
    printf 'program=codex\n'
    printf 'CODEX_HOME=%s\n' "$CODEX_HOME"
    printf 'args=%s\n' "$raw_args"
  } >> "$MA_TEST_LOG"
fi
if [ "${1:-}" = login ] && [ "${2:-}" = --device-auth ]; then
  mkdir -p "$CODEX_HOME"
  variant="$(basename "$CODEX_HOME")"
  header="$(printf '{"alg":"none"}' | b64url)"
  user="${MA_TEST_CODEX_USER:-$variant@example.test}"
  if [ -n "${MA_TEST_CODEX_TOKEN:-}" ]; then
    token_id="$MA_TEST_CODEX_TOKEN"
  elif [ "$variant" = .new-token ]; then
    token_id="$variant-$$"
  else
    token_id="$variant"
  fi
  payload="$(printf '{"email":"%s","sub":"acct-%s"}' "$user" "$token_id" | b64url)"
  printf '{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","kind":"subscription","variant":"%s","tokens":{"id_token":"%s.%s.sig","refresh_token":"refresh-%s","account_id":"acct-%s"}}\n' "$variant" "$header" "$payload" "$token_id" "$token_id" \
    > "$CODEX_HOME/auth.json"
fi
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  if grep -F '"variant":"broken"' "$CODEX_HOME/auth.json" >/dev/null 2>&1; then
    printf 'not logged in\n'
    exit 1
  fi
  test -f "$CODEX_HOME/auth.json" || exit 1
  printf 'Logged in using ChatGPT\n'
fi
if [ "${1:-}" = exec ]; then
  if grep -F '"variant":"deadping"' "$CODEX_HOME/auth.json" >/dev/null 2>&1; then
    printf 'nope\n'
    exit 0
  fi
  if grep -F '"variant":"limited"' "$CODEX_HOME/auth.json" >/dev/null 2>&1; then
    printf 'usage limit reached; resets soon\n'
    exit 0
  fi
  test -f "$CODEX_HOME/auth.json" || exit 1
  if [ -n "${MA_TEST_CODEX_REFRESH_MARK:-}" ]; then
    old="$(cat "$CODEX_HOME/auth.json")"
    printf '%s\n' "$old" | sed "s/}$/,\"refresh_mark\":\"$MA_TEST_CODEX_REFRESH_MARK\"}/" > "$CODEX_HOME/auth.json"
  fi
  printf 'pong\n'
fi
SH

chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex"

run_ma new claude cn >/dev/null
run_ma new codex inferact >/dev/null
run_ma new codex cn >/dev/null
say "creates isolated account folders"

if run_ma help $(seq 1 4097) > "$CASE/argv.out" 2> "$CASE/argv.err"; then
  die "expected oversized argv to fail"
fi
assert_grep "$CASE/argv.err" "too many command arguments for one request"
say "validates oversized argv before dispatch"

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

run_ma_logged auth add codex cn sub1 >/dev/null
assert_file "$ROOT/codex-2-cn/.codex/ma-auth/sub1/auth.json"
assert_file "$ROOT/codex-2-cn/.codex/auth.json"
assert_grep "$LOG" "CODEX_HOME=$ROOT/codex-2-cn/.codex/ma-auth/sub1"
assert_grep "$LOG" "args=-c cli_auth_credentials_store=file login --device-auth"
run_ma_logged auth add codex cn sub2 >/dev/null
if ( MA_TEST_CODEX_TOKEN=sub1 run_ma_logged auth add codex cn subdup ) > "$CASE/codex-dup.out" 2> "$CASE/codex-dup.err"; then
  die "expected duplicate Codex token add to fail"
fi
assert_grep "$CASE/codex-dup.err" "same auth token"
assert_no_file "$ROOT/codex-2-cn/.codex/ma-auth/subdup/auth.json"
run_ma auth rotate codex cn >/dev/null
assert_grep "$ROOT/codex-2-cn/.codex/auth.json" '"variant":"sub2"'
run_ma auth rotate codex cn >/dev/null
assert_grep "$ROOT/codex-2-cn/.codex/auth.json" '"variant":"sub1"'
MA_TEST_CODEX_REFRESH_MARK=live-run run_ma_logged codex cn exec hi >/dev/null
unset MA_TEST_CODEX_REFRESH_MARK
assert_grep "$LOG" "args=-c cli_auth_credentials_store=file exec hi"
assert_grep "$ROOT/codex-2-cn/.codex/ma-auth/sub1/auth.json" '"refresh_mark":"live-run"'
if run_ma codex cn exec -c cli_auth_credentials_store=keyring hi > "$CASE/codex-user-auth-store.out" 2> "$CASE/codex-user-auth-store.err"; then
  die "expected managed Codex auth storage override to fail"
fi
assert_grep "$CASE/codex-user-auth-store.err" "managed Codex auth requires cli_auth_credentials_store=file"
if run_ma codex cn --config=cli_auth_credentials_store=keyring exec hi > "$CASE/codex-user-auth-store-inline.out" 2> "$CASE/codex-user-auth-store-inline.err"; then
  die "expected inline managed Codex auth storage override to fail"
fi
assert_grep "$CASE/codex-user-auth-store-inline.err" "managed Codex auth requires cli_auth_credentials_store=file"
if run_ma auth rotate codex cn > "$CASE/codex-rotate.out" 2> "$CASE/codex-rotate.err"; then
  die "expected rapid Codex rotation warning"
fi
assert_grep "$CASE/codex-rotate.err" "all codex auth tokens"
run_ma_logged auth check codex cn > "$CASE/codex-check.out" 2> "$CASE/codex-check.err"
assert_grep "$CASE/codex-check.out" "ok"
assert_grep "$CASE/codex-check.err" "auth check runs real codex status/ping calls"
assert_grep "$CASE/codex-check.err" "ma-auth/<token>/auth.json"
assert_grep "$LOG" "args=-c cli_auth_credentials_store=file exec --ephemeral --skip-git-repo-check --ignore-rules --ignore-user-config --sandbox read-only Reply exactly with the single word: pong"
run_ma auth ls codex cn > "$CASE/codex-ls.out"
assert_grep "$CASE/codex-ls.out" "auth tokens"
assert_grep "$CASE/codex-ls.out" "*   sub1"
assert_grep "$CASE/codex-ls.out" "sub2@example.test"
mkdir -p "$ROOT/codex-2-cn/.codex/ma-auth/deadping"
printf '{"kind":"subscription","variant":"deadping","tokens":{"refresh_token":"refresh-deadping","account_id":"acct-deadping"}}\n' > "$ROOT/codex-2-cn/.codex/ma-auth/deadping/auth.json"
printf 'variant\tdeadping\t0\t0\tlogin\n' >> "$ROOT/codex-2-cn/.codex/ma-auth/state.tsv"
mkdir -p "$ROOT/codex-2-cn/.codex/ma-auth/limited"
printf '{"kind":"subscription","variant":"limited","tokens":{"refresh_token":"refresh-limited","account_id":"acct-limited"}}\n' > "$ROOT/codex-2-cn/.codex/ma-auth/limited/auth.json"
printf 'variant\tlimited\t0\t0\tlogin\n' >> "$ROOT/codex-2-cn/.codex/ma-auth/state.tsv"
mkdir -p "$ROOT/codex-2-cn/.codex/ma-auth/broken"
printf '{"kind":"subscription","variant":"broken"}\n' > "$ROOT/codex-2-cn/.codex/ma-auth/broken/auth.json"
printf 'variant\tbroken\t0\t0\tlogin\n' >> "$ROOT/codex-2-cn/.codex/ma-auth/state.tsv"
if run_ma auth check codex cn --prune > "$CASE/codex-prune.out"; then
  die "expected Codex prune check to report a failed variant"
fi
assert_grep "$CASE/codex-prune.out" "bad"
assert_grep "$CASE/codex-prune.out" "deadping"
assert_grep "$CASE/codex-prune.out" "unk"
assert_grep "$CASE/codex-prune.out" "provider ping inconclusive; auth not pruned"
assert_grep "$CASE/codex-prune.out" "limited"
assert_grep "$CASE/codex-prune.out" "limit"
assert_grep "$CASE/codex-prune.out" "auth valid; provider reports usage limit"
assert_grep "$CASE/codex-prune.out" "kept"
assert_grep "$CASE/codex-prune.out" "pruned"
assert_file "$ROOT/codex-2-cn/.codex/ma-auth/deadping/auth.json"
assert_file "$ROOT/codex-2-cn/.codex/ma-auth/limited/auth.json"
assert_no_file "$ROOT/codex-2-cn/.codex/ma-auth/broken/auth.json"
assert_file "$ROOT/codex-2-cn/.codex/auth.json"
run_ma auth remove codex cn deadping >/dev/null
run_ma auth remove codex cn limited >/dev/null
run_ma auth remove codex cn sub2 >/dev/null
assert_no_file "$ROOT/codex-2-cn/.codex/ma-auth/sub2/auth.json"
assert_file "$ROOT/codex-2-cn/.codex/auth.json"
if run_ma auth remove codex cn sub1 > "$CASE/codex-remove-last.out" 2> "$CASE/codex-remove-last.err"; then
  die "expected removing the last Codex token to require clear"
fi
assert_grep "$CASE/codex-remove-last.err" "use 'ma auth clear codex cn'"
assert_file "$ROOT/codex-2-cn/.codex/ma-auth/sub1/auth.json"
run_ma auth clear codex cn >/dev/null
assert_no_file "$ROOT/codex-2-cn/.codex/ma-auth/state.tsv"
assert_no_file "$ROOT/codex-2-cn/.codex/auth.json"
say "adds, rotates, removes, and clears Codex device auth tokens"

printf '{"theme":"stable"}\n' > "$ROOT/claude-1-cn/.claude/settings.json"
MA_TEST_CLAUDE_VARIANT=csub1 run_ma_logged auth add claude cn csub1 >/dev/null
assert_file "$ROOT/claude-1-cn/.claude/ma-auth/csub1/.credentials.json"
assert_file "$ROOT/claude-1-cn/.claude/ma-auth/csub1/.claude.json"
assert_grep "$ROOT/claude-1-cn/.claude/ma-auth/csub1/.credentials.json" '"refreshToken":"refresh-csub1"'
assert_grep "$ROOT/claude-1-cn/.claude/.credentials.json" '"refreshToken":"refresh-csub1"'
assert_grep "$ROOT/claude-1-cn/.claude/ma-auth/csub1/.claude.json" 'csub1@example.test'
assert_grep "$LOG" "CLAUDE_CONFIG_DIR=$ROOT/claude-1-cn/.claude"
assert_grep "$LOG" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$ROOT/claude-1-cn/.claude/ma-auth/csub1"
assert_grep "$LOG" "PATH=$ROOT/claude-1-cn/.claude/ma-auth/.ma-file-auth-bin:"
assert_grep "$LOG" "args=auth login --claudeai"
assert_grep "$ROOT/claude-1-cn/.claude/ma-auth/.ma-file-auth-bin/security.log" "find-generic-password"
assert_grep "$ROOT/claude-1-cn/.claude/ma-auth/.ma-file-auth-bin/security.log" "add-generic-password"
MA_TEST_CLAUDE_VARIANT=csub2 run_ma_logged auth add claude cn csub2 >/dev/null
if ( MA_TEST_CLAUDE_VARIANT=csubdup MA_TEST_CLAUDE_TOKEN=csub1 run_ma_logged auth add claude cn csubdup ) > "$CASE/claude-dup.out" 2> "$CASE/claude-dup.err"; then
  die "expected duplicate Claude token add to fail"
fi
assert_grep "$CASE/claude-dup.err" "same auth token"
assert_no_file "$ROOT/claude-1-cn/.claude/ma-auth/csubdup/.credentials.json"
assert_grep "$ROOT/claude-1-cn/.claude/.claude.json" "csub1@example.test"
run_ma_logged claude cn ping-after-add >/dev/null
assert_grep "$LOG" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$ROOT/claude-1-cn/.claude/ma-auth/csub1"
assert_grep "$LOG" "CLAUDE_CODE_OAUTH_TOKEN="
assert_grep "$LOG" "PATH=$ROOT/claude-1-cn/.claude/ma-auth/.ma-file-auth-bin:"
printf '{"oauthAccount":{"kind":"subscription","emailAddress":"shared@example.test","displayName":"Shared User"},"projects":{"keep":true}}\n' \
  > "$ROOT/claude-1-cn/.claude/.claude.json"
run_ma auth rotate claude cn >/dev/null
run_ma_logged claude cn ping-after-rotate >/dev/null
assert_grep "$LOG" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$ROOT/claude-1-cn/.claude/ma-auth/csub2"
assert_grep "$ROOT/claude-1-cn/.claude/.credentials.json" '"refreshToken":"refresh-csub2"'
assert_grep "$ROOT/claude-1-cn/.claude/.claude.json" "csub2@example.test"
assert_grep "$ROOT/claude-1-cn/.claude/settings.json" '"theme":"stable"'
run_ma_logged auth check claude cn > "$CASE/claude-check.out" 2> "$CASE/claude-check.err"
assert_grep "$CASE/claude-check.out" "ok"
assert_grep "$CASE/claude-check.err" "auth check runs real claude status/ping calls"
assert_grep "$CASE/claude-check.err" "ma-auth/<token>/.credentials.json"
assert_grep "$LOG" "PATH=$ROOT/claude-1-cn/.claude/ma-auth/.ma-file-auth-bin:"
assert_grep "$LOG" "args=--safe-mode --no-session-persistence --output-format text --permission-mode dontAsk --tools  -p Reply exactly with the single word: pong"
assert_grep "$ROOT/claude-1-cn/.claude/ma-auth/.ma-file-auth-bin/security.log" "find-generic-password"
run_ma auth ls claude cn > "$CASE/claude-ls.out"
assert_grep "$CASE/claude-ls.out" "oauth:"
assert_grep "$CASE/claude-ls.out" "csub1@example.test"
mkdir -p "$ROOT/claude-1-cn/.claude/ma-auth/placeholder"
printf '<token>\n' > "$ROOT/claude-1-cn/.claude/ma-auth/placeholder/.oauth_token"
printf 'variant\tplaceholder\t0\t0\tlogin\n' >> "$ROOT/claude-1-cn/.claude/ma-auth/state.tsv"
if run_ma auth check claude cn > "$CASE/claude-placeholder-check.out"; then
  die "expected Claude placeholder token to fail local credential check"
fi
assert_grep "$CASE/claude-placeholder-check.out" "placeholder"
assert_grep "$CASE/claude-placeholder-check.out" "missing .credentials.json"
mkdir -p "$ROOT/claude-1-cn/.claude/ma-auth/deadping"
printf '{"claudeAiOauth":{"accessToken":"access-deadping","refreshToken":"refresh-deadping"}}\n' > "$ROOT/claude-1-cn/.claude/ma-auth/deadping/.credentials.json"
printf 'variant\tdeadping\t0\t0\tlogin\n' >> "$ROOT/claude-1-cn/.claude/ma-auth/state.tsv"
mkdir -p "$ROOT/claude-1-cn/.claude/ma-auth/limited"
printf '{"claudeAiOauth":{"accessToken":"access-limited","refreshToken":"refresh-limited"}}\n' > "$ROOT/claude-1-cn/.claude/ma-auth/limited/.credentials.json"
printf 'variant\tlimited\t0\t0\tlogin\n' >> "$ROOT/claude-1-cn/.claude/ma-auth/state.tsv"
mkdir -p "$ROOT/claude-1-cn/.claude/ma-auth/broken"
printf '{"claudeAiOauth":{"accessToken":"access-broken","refreshToken":"refresh-broken"}}\n' > "$ROOT/claude-1-cn/.claude/ma-auth/broken/.credentials.json"
printf 'variant\tbroken\t0\t0\tlogin\n' >> "$ROOT/claude-1-cn/.claude/ma-auth/state.tsv"
if run_ma auth check claude cn --prune > "$CASE/claude-prune.out"; then
  die "expected Claude prune check to report a failed variant"
fi
assert_grep "$CASE/claude-prune.out" "bad"
assert_grep "$CASE/claude-prune.out" "deadping"
assert_grep "$CASE/claude-prune.out" "unk"
assert_grep "$CASE/claude-prune.out" "provider ping inconclusive; auth not pruned"
assert_grep "$CASE/claude-prune.out" "limited"
assert_grep "$CASE/claude-prune.out" "limit"
assert_grep "$CASE/claude-prune.out" "auth valid; provider reports usage limit"
assert_grep "$CASE/claude-prune.out" "kept"
assert_grep "$CASE/claude-prune.out" "pruned"
assert_file "$ROOT/claude-1-cn/.claude/ma-auth/deadping/.credentials.json"
assert_file "$ROOT/claude-1-cn/.claude/ma-auth/limited/.credentials.json"
assert_no_file "$ROOT/claude-1-cn/.claude/ma-auth/broken/.credentials.json"
run_ma auth remove claude cn deadping >/dev/null
run_ma auth remove claude cn limited >/dev/null
run_ma auth remove claude cn csub1 >/dev/null
assert_no_file "$ROOT/claude-1-cn/.claude/ma-auth/csub1/.credentials.json"
run_ma_logged claude cn ping-after-remove >/dev/null
assert_grep "$LOG" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$ROOT/claude-1-cn/.claude/ma-auth/csub2"
if run_ma auth remove claude cn csub2 > "$CASE/claude-remove-last.out" 2> "$CASE/claude-remove-last.err"; then
  die "expected removing the last Claude token to require clear"
fi
assert_grep "$CASE/claude-remove-last.err" "use 'ma auth clear claude cn'"
assert_file "$ROOT/claude-1-cn/.claude/ma-auth/csub2/.credentials.json"
run_ma auth clear claude cn >/dev/null
assert_no_file "$ROOT/claude-1-cn/.claude/ma-auth/state.tsv"
assert_no_file "$ROOT/claude-1-cn/.claude/.credentials.json"
run_ma_logged claude cn ping-after-clear >/dev/null
assert_grep "$LOG" "CLAUDE_SECURESTORAGE_CONFIG_DIR="
say "adds, rotates, removes, and clears Claude subscription OAuth tokens"

run_ma new claude thorson >/dev/null
printf '{"oauthAccount":{"kind":"subscription","variant":"existing"},"projects":{"keep":true}}\n' \
  > "$ROOT/claude-3-thorson/.claude/.claude.json"
MA_TEST_CLAUDE_VARIANT=default run_ma_logged auth add claude thorson >/dev/null
assert_file "$ROOT/claude-3-thorson/.claude/ma-auth/default@example.test/.credentials.json"
assert_grep "$ROOT/claude-3-thorson/.claude/ma-auth/default@example.test/.credentials.json" '"refreshToken":"refresh-default"'
assert_grep "$LOG" "CLAUDE_CONFIG_DIR=$ROOT/claude-3-thorson/.claude"
MA_TEST_CLAUDE_VARIANT=second run_ma_logged auth add claude thorson >/dev/null
assert_file "$ROOT/claude-3-thorson/.claude/ma-auth/second@example.test/.credentials.json"
assert_grep "$ROOT/claude-3-thorson/.claude/ma-auth/second@example.test/.credentials.json" '"refreshToken":"refresh-second"'
run_ma auth rotate claude thorson >/dev/null
run_ma_logged claude thorson ping-thorson-rotate >/dev/null
assert_grep "$LOG" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$ROOT/claude-3-thorson/.claude/ma-auth/second@example.test"
assert_grep "$ROOT/claude-3-thorson/.claude/.claude.json" "second@example.test"
say "adds multiple Claude OAuth tokens under one profile"

run_ma new claude pasted >/dev/null
mkdir -p "$ROOT/claude-4-pasted/.claude/ma-auth/oauth-2"
printf '<token>\n' > "$ROOT/claude-4-pasted/.claude/ma-auth/oauth-2/.oauth_token"
printf '# ma auth state v1\ncurrent\toauth-2\nvariant\toauth-2\t0\t0\tlogin\n' \
  > "$ROOT/claude-4-pasted/.claude/ma-auth/state.tsv"
MA_TEST_CLAUDE_VARIANT=pasted run_ma_logged auth add claude pasted >/dev/null
assert_file "$ROOT/claude-4-pasted/.claude/ma-auth/pasted@example.test/.credentials.json"
assert_grep "$ROOT/claude-4-pasted/.claude/ma-auth/state.tsv" "current	pasted@example.test"
run_ma_logged claude pasted ping-after-placeholder >/dev/null
assert_grep "$LOG" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$ROOT/claude-4-pasted/.claude/ma-auth/pasted@example.test"
say "replaces a bad Claude placeholder current token on add"

if PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" MA_TEST_LOG="$LOG" OPENAI_API_KEY=sk-test \
  "$ROOT/ma" auth add codex cn blocked > "$CASE/api-block.out" 2> "$CASE/api-block.err"; then
  die "expected API-key auth add to be blocked"
fi
assert_grep "$CASE/api-block.err" "OPENAI_API_KEY is set"

rm -rf "$ROOT"/codex-*-api
run_ma new codex api >/dev/null
CODEX_API_DIR="$(ls -d "$ROOT"/codex-*-api | sed -n '1p')"
mkdir -p "$CODEX_API_DIR/.codex"
printf '{"OPENAI_API_KEY":"sk-test"}\n' > "$CODEX_API_DIR/.codex/auth.json"
run_ma auth ls codex api > "$CASE/codex-api-ls.out"
assert_grep "$CASE/codex-api-ls.out" "live auth"
assert_grep "$CASE/codex-api-ls.out" "api-key"
assert_grep "$CASE/codex-api-ls.out" "API-key auth is not rotatable"
if run_ma auth check codex api --prune > "$CASE/codex-api-check.out"; then
  die "expected live API-key auth check to fail"
fi
assert_grep "$CASE/codex-api-check.out" "api-key"
assert_grep "$CASE/codex-api-check.out" "kept"
if run_ma auth add codex api > "$CASE/codex-api-add.out" 2> "$CASE/codex-api-add.err"; then
  die "expected live API-key auth add to fail"
fi
assert_grep "$CASE/codex-api-add.err" "live api-key auth"
say "blocks API-key auth for subscription rotation"

rm -rf "$ROOT"/codex-*
run_ma new codex solo >/dev/null
CODEX_SOLO_DIR="$(ls -d "$ROOT"/codex-*-solo | sed -n '1p')"
MA_TEST_CODEX_USER=solo@example.test run_ma_logged auth add codex solo >/dev/null
assert_no_file "$CODEX_SOLO_DIR/.codex/ma-auth/.new-token/auth.json"
assert_file "$CODEX_SOLO_DIR/.codex/ma-auth/solo@example.test/auth.json"
assert_grep "$CODEX_SOLO_DIR/.codex/ma-auth/state.tsv" "current	solo@example.test"
MA_TEST_CODEX_USER=solo@example.test run_ma_logged auth add codex solo >/dev/null
assert_file "$CODEX_SOLO_DIR/.codex/ma-auth/solo@example.test-2/auth.json"
run_ma_logged auth add codex named >/dev/null
assert_file "$CODEX_SOLO_DIR/.codex/ma-auth/named/auth.json"
assert_file "$CODEX_SOLO_DIR/.codex/ma-auth/solo@example.test/auth.json"
assert_file "$CODEX_SOLO_DIR/.codex/ma-auth/solo@example.test-2/auth.json"
say "auto-names auth tokens from inferred user identity"

echo "all tests passed"
