#!/usr/bin/env bash
# skill-health-all.sh — token-frugal aggregator for scheduled health checks.
#
# Runs skill-health.sh (with --fix) across the global skill roots + every project
# .claude/skills discovered under ~/Code, and emits ONE compact summary:
#   - all healthy  -> a single line ("ALL CLEAN: N skill dirs, no issues.")
#   - any issue    -> only the dirs that have something, with their detail lines
# This keeps the calling agent's context tiny: one command, one short output.
#
# Exit: 0 = no HARD issues (clean or warnings-only) · 1 = HARD issues somewhere.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SH="$HERE/skill-health.sh"
[ -f "$SH" ] || { echo "skill-health-all: missing $SH" >&2; exit 2; }

ROOTS=( "$HOME/.claude/skills" "$HOME/.agents/skills" )
while IFS= read -r p; do
  [ -n "$p" ] && ROOTS+=( "$p" )
done < <(find "$HOME/Code" -maxdepth 4 -type d -path '*/.claude/skills' ! -path '*/worktrees/*' 2>/dev/null)

clean=0
report=()
anyhard=0

for d in "${ROOTS[@]}"; do
  [ -d "$d" ] || continue
  out=$(bash "$SH" "$d" --fix 2>&1); ec=$?
  if [ "$ec" -eq 0 ] && ! printf '%s' "$out" | grep -qE 'WARNINGS|AUTO-FIXED'; then
    clean=$((clean+1))
    continue
  fi
  [ "$ec" -ne 0 ] && anyhard=1
  report+=("### $d")
  report+=("$(printf '%s\n' "$out" | grep -E 'AUTO-FIXED|WARNINGS|HARD ISSUES|^  - ')")
done

if [ "${#report[@]}" -eq 0 ]; then
  echo "ALL CLEAN: $clean skill dirs, no issues."
  exit 0
fi

echo "$clean dir(s) clean; issues below:"
printf '%s\n' "${report[@]}"
[ "$anyhard" -ne 0 ] && exit 1 || exit 0
