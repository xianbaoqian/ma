#!/bin/sh
# Build the single-file, cross-platform `ma` — and optionally copy it to the folders
# where you actually keep accounts.
#
# Run it:   ./build.sh
#
# What you get: one file, ./ma, that runs on macOS, Linux, and Windows-via-WSL with no
# install and no runtime. (How that's possible is explained in the README.)
#
# What it needs: zig 0.16 (https://ziglang.org/download/) and the usual base64 — both
# already present on a normal mac or Linux box.
#
# Deploying to your own folders: if a file called `deploy.conf` sits next to this script,
# every folder listed in it gets a fresh copy of `ma` at the end of the build. One line
# per folder, '#' for comments, `~` is allowed. This file is gitignored, so your personal
# paths never end up in the repo.
set -e
cd "$(dirname "$0")"

# --- make sure zig is here, with a clear message if it isn't ---
if ! command -v zig >/dev/null 2>&1; then
  echo "build: I need the 'zig' compiler and can't find it on your PATH." >&2
  echo "       Grab zig 0.16 from https://ziglang.org/download/ and try again." >&2
  exit 1
fi

# --- 1. cross-compile the same source once per platform, into a throwaway dir ---
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "Building three native engines from launcher.zig ..."
zig build-exe launcher.zig -femit-bin="$tmp/ma-MACARM"   -target aarch64-macos -O ReleaseSmall
zig build-exe launcher.zig -femit-bin="$tmp/ma-LINUXARM" -target aarch64-linux -O ReleaseSmall
zig build-exe launcher.zig -femit-bin="$tmp/ma-LINUXX86" -target x86_64-linux  -O ReleaseSmall

# --- 2. write the little shell "recipe" that picks the right engine at run time ---
# (Quoted heredoc: everything below is stored literally and only runs later, on the user's
# machine — not now, during the build.)
cat > ma <<'WRAP'
#!/bin/sh
# This file is a shell script with three native programs hidden inside it. A mac program
# and a Linux program are genuinely different files and can't be the same bytes, so this
# file isn't a program at all — it's a recipe that both systems know how to read. When you
# run it, the recipe checks which system you're on, peels off the matching program, and
# runs that. See the project README for the full story.
set -e
case "$(uname)-$(uname -m)" in
  Darwin-arm64)  tag=MACARM ;;
  Linux-aarch64) tag=LINUXARM ;;
  Linux-x86_64)  tag=LINUXX86 ;;
  *) echo "ma: no built-in engine for $(uname)-$(uname -m)" >&2; exit 1 ;;
esac
# Follow $0 (which may be an account symlink, e.g. claude -> ../ma) back to the real file,
# so we always find the folder this `ma` actually lives in.
self="$0"; case "$self" in */*) ;; *) self="$(command -v "$self")" ;; esac
while [ -L "$self" ]; do
  d="$(cd "$(dirname "$self")" && pwd)"; l="$(readlink "$self")"
  case "$l" in /*) self="$l" ;; *) self="$d/$l" ;; esac
done
home="$(cd "$(dirname "$self")" && pwd)"
# Peel off the right engine next to `ma` (never into ~/.cache — everything stays local and
# you can see it). Re-extract whenever `ma` is newer, so an updated `ma` is never stale.
bin="$home/ma-$tag"
if [ ! -x "$bin" ] || [ "$self" -nt "$bin" ]; then
  sed -n "/^#${tag}_BEGIN\$/,/^#${tag}_END\$/p" "$self" | sed '1d;$d' | base64 -d > "$bin"
  chmod +x "$bin"
fi
# Tell the engine where it lives and how it was called, then hand off.
MA_HOME="$home" MA_ARGV0="$0" exec "$bin" "$@"
WRAP

# --- 3. base64-encode each engine and staple it onto the end, between markers ---
for tag in MACARM LINUXARM LINUXX86; do
  echo "#${tag}_BEGIN"; base64 < "$tmp/ma-$tag"; echo "#${tag}_END"
done >> ma
chmod +x ma
echo "Built ./ma ($(wc -c < ma) bytes) — mac-arm64 + linux-arm64 + linux-x86_64."

# --- 4. optional: copy the fresh ma into your own account folders ---
if [ -f deploy.conf ]; then
  echo "Deploying to the folders in deploy.conf ..."
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac      # skip blanks and comments
    dir="$(eval echo "$line")"                     # allow ~ to expand
    if [ -d "$dir" ]; then
      cp ma "$dir/ma" && chmod +x "$dir/ma"
      echo "  -> $dir/ma"
    else
      echo "  !! skipped (no such folder): $dir" >&2
    fi
  done < deploy.conf
fi
