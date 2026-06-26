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

## 轮换订阅登录

有时候你不是想建很多套配置，只是想给同一个账号文件夹准备几个可用的订阅登录。比如一个
Claude 账号文件夹里已经有配置、历史记录和插件，你只想在用量满了以后换到下一个登录。

`ma auth` 做的就是这件事：在同一个账号文件夹下面保存多个订阅登录，然后按顺序切换。轮换只换
登录，不搬配置、历史记录、会话和插件。

```sh
ma auth add codex work            # 打开 codex login --device-auth，保存一个订阅登录
ma auth add codex work            # 再保存一个
ma auth ls codex work             # 看当前有哪些登录，不打印完整 token
ma auth rotate codex work         # 切到下一个登录
ma auth check codex work --prune  # 检查这些登录，只删明确坏掉的
ma auth remove codex work sub1    # 删除其中一个
ma auth clear codex work          # 清掉这个账号文件夹下面保存的所有登录

ma auth add claude work           # 打开 claude auth login --claudeai，保存一个订阅登录
ma auth add claude work           # 再保存一个
ma auth ls claude work
ma auth rotate claude work
```

如果只有一个 `work` 账号，账号名也可以省略。平时也不用自己给登录取名字；不写最后那个
`TOKEN` 时，`ma` 会尽量用邮箱或用户名命名。名字重复时会自动加 `-2`、`-3`。如果新登录其实
和已有登录是同一份，`ma` 会拒绝保存，避免你以为自己多了一个可轮换的登录。

`ma auth ls` 只看本地文件，会告诉你当前用的是哪一个、能推断出的身份、什么时候添加、什么时候
轮换过。`ma auth check` 会真的问一次底层工具能不能用。输出大概是这几类：

- `ok`：登录可用
- `limit`：登录是真的，但服务端说用量满了；这种不会被删
- `bad`：登录已经坏了；加 `--prune` 时会删掉它
- `unk`：没法判断；也不会随便删

文件都放在这个账号自己的状态目录里。Codex 的登录保存成 `ma-auth/<name>/auth.json`。Claude 的
登录保存成 `ma-auth/<name>/.credentials.json`，启动 Claude 时 `ma` 会让 Claude 使用当前选中的
那一份。Claude 的设置、项目记录、历史、会话和插件还是留在共享的 `.claude/`
目录里；轮换时只换登录和少量账号身份字段。

这里特意不用 `claude setup-token`，也不用 `CLAUDE_CODE_OAUTH_TOKEN`。那类 token 可以发起推理请求，
但不适合完整的交互式 Claude 会话。`ma` 要保存的是 Claude 自己可刷新的订阅 OAuth 登录；如果
Claude 只把登录塞进 macOS Keychain，没有写出可轮换的 `.credentials.json`，`ma auth add claude ...`
会直接失败。

这个功能只支持订阅登录。`OPENAI_API_KEY`、`ANTHROPIC_API_KEY` 这类 API key 会被拒绝，因为它们
不是同一种登录，也没法按这个方式当备用登录切换。10 分钟内所有登录都轮换过时，`ma auth rotate` 会
给出警告并退出，提醒你先看一下用量，别一直空转。

`ma` 每次命令只加载固定数量的数据到内存；这不是磁盘文件数量上限。磁盘上可以继续放更多账号、
登录和会话文件。单次命令最多加载每个程序 4096 个账号、每个账号文件夹 4096 个登录、
4096 行会话列表，以及 `programs.conf` 每个程序 16 个状态目录映射。碰到边界时，错误
会说明这是单次命令的加载上限，并且不会改动已经保存的文件。

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
