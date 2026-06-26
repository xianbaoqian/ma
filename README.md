# ma — run many isolated accounts of your AI CLIs, side by side

[中文说明](README.zh-CN.md)

If you have more than one account for tools like `claude`, `codex`, `kimi`, or `opencode`,
they normally fight over the same hidden config folder in your home directory (`~/.claude`,
`~/.codex`, …). Log into one and you've logged out of the other.

`ma` fixes that in the simplest way possible: **one folder per account.** Each account is
just a directory, and `ma` points the tool's config at that directory before launching it.
Your work account and your personal account never touch each other.

There's no daemon, no database, no hidden state. An account is a folder you can see, copy,
back up, or delete with `rm`. The whole idea fits in one sentence:

> An isolated account is a set of environment variables pointed at one folder, then run the tool.

## Why this one and not the dozen others

There are several good multi-account tools already. `ma` is different in two ways that
might matter to you:

1. **It's one small file that runs everywhere supported, with nothing to install.** Not an
   npm package, not a per-OS download, not a script you have to source. One roughly
   megabyte-sized `ma` file carries the native engines for Apple Silicon Macs, Intel Macs,
   Linux ARM, and Linux x86_64, squeezed together behind the same command. Copy the same
   file to a new machine and it just works. (The trick that makes this possible is
   explained near the bottom — it's genuinely interesting.)

2. **Everything is local and visible.** Nothing is written to `~/.config` or a registry.
   The accounts live in the folder you choose, named so you can read them at a glance, and
   the only "state" is the folder names themselves. You can audit the whole thing by looking.

## Download and install

The repository already includes a ready-to-run `ma` file for supported Unix-like platforms:
Apple Silicon macOS, Intel macOS, Linux ARM64, and Linux x86_64. Clone it and run the
included installer:

```sh
git clone https://github.com/xianbaoqian/ma
cd ma
./install.sh ~/ai-accounts        # choose where account folders should live
```

The installer copies that `ma` file into your account folder, writes a starter
`programs.conf` if needed, and prints one `alias` line to add to your shell.

If your platform is not one of the bundled targets, or you want to rebuild the bundled
binary yourself, use `./build.sh` first and then run `./install.sh`.

## Getting started

After installation, from anywhere:

```sh
ma new claude work                # create an isolated "work" account for claude
ma claude work                    # use it — anytime, from any project directory
ma ls                             # list every account and whether it's logged in
```

If you are working directly from the cloned repository without installing yet, you can also
run the bundled file in place:

```sh
./ma ls
```

Everything you type after the account name is passed straight through to the real tool, so
`ma claude work --resume` does exactly what `claude --resume` would, just for that account.

## Alias or symlink?

Use the alias printed by `install.sh`:

```sh
alias ma="$HOME/ai-accounts/ma"
```

That is the clearest setup: the `ma` file stays inside the account root, next to
`programs.conf` and all account folders.

A symlink from a directory on your `PATH` also works:

```sh
ln -s "$HOME/ai-accounts/ma" "$HOME/bin/ma"
```

The wrapper follows that symlink back to the real file, so it still finds
`$HOME/ai-accounts/programs.conf`.

Do not copy `ma` into `~/bin` as a standalone file. A copied `~/bin/ma` thinks `~/bin` is
the account root, so it looks for `~/bin/programs.conf` and creates accounts there. If you
want a `PATH` command, symlink to the installed `ma` instead of copying it.

## Resume from the wrong account

Sometimes you remember the session id, but not which account created it:

```sh
ma claude work --resume fbfdb307-0866-4923-9e77-8a2a4274086e
```

If that session is not in `work`, `ma` now checks the other folders for the same program.
If it finds exactly one match, it tells you where it found it and asks before moving
anything:

```text
ma: claude session ... is in claude-2-personal, not account 'work'
ma: move it into 'work'? [y/N]
```

Answer `y` and `ma` moves the session file into the account you asked to use, moves Claude's
sidecar folder when there is one, and moves the matching `history.jsonl` rows too. Answer
anything else and nothing is moved.

This works for Claude and Codex. It checks nested session paths, so the session does not
have to be directly under `.claude/` or `.codex/`. opencode sessions live in its SQLite
database, so `ma` does not move rows; it detects when `-s`/`--session` points at another
account and tells you which account owns it.

## Sessions in this folder

Use `ps` after the program name to see sessions for the current project directory:

```sh
ma claude ps
ma codex ps
ma opencode ps
```

The table shows the account, session id, last seen time, start time, duration, and topic.
For opencode, `ma` asks `opencode db --format tsv` under each account's environment.

## Rotate subscription logins

For Codex and Claude, each `ma` profile/account can hold multiple subscription OAuth/device
logins. Rotation swaps the active token for that profile without touching settings, history,
sessions, or plugins:

```sh
ma auth add codex work sub1       # runs: codex login --device-auth
ma auth add codex work            # adds another token under the same profile
ma auth ls codex work             # show stored tokens without printing secrets
ma auth rotate codex work         # swaps to the next stored auth.json
ma auth check codex work --prune  # test tokens and remove broken ones
ma auth remove codex work sub1    # delete one stored token
ma auth clear codex work          # delete all stored tokens for this profile

ma auth add claude work sub1      # runs: claude auth login --claudeai
ma auth add claude work           # adds another Claude subscription OAuth login
ma auth ls claude work
ma auth rotate claude work
```

The login tokens live under the account state folder in `ma-auth/`, and rotation metadata
is stored in `ma-auth/state.tsv`. Codex stores `auth.json`; Claude stores refresh-capable
subscription OAuth credentials in `.credentials.json` under each token slot and launches
Claude with `CLAUDE_SECURESTORAGE_CONFIG_DIR` pointed at the selected slot. For Claude child
processes, `ma` also puts a small private `security` shim first in `PATH`, so Claude's macOS
Keychain calls fail and Claude uses its file-backed secure-storage fallback. It does not use
`claude setup-token` or `CLAUDE_CODE_OAUTH_TOKEN`, because those long-lived setup tokens are
inference-only and do not support the full interactive Claude session. Shared config,
projects, history, sessions, and plugins stay in place. If there is only one account for the
program, the account name can be omitted. If the auth slot name is omitted, `ma` names the
token from the inferred user identity, such as an email address; repeated identities get
`-2`, `-3`, and so on. Existing older `default` slots continue to work only if they contain
refresh-capable credential files. Explicit slot names are only for cases where you want to
name a token yourself. If a new login produces the same stored credential as an existing
token, `ma` refuses it and leaves the current token selected.

`ma auth ls` reads only local files and shows the current marker, token slot name, a short
fingerprint, inferred identity when available, and add/rotate times. `ma auth check` asks
the underlying tool to validate each stored login, then makes a small non-interactive
provider ping. It reports `ok`, `limit`, `bad`, or `unk`; with `--prune`, only clearly
invalid auth (`bad`) is removed from `ma-auth/`. Quota-limited and inconclusive logins are
kept and are printed as `kept`.

The stored login is refresh-capable, but the live OAuth access token inside it is still
short-lived. If a slot has been idle for a while, run a tiny command through that account so
the real CLI can refresh it, for example `ma claude work -p hi` or
`ma codex work exec --skip-git-repo-check hi`. `ma auth check` also exercises the saved
logins this way, so it may refresh token files under `ma-auth/<token>/`. `state.tsv` stores
only the current token name and add/rotate times, not OAuth tokens.

Claude token metadata is saved as a sanitized `.claude.json` artifact with selected
OAuth account fields only. Rotation writes only those selected `oauthAccount` fields and
the selected `.credentials.json` back to the shared `.claude/` directory; other Claude
settings remain in place. If Claude stores OAuth only in macOS Keychain and does not write
`.credentials.json` into the selected slot even with the Keychain shim, `ma auth add claude
...` fails immediately because that login cannot be rotated as a file-backed token.

Auth rotation is subscription-only: API-key auth or credential environment variables such
as `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` are blocked because they cannot fall back the
same way. If every stored login was rotated within the last 10 minutes, `ma auth rotate`
warns and exits so you can double-check usage or rest.

`ma` uses a fixed RAM workspace for each command. Files on disk are not capped by these
numbers, but one invocation will load at most 4096 accounts per program, 4096 auth tokens
per profile, 4096 session rows, and 16 state env mappings per program line in
`programs.conf`. If a command hits one of those bounds, the error says it is a per-command
RAM/load limit and leaves the stored files alone.

## The commands

| command | what it does |
| --- | --- |
| `ma new PROGRAM ACCOUNT` | create a new isolated account folder |
| `ma auth add PROGRAM [ACCOUNT] [TOKEN]` | add a Codex/Claude subscription login token |
| `ma auth ls PROGRAM [ACCOUNT]` | list stored auth tokens and local metadata |
| `ma auth rotate PROGRAM [ACCOUNT]` | rotate to the next stored subscription login |
| `ma auth check PROGRAM [ACCOUNT] [--prune]` | validate stored auth tokens and optionally remove broken ones |
| `ma auth remove PROGRAM [ACCOUNT] TOKEN` | remove one stored auth token |
| `ma auth clear PROGRAM [ACCOUNT]` | remove all stored auth tokens for a profile |
| `ma PROGRAM NAME` | run that account (everything after is passed through) |
| `ma PROGRAM ID` | same, but pick the account by its number |
| `ma PROGRAM ps` | list this folder's Claude, Codex, or opencode sessions |
| `ma ls` | list all accounts and their login state |
| `ma help` | usage |

You can also run an account directly without the alias: each account folder contains a
launcher named after the tool, e.g. `./claude-1-work/claude`.

## Adding another tool — one line

Tools are listed in `programs.conf`. To support a new one, add a single line:

```
# name | binary | state env mappings (VAR=dir, space-separated)
gemini | gemini | GEMINI_CONFIG_DIR=.gemini
```

- **name** is what you type on the command line and what shows up in folder names.
- **binary** is the actual program to run (found on your `PATH`).
- **VAR=dir** is a state env mapping: it points the tool's config environment variable at a folder inside the account.
  The included tools already work; most CLIs have a variable like this.

That's all. Existing accounts pick up the change the next time you launch them.

## How it works (the short version)

Each account folder is named `PROGRAM-ID-ACCOUNT`, for example `claude-1-work`. That name
is the *only* place the account's identity is stored. Inside the folder, `ma` keeps the
tool's config exactly where the tool expects it — `claude-1-work/.claude/` holds what would
normally be in `~/.claude`. So `ls -a claude-1-work` shows you the account's entire world.

Inside each folder is a launcher named after the tool (`claude-1-work/claude`), which is
just a symlink back to `ma`. When you run it, `ma` works out which account it is from its
own location, sets the right environment variable, and hands off to the real tool. Change
how a tool is isolated in `programs.conf` and every existing account follows along — there's
nothing to regenerate.

## How one file runs on both macOS and Linux (the interesting part)

A macOS program and a Linux program are genuinely different files. The operating system
decides what to run by reading the very first bytes of a file: macOS looks for one specific
marker, Linux looks for a different one, and they can't both be first. So a single file
**cannot** be a native program for both systems at once. That's not a limitation of any
tool — it's how the two systems work.

`ma` sidesteps this by **not being a program at all.** It's a shell script — a recipe —
and a recipe is something *both* systems already know how to read. Stapled invisibly to the
end of that recipe are the real programs: one built for Apple Silicon Macs, one for Intel
Macs, one for Linux on ARM chips, and one for Linux on x86_64 chips. When you run `ma`, the
recipe looks at which system and chip you're on, peels off the matching program into the
same folder, and runs it.

So the magic isn't "one native program format that every OS agrees on." It's one uniform
file that every supported system can start, carrying the right native program for each
system inside it, handing over to the correct one on the spot. The first time you run `ma`
on a machine, it leaves the unpacked program sitting right next to itself (named like
`ma-MACARM`) so you can see exactly what ran — and so it doesn't have to unpack again.

This idea has a famous, more powerful cousin called **Cosmopolitan / APE**, which does the
same thing at a deeper level and even covers native Windows. `ma` uses the simple version
because it needs no special compiler and no runtime — just the shell that every Mac and
Linux box already has.

### What about Windows?

The single file does **not** run on native Windows (the Command Prompt / double-click world)
— Windows doesn't read the kind of recipe Mac and Linux do. It **does** run under **WSL**
(Windows Subsystem for Linux), because WSL is real Linux. Keep the folder on the Linux side
of WSL (your WSL home), not on the mounted `C:` drive, where unpacking can fail.

One more Windows note, even under WSL: Claude on Windows keeps a little extra state in
`~/.claude.json`, outside the config folder, so two accounts sharing one Windows home can
still collide. macOS and Linux don't have this wrinkle.

## Building from source

You need [zig 0.16](https://ziglang.org/download/). Then:

```sh
./build.sh
```

That runs the regression tests, then cross-compiles the engine for four targets — macOS ARM,
macOS x86_64, Linux ARM, and Linux x86_64 — and squeezes them into one small `ma` file. You
don't need a Linux machine to build the Linux versions — zig does it all from one box. If
local `deploy.conf` exists, `build.sh` also drops the fresh `ma` into every folder listed
there. `install.sh` adds its install target to that file automatically; edit `deploy.conf`
by hand only when you want to add, remove, or comment out extra deployment folders. There
is no separate `deploy.sh`; deployment is just the final optional step of `build.sh`. The
file is ignored by git because it contains personal machine paths.

The source lives in `src/`. For a faster behavior check without the cross-platform package
step, run:

```sh
./test.sh
```

The test builds a temporary `ma`, creates fake `claude` and `codex` binaries, and verifies
account creation, resume-session adoption, `history.jsonl` movement, decline behavior, and
non-ASCII account names.

## Where your logins live, and git

Per-account logins sit in the dotfile folders inside each account (`.claude/`, `.codex/`,
…). The included `.gitignore` keeps those out of version control — only the tool itself is
ever committed. Auth rotation reads and copies only the credential artifacts needed for the
selected program; `ma auth ls` prints fingerprints and inferred identities, not secrets.

## License

MIT. See [LICENSE](LICENSE).
