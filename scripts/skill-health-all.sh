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

# --- agent-registry drift: BARE (non-namespaced) [skill] entries whose target
# skill dir no longer exists (e.g. renamed/folded by a consolidation). Plugin-
# namespaced entries (foo:bar) are skipped — a script can't verify the plugin
# universe, so flagging them would be a false positive. Echoes a section only
# when drift is found; returns 1 then, 0 otherwise.
check_registry_drift() {
  local REG="$HOME/.claude/skills/subagent-driven-development/agent-registry.md"
  [ -f "$REG" ] || return 0
  local known
  known=$( { ls "$HOME/.claude/skills" 2>/dev/null; ls "$HOME/.agents/skills" 2>/dev/null;
             while IFS= read -r r; do [ -d "$r" ] && ls "$r" 2>/dev/null; done \
               < <(find "$HOME/Code" -maxdepth 4 -type d -path '*/.claude/skills' ! -path '*/worktrees/*' 2>/dev/null);
           } | sort -u )
  local stale=() line id
  while IFS= read -r line; do
    case "$line" in *'[skill]'*) : ;; *) continue;; esac
    id=$(printf '%s' "$line" | sed -E 's/^- *([^ ]+).*/\1/')
    case "$id" in *:*) continue;; esac   # namespaced plugin skill — unverifiable, skip
    printf '%s\n' "$known" | grep -qxF "$id" || stale+=("$id")
  done < <(grep -E '^- ' "$REG")
  [ ${#stale[@]} -eq 0 ] && return 0
  echo "### REGISTRY DRIFT — agent-registry.md [skill] entries with no matching skill dir"
  printf '  - %s (stale: renamed/folded/removed — fix or drop the registry entry)\n' "${stale[@]}"
  return 1
}

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

# agent-registry drift (separate from the per-dir cluster checks)
regout=$(check_registry_drift); regec=$?
if [ -n "$regout" ]; then report+=("$regout"); [ "$regec" -ne 0 ] && anyhard=1; fi

if [ "${#report[@]}" -eq 0 ]; then
  echo "ALL CLEAN: $clean skill dirs + registry, no issues."
  exit 0
fi

echo "$clean dir(s) clean; issues below:"
printf '%s\n' "${report[@]}"
[ "$anyhard" -ne 0 ] && exit 1 || exit 0
