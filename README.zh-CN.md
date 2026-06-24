# ma：把多个 AI CLI 账号分开放

[English README](README.md)

如果你有好几个 `claude`、`codex`、`kimi` 或 `opencode` 账号，它们默认都会抢同一个
隐藏配置目录，比如 `~/.claude`、`~/.codex`。登录一个账号，另一个账号就容易被挤掉。

`ma` 的做法很直白：**一个账号一个文件夹**。启动工具前，`ma` 只做一件事：把这个工具的
配置环境变量指向对应账号文件夹，然后运行真正的工具。

比如：

```sh
ma new claude work
ma claude work
```

`work` 这个 Claude 账号的东西会放在 `claude-1-work/.claude/` 里，不会去碰你的
`personal` 账号。

## 下载和安装

仓库里已经带了一个可以直接运行的 `ma` 文件，支持这些 Unix-like 平台：Apple Silicon
macOS、Intel macOS、Linux ARM64、Linux x86_64。直接 clone 仓库，然后运行安装脚本：

```sh
git clone https://github.com/xianbaoqian/ma
cd ma
./install.sh ~/ai-accounts        # 选择账号文件夹放在哪里
```

安装脚本会把 `ma` 复制到账号根目录，必要时写入初始 `programs.conf`，并打印一行可以放进
shell 配置的 `alias`。

如果你的平台不在上面的内置目标里，或者你想自己重新构建这个单文件二进制，先运行
`./build.sh`，再运行 `./install.sh`。

如果还没安装，只想在 clone 下来的仓库里直接试一下，也可以运行：

```sh
./ma ls
```

## 常用命令

```sh
ma new claude work          # 新建一个 claude 账号，名字叫 work
ma claude work              # 用 work 这个账号启动 claude
ma claude 1                 # 也可以用 id 启动
ma claude ps                # 看当前目录相关的 session
ma ls                       # 看有哪些账号、有没有登录
```

## alias 和 symlink 怎么选

`install.sh` 打印出来的 alias 是最清楚的做法：

```sh
alias ma="$HOME/ai-accounts/ma"
```

这样 `ma` 这个文件一直放在账号根目录里，旁边就是 `programs.conf` 和所有账号文件夹。

如果你想把 `ma` 放进 `PATH`，也可以用 symlink：

```sh
ln -s "$HOME/ai-accounts/ma" "$HOME/bin/ma"
```

这个是可以的。`ma` 的外层 shell wrapper 会顺着 symlink 找回真正的文件，所以还是会用
`$HOME/ai-accounts/programs.conf`。

不要把 `ma` 直接复制到 `~/bin` 当成一个独立文件用。复制出来的 `~/bin/ma` 会以为
`~/bin` 才是账号根目录，于是去找 `~/bin/programs.conf`，新账号也会建到 `~/bin` 下面。
想放进 `PATH`，用 symlink，不要 copy。

账号文件夹里也有一个同名启动器，比如：

```sh
./claude-1-work/claude
```

它只是指回 `ma`。`ma` 根据自己是从哪个文件夹被启动的，知道该用哪个账号。

## resume 找错账号怎么办

有时候你手里有 session id，但是忘了它是哪个账号创建的。比如你运行：

```sh
ma claude work --resume fbfdb307-0866-4923-9e77-8a2a4274086e
```

如果这个 session 不在 `work` 账号里，`ma` 会去同类账号里找。找到唯一一个匹配时，它会先问你：

```text
ma: claude session ... is in claude-2-personal, not account 'work'
ma: move it into 'work'? [y/N]
```

输入 `y`，它才会移动。它会移动这些东西：

- session 的 `.jsonl` 文件
- Claude 可能带的同名 sidecar 文件夹
- `history.jsonl` 里包含这个 session id 的记录

输入其他内容，什么都不动。

这个功能现在支持 Claude 和 Codex，也会递归查子目录；session 文件不需要正好在
`.claude/` 或 `.codex/` 第一层。opencode 的 session 在 SQLite 数据库里，`ma` 不会搬数据库
记录；如果 `-s` 或 `--session` 指向了别的账号，它会告诉你这个 session 在哪个账号里。

## 看当前目录的 session

把 `ps` 放在工具名后面，可以列出当前项目目录相关的 session：

```sh
ma claude ps
ma codex ps
ma opencode ps
```

表格里会显示账号、session id、最后活跃时间、开始时间、持续时间和 topic。opencode 会在每个
账号的环境里调用 `opencode db --format tsv` 查询。

## 添加新工具

工具列表在 `programs.conf`。加新工具通常只要一行：

```text
gemini | gemini | GEMINI_CONFIG_DIR=.gemini
```

意思是：运行 `gemini` 时，把 `GEMINI_CONFIG_DIR` 指向当前账号文件夹里的 `.gemini`。

## 构建和测试

需要 Zig 0.16：

```sh
./test.sh
./build.sh
```

`./test.sh` 会临时构建一个 `ma`，用假的 `claude` 和 `codex` 做回归测试，确认新建账号、
resume 搬家、`history.jsonl` 搬家、拒绝移动、中文账号名都能工作。

`./build.sh` 会先跑测试，再构建最终的单文件 `ma`。如果本地有 `deploy.conf`，它还会把新的
`ma` 复制到里面列出的账号根目录。

## 文件在哪里

源码在 `src/`：

- `src/launcher.zig`：命令分发、启动真正的工具
- `src/manifest.zig`：读 `programs.conf`、解析账号文件夹名
- `src/resume.zig`：resume 找错账号时的确认和移动逻辑

账号数据不进 git。`.gitignore` 默认忽略所有东西，只把项目源码和脚本放出来，避免误提交登录
信息。
