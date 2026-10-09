#!/usr/bin/env python3
"""adopt.py - scan an agent's skills folder and emit a Stowfile.

Group junctions/symlinks by their source directory, so an existing
zero-copy setup can be captured into a manifest in one shot.

Usage:
    python adopt.py <agent-skills-dir> [output-stowfile]

Example:
    python adopt.py ~/.workbuddy/skills Stowfile

Requires Python 3.8+. On Windows, junctions are read via os.readlink.
"""
import os
import sys


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    ws = os.path.expanduser(sys.argv[1])
    out = os.path.expanduser(sys.argv[2]) if len(sys.argv) > 2 else None
    if not os.path.isdir(ws):
        sys.exit(f"not a directory: {ws}")

    target_name = os.path.basename(ws.rstrip("/\\")) or "agent"
    roots: dict[str, list[str]] = {}
    dangling: list[str] = []

    for name in sorted(os.listdir(ws)):
        full = os.path.join(ws, name)
        try:
            target = os.readlink(full)
        except OSError:
            continue  # real directory or regular file
        target = target.replace("\\\\?\\", "").replace("\\??\\", "")
        if not os.path.exists(target):
            dangling.append(f"{name} -> {target}")
        roots.setdefault(os.path.dirname(target), []).append(name)

    def group_name(src_dir: str) -> str:
        rel = src_dir.replace(os.path.expanduser("~"), "~").replace("\\", "/")
        return rel

    lines = [
        f"# skill-stow manifest - adopted from {ws}",
        "",
        f"target {target_name}  {ws.replace(os.path.expanduser('~'), '~').replace(os.sep, '/')}",
        "",
    ]
    root_names = {}
    for src_dir in sorted(roots):
        rel = group_name(src_dir)
        name = rel.strip("/").replace("/", "-").replace("~", "").strip("-") or "src"
        root_names[src_dir] = name
        lines.append(f"source {name}  {rel}")
    lines.append("")
    for src_dir in sorted(roots):
        lines.append(
            f"mount {target_name} {root_names[src_dir]}  {' '.join(sorted(roots[src_dir]))}"
        )

    text = "\n".join(lines) + "\n"
    if out:
        with open(out, "w", newline="\n") as f:
            f.write(text)
        print(f"wrote {out}")
    else:
        print(text, end="")

    total = sum(len(v) for v in roots.values())
    print(f"# mounts: {total}", file=sys.stderr)
    for d in dangling:
        print(f"# DANGLING (target missing, kept in manifest): {d}", file=sys.stderr)


if __name__ == "__main__":
    main()
