#!/bin/sh
# Set up a folder to keep your isolated accounts in.
#
# Run it:   ./install.sh [folder]
#   - no argument:  installs into ./accounts next to this script
#   - with a path:  installs there (created if needed), e.g. ./install.sh ~/ai-accounts
#
# It copies the single `ma` file into that folder, drops a starter programs.conf if there
# isn't one, and prints the one alias line you need. That folder then *is* your accounts
# home: every account you make lives inside it as a plain, visible sub-folder.
set -e
cd "$(dirname "$0")"

if [ ! -x ./ma ]; then
  echo "install: I don't see a built ./ma here. Run ./build.sh first (needs zig)," >&2
  echo "         or download a prebuilt ma into this folder." >&2
  exit 1
fi

dest="${1:-./accounts}"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"          # make it absolute for the alias line

cp ./ma "$dest/ma"; chmod +x "$dest/ma"
if [ ! -f "$dest/programs.conf" ]; then
  cp ./programs.conf "$dest/programs.conf"
  echo "Wrote a starter programs.conf (edit it to add or change tools)."
fi

# Guess the right rc file so the printed line is copy-paste ready.
case "${SHELL##*/}" in
  zsh)  rc="~/.zshrc"  ;;
  bash) rc="~/.bashrc" ;;
  *)    rc="your shell's startup file" ;;
esac

echo
echo "Done. Your accounts will live in: $dest"
echo
echo "Add this line to $rc so you can type 'ma' from anywhere:"
echo
echo "    alias ma='$dest/ma'"
echo
echo "Then start a new shell and try:"
echo "    ma new claude work     # make an isolated 'work' account for claude"
echo "    ma claude work         # run it (after you log in once)"
echo "    ma ls                  # see all your accounts"
