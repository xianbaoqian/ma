# ma — run many isolated accounts of your AI CLIs, side by side

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

## Getting started

You need the single `ma` file. Either build it (see *Building* below) or grab a prebuilt
one, then:

```sh
./install.sh ~/ai-accounts        # set up a folder to hold your accounts
```

That copies `ma` into the account folder, writes a starter `programs.conf` if needed,
registers that folder in local `deploy.conf` for future builds, and prints one `alias`
line to add to your shell. After that, from anywhere:

```sh
ma new claude work                # create an isolated "work" account for claude
ma claude work /login             # log in once (the login lands inside the folder)
ma claude work                    # use it — anytime, from any project directory
ma ls                             # list every account and whether it's logged in
```

Everything you type after the account name is passed straight through to the real tool, so
`ma claude work --resume` does exactly what `claude --resume` would, just for that account.

## The commands

| command | what it does |
| --- | --- |
| `ma new PROGRAM ACCOUNT` | create a new isolated account folder |
| `ma PROGRAM NAME` | run that account (everything after is passed through) |
| `ma PROGRAM ID` | same, but pick the account by its number |
| `ma ls` | list all accounts and their login state |
| `ma help` | usage |

You can also run an account directly without the alias: each account folder contains a
launcher named after the tool, e.g. `./claude-1-work/claude`.

## Adding another tool — one line

Tools are listed in `programs.conf`. To support a new one, add a single line:

```
# name | binary | VAR=dir pairs (space-separated)
gemini | gemini | GEMINI_CONFIG_DIR=.gemini
```

- **name** is what you type on the command line and what shows up in folder names.
- **binary** is the actual program to run (found on your `PATH`).
- **VAR=dir** points the tool's config environment variable at a folder inside the account.
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

That cross-compiles the engine for four targets — macOS ARM, macOS x86_64, Linux ARM, and
Linux x86_64 — and squeezes them into one small `ma` file. You don't need a Linux machine
to build the Linux versions — zig does it all from one box. If local `deploy.conf` exists,
`build.sh` also drops the fresh `ma` into every folder listed there. `install.sh` adds its
install target to that file automatically; edit `deploy.conf` by hand only when you want to
add, remove, or comment out extra deployment folders. There is no separate `deploy.sh`;
deployment is just the final optional step of `build.sh`. The file is ignored by git
because it contains personal machine paths.

## Where your logins live, and git

Per-account logins sit in the dotfile folders inside each account (`.claude/`, `.codex/`,
…). The included `.gitignore` keeps those out of version control — only the tool itself is
ever committed. `ma` never reads or copies your credentials; it only sets environment
variables and launches the real tool.

## License

MIT. See [LICENSE](LICENSE).
