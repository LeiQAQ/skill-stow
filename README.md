# skill-stow

**One source of truth for your AI agent skills. Mount curated skill folders into any number of AI coding tools via Windows junctions / Unix symlinks — zero copies, zero dependencies, one plain-text manifest.**

[中文说明](./README.zh-CN.md)

```
~/.codex/skills/stickman-topic        ← the real skill lives here (single source)
~/.workbuddy/skills/stickman-topic    ← junction → the same folder
~/.claude/skills/stickman-topic       ← junction → the same folder
```

## Why

AI coding agents (Claude Code, Codex, WorkBuddy/CodeBuddy, Cursor, Gemini CLI, ...) each read skills from their own folder. Existing GUI managers solve this with a **central library**: skills get copied into the manager's hub first, then distributed. That means duplicates, a second source of truth, and a metadata database to keep in sync.

**skill-stow flips the model.** Your skill keeps its original home. Agent folders hold nothing but links. A curated manifest decides *which* skills appear *where*. Unmounting removes a link and never touches the source.

| | GUI skill managers | **skill-stow** |
|---|---|---|
| Model | central library, then copy/symlink out | **source-as-truth, link in** |
| Copies of a skill | 1 copy in hub + link/copy per agent | **0 copies** |
| Config | app database | **plain-text `Stowfile`** (git-friendly) |
| Dependencies | Tauri/React/Rust app | **none** — PowerShell or bash |
| Curation | per-agent toggles in UI | **manifest lines you can review in a PR** |
| Windows | symlink, fallback junction | **junction first** (no admin, no Developer Mode) |

## Install

No install. Copy `skill-stow.ps1` (Windows) or `skill-stow.sh` (macOS/Linux) somewhere, put a `Stowfile` next to it.

Already mounting skills by hand? Capture the current state into a manifest:

```bash
python3 adopt.py ~/.workbuddy/skills Stowfile   # scans links, groups by source, emits a Stowfile
```

## The Stowfile

```text
# skill-stow manifest — plain text, '#' starts a comment

target workbuddy   ~/.workbuddy/skills
target claude      ~/.claude/skills

source main        ~/.codex/skills
source superpowers ~/.codex/superpowers/skills

# mount <target> <source> <skill> [skill ...]
mount workbuddy main        stickman-topic stickman-script-draft
mount workbuddy superpowers brainstorming verifying
```

- `source` — where skills really live.
- `target` — an agent's skills folder (must exist; the agent itself doesn't need to be running).
- `mount` — one line per curation decision; a line can carry many skills.
- Keep your real `Stowfile` out of git (it's machine-specific) and commit a `Stowfile.example` instead — same pattern as `.env`.

## Commands

```powershell
# Windows (PowerShell)
.\skill-stow.ps1 audit              # compare manifest vs disk, report every mismatch
.\skill-stow.ps1 mount -All         # create every missing junction
.\skill-stow.ps1 mount -Target workbuddy -Name brainstorming
.\skill-stow.ps1 unmount -All -DryRun
.\skill-stow.ps1 doctor             # broken links, collisions, extras
.\skill-stow.ps1 list               # mounts + status
```

```bash
# macOS / Linux (real symlinks)
./skill-stow.sh audit
./skill-stow.sh mount -all
./skill-stow.sh unmount -target workbuddy -name brainstorming
```

Statuses reported by `audit` / `doctor`:

| Status | Meaning |
|---|---|
| `OK` | link exists, points at the manifest source |
| `MISSING` | manifest wants it, disk doesn't have it |
| `DRIFTED` | link exists but points somewhere else |
| `COLLISION` | a real directory occupies the link path — **never auto-removed** |
| `EXTRA` | link on disk that the manifest doesn't know about |
| `BROKEN` | link exists but its source folder is gone |

## Safety rules (enforced in code, not just docs)

1. **Sources are never written to.** The scripts only create/remove links inside target folders.
2. **`unmount` removes a link only if** (a) it is a reparse point (`LinkType -eq 'Junction'` / `-L` on Unix), **and** (b) its target matches the manifest source. Real directories are always refused.
3. `--dry-run` on every mutating command.
4. Junctions are preferred on Windows: they need **no administrator rights and no Developer Mode**, unlike directory symlinks.

## Windows junction trap table

Everything below was hit in real use and is handled (or documented) by the scripts:

| Trap | Detail |
|---|---|
| `os.path.islink()` lies | Python returns `False` for junctions. Detect with PowerShell `Get-Item ... .LinkType -eq 'Junction'` or .NET `DirectoryInfo.Attributes -band ReparsePoint`. |
| `cmd /c mklink /J` gets blocked | Sandboxed shells (Git Bash hooks, approval wrappers) often intercept `cmd /c`. Use the native cmdlet: `New-Item -ItemType Junction -Path <link> -Target <src>`. |
| Deleting a junction the safe way | `[System.IO.Directory]::Delete($link, $false)` removes the reparse point only — and throws on a real non-empty directory, which makes it a safe primitive. `Remove-Item` without `-Force` can recurse into the target. |
| Junction = real dir for scanners | Tools like `fast-glob` (`followSymlinks: true`) treat junctions as real directories. Backup folders containing a `SKILL.md` **inside your source tree** will be picked up as skills. Keep `_backups/` outside scanned roots. |
| Symlink vs junction | Directory symlink needs Developer Mode or elevation; junction needs neither — but junctions are directories-only and can't cross to WSL. For agents inside WSL, run the `.sh` script inside WSL instead. |
| Relative target confusion | Junctions store absolute paths. When auditing, expand `~` and `Resolve-Path` before comparing, or you'll get phantom `DRIFTED` results. |

## FAQ

**Is this original?** The mechanism is a classic symlink farm (GNU Stow, 1998). The *source-as-truth + curated manifest + junction-first-on-Windows* packaging for AI agent skills is what this repo adds. GUI managers already exist — see [xingkongliang/skills-manager](https://github.com/xingkongliang/skills-manager), [jiweiyeah/Skills-Manager](https://github.com/jiweiyeah/Skills-Manager) — and may fit you better if you want a marketplace UI.

**Why not just copy skills?** Copies drift. The moment you edit a skill in one agent's folder, the others are stale. Links can't drift.

**Which agents can I target?** Any tool that reads a skills folder: `~/.claude/skills`, `~/.codex/skills`, `~/.workbuddy/skills`, Cursor project rules dirs, etc. Add it as a `target` line.

## License

MIT
