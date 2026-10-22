#!/bin/bash
# Remove builder/QA worktrees under .claude/worktrees whose work has landed.
#
# The Agent tool's worktree isolation only auto-removes a worktree that has
# no changes, and every builder commits, so finished worktrees pile up (and
# some are left locked, which makes `git worktree prune` a no-op on them).
# PRs are merged by the owner outside Claude's sessions, so nothing on the
# Claude side ever runs "after merge". This script is that step, run on
# demand.
#
# Usage: scripts/cleanup-worktrees.sh [--apply]
#   (no flag)  dry run: report what would be removed and what is kept, and why
#   --apply    unlock + remove the removable worktrees, delete their local
#              branches, delete their "BodegasNYC-<branch>" simulators,
#              delete worktree-agent-* scratch branches already on main, and
#              delete orphaned DerivedData folders (see below)
#
# A worktree is removable only when ALL of these hold:
#   * its branch has a MERGED or CLOSED PR on GitHub (per `gh pr list`), or
#     it is detached at a commit that is on origin/main or on a branch with
#     a merged/closed PR
#   * it has no uncommitted tracked changes and no untracked files other
#     than build/ output
# Anything with an open PR, no PR at all, or real uncommitted work is kept
# and listed. Remote branches are never deleted. Squash merges mean commit
# ancestry says nothing, which is why PR state is the source of truth.
#
# DerivedData: Xcode and MobileBuildMCP key their DerivedData folders by
# project path, so a build from a worktree leaves a folder under
# ~/Library/Developer/Xcode/DerivedData or
# ~/Library/Developer/MobileBuildMCP/workspaces/*/DerivedData that nothing
# removes when the worktree goes (run-tests.sh now builds into the in-tree
# build/dd, but MCP builds and raw xcodebuild still land there). A folder is
# swept only when its info.plist WorkspacePath is inside THIS repo (main
# checkout or a worktree of it) and that path no longer exists; other
# projects' folders are never touched.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
# The main checkout, even when run from a worktree: DerivedData paths are
# matched against this so one run covers every worktree of the repo.
MAIN_ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)

APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  *)
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac

if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is required and must be authenticated (gh auth login)" >&2
  exit 1
fi

git fetch -q origin
git worktree prune

# branch -> MERGED | CLOSED | OPEN, newest PR per branch wins.
PR_STATES=$(gh pr list --state all --limit 300 --json headRefName,state \
  -q '.[] | "\(.headRefName) \(.state)"' | awk '!seen[$1]++')

pr_state() {  # prints the PR state for a branch, or "NONE"
  local s
  s=$(printf '%s\n' "$PR_STATES" | awk -v b="$1" '$1 == b { print $2; exit }')
  echo "${s:-NONE}"
}

on_main() { git merge-base --is-ancestor "$1" origin/main 2>/dev/null; }

landed_branch_containing() {  # prints a merged/closed PR branch containing commit $1, if any
  local ref b
  while read -r ref; do
    [ -n "$ref" ] || continue
    b="${ref#origin/}"
    case "$(pr_state "$b")" in
      MERGED|CLOSED) echo "$b"; return 0 ;;
    esac
  done < <(git branch -a --contains "$1" --format='%(refname:short)' 2>/dev/null)
  return 1
}

real_dirt() {  # uncommitted changes in worktree $1, ignoring untracked build/ output
  git -C "$1" status --porcelain --untracked-files=all | grep -vE '^\?\? build/' || true
}

REMOVE=()   # "path|branch-or-empty"
KEEP=()

# Parse `git worktree list --porcelain`: blocks separated by blank lines.
path=""; head=""; branch=""
flush() {
  [ -n "$path" ] || return 0
  if [ "$path" = "$ROOT" ]; then path=""; head=""; branch=""; return 0; fi
  local why="" dirt state landed
  dirt=$(real_dirt "$path")
  if [ -n "$dirt" ]; then
    KEEP+=("$path|${branch:-detached}|has uncommitted changes")
  elif [ -n "$branch" ]; then
    state=$(pr_state "$branch")
    case "$state" in
      MERGED|CLOSED) REMOVE+=("$path|$branch|PR $state") ;;
      OPEN)          KEEP+=("$path|$branch|PR still open") ;;
      *)             if on_main "$head"; then REMOVE+=("$path|$branch|no PR, but tip is already on main")
                     else KEEP+=("$path|$branch|no PR for this branch"); fi ;;
    esac
  else
    if on_main "$head"; then
      REMOVE+=("$path||detached at a commit on main")
    elif landed=$(landed_branch_containing "$head"); then
      REMOVE+=("$path||detached on $landed, whose PR is $(pr_state "$landed")")
    else
      KEEP+=("$path|detached|detached at ${head:0:7}, not on main or any landed branch")
    fi
  fi
  path=""; head=""; branch=""
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*) path="${line#worktree }" ;;
    "HEAD "*)     head="${line#HEAD }" ;;
    "branch "*)   branch="${line#branch refs/heads/}" ;;
    "")           flush ;;
  esac
done < <(git worktree list --porcelain; echo)
flush

# Scratch branches the Agent tool creates for each worktree; safe once on main
# and no longer checked out anywhere (after the removals above).
SCRATCH=()
while read -r b; do
  [ -n "$b" ] || continue
  if on_main "$b"; then SCRATCH+=("$b"); fi
done < <(git branch --list 'worktree-agent-*' --format='%(refname:short)')

# DerivedData folders whose project path was inside this repo and is gone.
# Scanned once for the report, and again under --apply after the worktrees
# above are removed, so a worktree removed in this run is swept in this run.
DD_ORPHANS=()   # "path|workspace-path|size"
scan_dd_orphans() {
  local d wp
  DD_ORPHANS=()
  for d in "$HOME"/Library/Developer/Xcode/DerivedData/*/ \
           "$HOME"/Library/Developer/MobileBuildMCP/workspaces/*/DerivedData/*/; do
    [ -f "$d/info.plist" ] || continue
    wp=$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null) || continue
    case "$wp" in "$MAIN_ROOT"/*) ;; *) continue ;; esac
    [ -e "$wp" ] && continue
    DD_ORPHANS+=("${d%/}|$wp|$(du -sh "$d" 2>/dev/null | cut -f1)")
  done
}
scan_dd_orphans

echo "== removable worktrees (${#REMOVE[@]}) =="
for e in "${REMOVE[@]:-}"; do
  [ -n "$e" ] || continue
  IFS='|' read -r p b why <<<"$e"
  echo "  ${p#"$ROOT"/}  [${b:-detached}]  $why"
done
echo "== kept worktrees (${#KEEP[@]}) =="
for e in "${KEEP[@]:-}"; do
  [ -n "$e" ] || continue
  IFS='|' read -r p b why <<<"$e"
  echo "  ${p#"$ROOT"/}  [$b]  $why"
done
echo "== stale worktree-agent-* branches already on main (${#SCRATCH[@]}) =="
for b in "${SCRATCH[@]:-}"; do [ -n "$b" ] && echo "  $b"; done
echo "== orphaned DerivedData folders (${#DD_ORPHANS[@]}) =="
for e in "${DD_ORPHANS[@]:-}"; do
  [ -n "$e" ] || continue
  IFS='|' read -r p wp size <<<"$e"
  echo "  ${p/#$HOME/~}  ($size)  for ${wp#"$MAIN_ROOT"/}"
done

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "dry run; re-run with --apply to remove."
  exit 0
fi

echo
for e in "${REMOVE[@]:-}"; do
  [ -n "$e" ] || continue
  IFS='|' read -r p b why <<<"$e"
  git worktree unlock "$p" 2>/dev/null || true
  git worktree remove --force "$p"
  echo "removed ${p#"$ROOT"/}"
  if [ -n "$b" ] && [ "$b" != "main" ]; then
    git branch -D "$b" >/dev/null 2>&1 && echo "deleted branch $b" || true
    scripts/sim-for-branch.sh delete "$b" 2>/dev/null || true
  fi
done
git worktree prune

for b in "${SCRATCH[@]:-}"; do
  [ -n "$b" ] || continue
  # -D fails if the branch is still checked out somewhere; that's the guard.
  git branch -D "$b" >/dev/null 2>&1 && echo "deleted scratch branch $b" || echo "kept $b (still checked out)"
done

scan_dd_orphans   # picks up the DerivedData of worktrees removed just above
for e in "${DD_ORPHANS[@]:-}"; do
  [ -n "$e" ] || continue
  IFS='|' read -r p wp size <<<"$e"
  rm -rf "$p" && echo "deleted DerivedData ${p/#$HOME/~} ($size)"
done

echo
git worktree list
LEFT=$(xcrun simctl list devices 2>/dev/null | grep -o 'BodegasNYC-[^ ]*' | sort -u || true)
if [ -n "$LEFT" ]; then
  echo "remaining BodegasNYC-* simulators (delete with scripts/sim-for-branch.sh delete <branch>):"
  printf '  %s\n' $LEFT
fi
