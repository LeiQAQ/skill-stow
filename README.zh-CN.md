# skill-stow

**AI agent skill 的"单一真源"管理：用 Windows junction / Unix symlink 把精选的 skill 目录挂载进任意多个 AI 编码工具——零复制、零依赖、一份纯文本清单。**

[English](./README.md)

```
~/.codex/skills/stickman-topic        ← skill 的真身只在这里
~/.workbuddy/skills/stickman-topic    ← junction → 同一个目录
~/.claude/skills/stickman-topic       ← junction → 同一个目录
```

## 为什么

各家 AI 编码工具（Claude Code、Codex、WorkBuddy/CodeBuddy、Cursor、Gemini CLI……）各自读自己的 skills 目录。现有 GUI 管理器的方案是**中心库**：先把 skill 复制进管理器的仓库，再分发出去——意味着重复副本、第二个真源、还要一套元数据数据库保持同步。

**skill-stow 把模型反过来。** skill 留在原籍，agent 目录里只有链接。一份精选清单决定*哪些* skill 出现在*哪里*。卸载只删链接，绝不碰源文件。

| | GUI skill 管理器 | **skill-stow** |
|---|---|---|
| 模型 | 中心库 → 复制/symlink 分发 | **源即真相 → 链接挂入** |
| skill 副本数 | 中心库 1 份 + 每 agent 一份 | **0 份复制** |
| 配置 | 应用内数据库 | **纯文本 `Stowfile`**（可直接进 git 评审） |
| 依赖 | Tauri/React/Rust 桌面应用 | **无** — 一个 PowerShell 或 bash 脚本 |
| Windows 链接 | symlink 优先，junction 兜底 | **junction 优先**（免管理员、免开发者模式） |

## 安装

无需安装。把 `skill-stow.ps1`（Windows）或 `skill-stow.sh`（macOS/Linux）放到任意位置，旁边放一份 `Stowfile`。

已经在手工挂载？一条命令把现状收编成清单：

```bash
python3 adopt.py ~/.workbuddy/skills Stowfile   # 扫描链接、按源分组、导出 Stowfile
```

## Stowfile 清单格式

```text
# skill-stow 清单 — 纯文本，'#' 开头是注释

target workbuddy   ~/.workbuddy/skills
target claude      ~/.claude/skills

source main        ~/.codex/skills
source superpowers ~/.codex/superpowers/skills

# mount <target> <source> <skill> [skill ...]
mount workbuddy main        stickman-topic stickman-script-draft
mount workbuddy superpowers brainstorming verifying
```

- `source` — skill 真正存放的位置。
- `target` — 某 agent 的 skills 目录（目录需存在，agent 本体无需在运行）。
- `mount` — 每行一条挂载决策，一行可带多个 skill。
- 真实的 `Stowfile` 是机器相关的，走 `.gitignore`；仓库里只提交 `Stowfile.example`——和 `.env` 同一套模式。

## 命令

```powershell
# Windows (PowerShell)
.\skill-stow.ps1 audit              # 清单 vs 磁盘全量比对，报告所有不一致
.\skill-stow.ps1 mount -All         # 建齐所有缺失的 junction
.\skill-stow.ps1 mount -Target workbuddy -Name brainstorming
.\skill-stow.ps1 unmount -All -DryRun
.\skill-stow.ps1 doctor             # 断链、碰撞、多余链接体检
.\skill-stow.ps1 list               # 挂载清单 + 状态
```

```bash
# macOS / Linux（真 symlink）
./skill-stow.sh audit
./skill-stow.sh mount -all
./skill-stow.sh unmount -target workbuddy -name brainstorming
```

`audit` / `doctor` 的状态含义：

| 状态 | 含义 |
|---|---|
| `OK` | 链接存在且指向清单声明的源 |
| `MISSING` | 清单要求挂载，磁盘上没有 |
| `DRIFTED` | 链接存在但指向了别处 |
| `COLLISION` | 真实目录占了链接位置——**永不自动删除** |
| `EXTRA` | 磁盘上存在但清单不认识的链接 |
| `BROKEN` | 链接存在但源目录已消失 |

## 安全规则（代码强制，不只是文档）

1. **永远不写源目录。** 脚本只在 target 目录里创建/删除链接。
2. **`unmount` 删链接必须同时满足**：(a) 它是 reparse point（PowerShell 里 `LinkType -eq 'Junction'`，Unix 上 `-L`）；(b) 链接目标与清单声明的源一致。真实目录一律拒绝。
3. 所有改动型命令都支持 `--dry-run`。
4. Windows 上优先 junction：不需要管理员权限，也不需要开发者模式——目录 symlink 两者必居其一。

## Windows junction 踩坑表（本项目的核心沉淀）

以下每一条都是真实踩过的坑，脚本里已处理或已在文档说明：

| 坑 | 细节 |
|---|---|
| `os.path.islink()` 对 junction 说谎 | Python 返回 `False`。要用 PowerShell `Get-Item ... .LinkType -eq 'Junction'` 或 .NET `DirectoryInfo.Attributes -band ReparsePoint` 判断。 |
| `cmd /c mklink /J` 被沙箱拦截 | 带审批钩子的 shell（Git Bash hooks 等）经常拦 `cmd /c`。用原生 cmdlet：`New-Item -ItemType Junction -Path <link> -Target <src>`。 |
| 删 junction 的安全姿势 | `[System.IO.Directory]::Delete($link, $false)` 只删 reparse point——遇到真实非空目录会直接抛异常，这反而使它成为安全原语。不带 `-Force` 的 `Remove-Item` 可能递归进目标。 |
| junction 在扫描器眼里 = 真目录 | `fast-glob`（`followSymlinks: true`）这类工具把 junction 当真实目录遍历。源码树里含 `SKILL.md` 的 `_backups/` 会被当成正式 skill 扫出来。**备份目录要放到被扫描的根之外。** |
| symlink vs junction | 目录 symlink 需要开发者模式或管理员；junction 都不要——但只能用于目录、跨不进 WSL。agent 在 WSL 里就改在 WSL 内跑 `.sh` 脚本。 |
| 相对路径陷阱 | junction 存的是绝对路径。audit 前先展开 `~` 并 `Resolve-Path` 再比对，否则会出现假 `DRIFTED`。 |

## FAQ

**这东西是独创的吗？** 机制本身是经典的 symlink farm（GNU Stow，1998）。本仓库贡献的是 *源即真相 + 精选清单 + Windows junction 优先* 在 AI agent skill 场景下的打包。想要市场/图形界面的话，现成的 [xingkongliang/skills-manager](https://github.com/xingkongliang/skills-manager)、[jiweiyeah/Skills-Manager](https://github.com/jiweiyeah/Skills-Manager) 可能更合适。

**为什么不直接复制 skill？** 副本会漂移——你在一个 agent 目录里改了 skill，其他份就旧了。链接不会漂移。

**能挂给哪些工具？** 凡是读 skills 目录的都行：`~/.claude/skills`、`~/.codex/skills`、`~/.workbuddy/skills`、Cursor 的项目规则目录等。加一行 `target` 即可。

## License

MIT
