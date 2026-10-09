#!/usr/bin/env bash
# skill-stow - mount curated AI agent skill folders via symlinks (macOS/Linux).
# Source-as-truth: sources are NEVER modified. Unmount only removes symlinks
# whose target matches the manifest source.
#
# Compatible with bash 3.2+ (stock macOS bash). No external deps beyond coreutils.
#
# Usage:
#   skill-stow.sh audit
#   skill-stow.sh mount   [-all | -target t -name s] [-dry-run]
#   skill-stow.sh unmount [-all | -target t -name s] [-dry-run]
#   skill-stow.sh doctor
#   skill-stow.sh list
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${STOWFILE:-$SCRIPT_DIR/Stowfile}"

expand_home() {
  case "$1" in
    "~") echo "$HOME" ;;
    "~"/*) echo "$HOME/${1#~/}" ;;
    *) echo "$1" ;;
  esac
}

die() { echo "ERROR: $*" >&2; exit 2; }

# --- manifest state (parallel indexed arrays, bash 3.2 safe) ------------------
TARGET_NAMES=(); TARGET_PATHS=()
SOURCE_NAMES=(); SOURCE_PATHS=()
MOUNT_T=(); MOUNT_S=(); MOUNT_SKILL=()

lookup() { # lookup <names-array-name> <paths-array-name> <key>  -> echoes value
  local _n _k="$3" i
  eval "local _cnt=\${#$1[@]}"
  for ((i = 0; i < _cnt; i++)); do
    eval "_n=\${$1[$i]}"
    if [ "$_n" = "$_k" ]; then eval "echo \"\${$2[$i]}\""; return 0; fi
  done
  return 1
}

parse_manifest() {
  [ -f "$MANIFEST" ] || die "Manifest not found: $MANIFEST (set STOWFILE or place a Stowfile next to the script)"
  local lineno=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))
    local line="${raw%%#*}"
    # shellcheck disable=SC2206
    local tok=($line)
    [ ${#tok[@]} -eq 0 ] && continue
    local directive
    directive="$(printf '%s' "${tok[0]}" | tr '[:upper:]' '[:lower:]')"
    case "$directive" in
      target)
        [ ${#tok[@]} -ge 3 ] || die "Stowfile line $lineno: 'target <name> <path>' expected"
        TARGET_NAMES+=("${tok[1]}")
        TARGET_PATHS+=("$(expand_home "${tok[2]}")") ;;
      source)
        [ ${#tok[@]} -ge 3 ] || die "Stowfile line $lineno: 'source <name> <path>' expected"
        SOURCE_NAMES+=("${tok[1]}")
        SOURCE_PATHS+=("$(expand_home "${tok[2]}")") ;;
      mount)
        [ ${#tok[@]} -ge 4 ] || die "Stowfile line $lineno: 'mount <target> <source> <skill>...' expected"
        local i
        for ((i = 3; i < ${#tok[@]}; i++)); do
          MOUNT_T+=("${tok[1]}"); MOUNT_S+=("${tok[2]}"); MOUNT_SKILL+=("${tok[$i]}")
        done ;;
      *) die "Stowfile line $lineno: unknown directive '${tok[0]}'" ;;
    esac
  done < "$MANIFEST"
  # resolve references
  local i
  for ((i = 0; i < ${#MOUNT_T[@]}; i++)); do
    lookup TARGET_NAMES TARGET_PATHS "${MOUNT_T[$i]}" >/dev/null \
      || die "mount line: unknown target '${MOUNT_T[$i]}'"
    lookup SOURCE_NAMES SOURCE_PATHS "${MOUNT_S[$i]}" >/dev/null \
      || die "mount line: unknown source '${MOUNT_S[$i]}'"
  done
}

target_path_of() { lookup TARGET_NAMES TARGET_PATHS "$1"; }
source_path_of() { lookup SOURCE_NAMES SOURCE_PATHS "$1"; }

select_mounts() {
  SELECT_T=(); SELECT_S=(); SELECT_SKILL=()
  local any_filter=0
  [ -n "${FILTER_TARGET:-}" ] && any_filter=1
  [ -n "${FILTER_NAME:-}" ] && any_filter=1
  [ "${ALL:-0}" -eq 1 ] && any_filter=1
  [ $any_filter -eq 1 ] || die "Refusing to act on everything implicitly. Pass -all, or filter with -target / -name."
  local i
  for ((i = 0; i < ${#MOUNT_T[@]}; i++)); do
    [ -n "${FILTER_TARGET:-}" ] && [ "${MOUNT_T[$i]}" != "$FILTER_TARGET" ] && continue
    [ -n "${FILTER_NAME:-}" ] && [ "${MOUNT_SKILL[$i]}" != "$FILTER_NAME" ] && continue
    SELECT_T+=("${MOUNT_T[$i]}"); SELECT_S+=("${MOUNT_S[$i]}"); SELECT_SKILL+=("${MOUNT_SKILL[$i]}")
  done
}

cmd_audit() {
  local issues=0 i t s skill link src
  for ((i = 0; i < ${#MOUNT_T[@]}; i++)); do
    t="${MOUNT_T[$i]}"; s="${MOUNT_S[$i]}"; skill="${MOUNT_SKILL[$i]}"
    link="$(target_path_of "$t")/$skill"; src="$(source_path_of "$s")/$skill"
    if [ ! -e "$src" ]; then
      printf "%-10s %s/%s  (source missing: %s)\n" "SRC-MISS" "$t" "$skill" "$src"; issues=$((issues+1)); continue
    fi
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
      printf "%-10s %s/%s\n" "MISSING" "$t" "$skill"; issues=$((issues+1)); continue
    fi
    if [ -L "$link" ]; then
      if [ "$(readlink "$link")" = "$src" ]; then
        printf "%-10s %s/%s\n" "OK" "$t" "$skill"
      else
        printf "%-10s %s/%s  -> %s\n" "DRIFTED" "$t" "$skill" "$(readlink "$link")"; issues=$((issues+1))
      fi
    else
      printf "%-10s %s/%s  (real directory occupies the link path)\n" "COLLISION" "$t" "$skill"; issues=$((issues+1))
    fi
  done
  # extras: symlinks on disk that the manifest does not know about
  local ti p item known=0 j
  for ((ti = 0; ti < ${#TARGET_NAMES[@]}; ti++)); do
    p="${TARGET_PATHS[$ti]}"
    [ -d "$p" ] || continue
    for item in "$p"/*; do
      [ -L "$item" ] || continue
      known=0
      for ((j = 0; j < ${#MOUNT_T[@]}; j++)); do
        [ "${MOUNT_T[$j]}" = "${TARGET_NAMES[$ti]}" ] && [ "$item" = "$p/${MOUNT_SKILL[$j]}" ] && known=1
      done
      [ $known -eq 1 ] && continue
      printf "%-10s %s/%s  (symlink -> %s)\n" "EXTRA" "${TARGET_NAMES[$ti]}" "$(basename "$item")" "$(readlink "$item")"
      issues=$((issues+1))
    done
  done
  if [ $issues -eq 0 ]; then echo "All clean."; else echo; echo "$issues issue(s) found."; exit 1; fi
}

cmd_mount() {
  select_mounts
  local created=0 skipped=0 failed=0 i t s skill link src
  for ((i = 0; i < ${#SELECT_T[@]}; i++)); do
    t="${SELECT_T[$i]}"; s="${SELECT_S[$i]}"; skill="${SELECT_SKILL[$i]}"
    link="$(target_path_of "$t")/$skill"; src="$(source_path_of "$s")/$skill"
    if [ ! -e "$src" ]; then echo "[SKIP]      source missing: $src"; failed=$((failed+1)); continue; fi
    if [ -L "$link" ]; then
      if [ "$(readlink "$link")" = "$src" ]; then skipped=$((skipped+1)); continue; fi
      echo "[DRIFTED]   $link -> $(readlink "$link"); unmount first."; failed=$((failed+1)); continue
    fi
    if [ -e "$link" ]; then
      echo "[COLLISION] real directory in the way, refusing: $link"; failed=$((failed+1)); continue
    fi
    if [ "${DRYRUN:-0}" -eq 1 ]; then
      echo "[DRYRUN] would create symlink: $link -> $src"; created=$((created+1))
    else
      if ln -s "$src" "$link"; then
        echo "[MOUNTED]   $link -> $src"; created=$((created+1))
      else
        echo "[FAILED]    $link"; failed=$((failed+1))
      fi
    fi
  done
  echo; echo "created: $created  already-ok: $skipped  failed: $failed"
  [ $failed -gt 0 ] && exit 1
  exit 0
}

cmd_unmount() {
  select_mounts
  local removed=0 refused=0 i t s skill link src
  for ((i = 0; i < ${#SELECT_T[@]}; i++)); do
    t="${SELECT_T[$i]}"; s="${SELECT_S[$i]}"; skill="${SELECT_SKILL[$i]}"
    link="$(target_path_of "$t")/$skill"; src="$(source_path_of "$s")/$skill"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then echo "[ABSENT]    $link"; continue; fi
    if [ ! -L "$link" ]; then
      echo "[REFUSED]   $link is a real directory; skill-stow never deletes real directories."
      refused=$((refused+1)); continue
    fi
    if [ "$(readlink "$link")" != "$src" ]; then
      echo "[REFUSED]   $link points to '$(readlink "$link")', not the manifest source; not touching it."
      refused=$((refused+1)); continue
    fi
    if [ "${DRYRUN:-0}" -eq 1 ]; then
      echo "[DRYRUN] would remove symlink: $link"
    else
      rm "$link" && { echo "[REMOVED]   $link"; removed=$((removed+1)); }
    fi
  done
  echo; echo "removed: $removed  refused: $refused"
  [ $refused -gt 0 ] && exit 1
  exit 0
}

cmd_doctor() {
  local bad=0 i p item
  for ((i = 0; i < ${#TARGET_NAMES[@]}; i++)); do
    [ -d "${TARGET_PATHS[$i]}" ] || { echo "[WARN] target '${TARGET_NAMES[$i]}' does not exist: ${TARGET_PATHS[$i]}"; bad=$((bad+1)); }
  done
  for ((i = 0; i < ${#SOURCE_NAMES[@]}; i++)); do
    [ -d "${SOURCE_PATHS[$i]}" ] || { echo "[ERR] source '${SOURCE_NAMES[$i]}' does not exist: ${SOURCE_PATHS[$i]}"; bad=$((bad+1)); }
  done
  for ((i = 0; i < ${#TARGET_NAMES[@]}; i++)); do
    p="${TARGET_PATHS[$i]}"
    [ -d "$p" ] || continue
    for item in "$p"/*; do
      [ -L "$item" ] || continue
      [ -e "$item" ] || { echo "[BROKEN]   $item -> $(readlink "$item")"; bad=$((bad+1)); }
    done
  done
  if [ $bad -eq 0 ]; then echo "No problems found."; else echo; echo "$bad problem(s)."; exit 1; fi
}

cmd_list() {
  local i t s skill link status
  for ((i = 0; i < ${#MOUNT_T[@]}; i++)); do
    t="${MOUNT_T[$i]}"; s="${MOUNT_S[$i]}"; skill="${MOUNT_SKILL[$i]}"
    link="$(target_path_of "$t")/$skill"; status="MISSING"
    [ -L "$link" ] && status="SYMLINK"
    [ ! -L "$link" ] && [ -e "$link" ] && status="COLLISION"
    printf "%-12s %-12s %-30s [%s]\n" "$t" "$s" "$skill" "$status"
  done
  echo; echo "targets: ${#TARGET_NAMES[@]}   sources: ${#SOURCE_NAMES[@]}   mounts: ${#MOUNT_SKILL[@]}"
}

usage() {
  cat <<'EOF'
skill-stow - symlink-based skill mounting, source-as-truth.

Usage:
  skill-stow.sh audit
  skill-stow.sh mount   [-all | -target t -name s] [-dry-run]
  skill-stow.sh unmount [-all | -target t -name s] [-dry-run]
  skill-stow.sh doctor
  skill-stow.sh list

Env:
  STOWFILE   manifest path (default: Stowfile next to this script)
EOF
}

# ----------------------------------------------------------------------- main
COMMAND="${1:-help}"; [ $# -gt 0 ] && shift
FILTER_TARGET=""; FILTER_NAME=""; ALL=0; DRYRUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    -target) FILTER_TARGET="$2"; shift 2 ;;
    -name)   FILTER_NAME="$2"; shift 2 ;;
    -all)    ALL=1; shift ;;
    -dry-run|--dry-run) DRYRUN=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

parse_manifest
case "$COMMAND" in
  audit)   cmd_audit ;;
  mount)   cmd_mount ;;
  unmount) cmd_unmount ;;
  doctor)  cmd_doctor ;;
  list)    cmd_list ;;
  help|*)  usage ;;
esac
