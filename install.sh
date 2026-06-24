#!/bin/sh
# Set up a folder to keep your isolated accounts in.
#
# Run it:   ./install.sh [folder]
#   - no argument:  installs into ./accounts next to this script
#   - with a path:  installs there (created if needed), e.g. ./install.sh ~/ai-accounts
#
# It copies the single `ma` file into that folder, drops a starter programs.conf if there
# isn't one, records the folder in deploy.conf for future builds, and prints the one alias
# line you need. That folder then *is* your accounts home: every account you make lives
# inside it as a plain, visible sub-folder.
set -e
cd "$(dirname "$0")"

# Expand an install target path without invoking the shell on user data.
# Example: expand_path "~/ai-accounts" prints "$HOME/ai-accounts".
expand_path() {
  case "$1" in
    '~')    printf '%s\n' "$HOME" ;;
    '~/'*)  printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

# Add the install target to deploy.conf if it is not already present.
# Example: with dest=/Users/me/ai-accounts, appends that path for future ./build.sh deploys.
register_deploy_target() {
  deploy_conf=deploy.conf
  found=0

  if [ -f "$deploy_conf" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      path="$(expand_path "$line")"
      if [ -d "$path" ]; then
        path="$(cd "$path" && pwd)"
      fi
      if [ "$path" = "$dest" ]; then
        found=1
        break
      fi
    done < "$deploy_conf"
  fi

  if [ "$found" -eq 1 ]; then
    return 0
  fi

  if [ ! -f "$deploy_conf" ]; then
    if ! {
      echo '# Folders that should get a fresh copy of `ma` whenever you run ./build.sh.'
      echo "# One folder per line. Lines starting with '#' are comments. '~' expands to your home dir."
      echo '# This file is gitignored, so these personal paths never leave your machine.'
    } > "$deploy_conf"; then
      echo "install: couldn't update deploy.conf; future ./build.sh runs won't auto-deploy here." >&2
      return 0
    fi
  fi

  if printf '%s\n' "$dest" >> "$deploy_conf"; then
    echo "Registered this folder in deploy.conf for future ./build.sh deploys."
  else
    echo "install: couldn't update deploy.conf; future ./build.sh runs won't auto-deploy here." >&2
  fi
}

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
register_deploy_target

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
echo "    ma claude work         # run that account"
echo "    ma ls                  # see all your accounts"
