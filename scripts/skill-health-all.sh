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

# --- fork drift: user-scope superpowers forks (writing-plans,
# subagent-driven-development) vs the current upstream plugin SKILL.md. A fork is
# intentionally divergent, so a fork-vs-upstream diff is noise; the useful signal
# is "did UPSTREAM advance since we last reconciled?" — hash the current upstream
# copy, compare to a stored baseline, alert when it changes. MONITOR-ONLY: porting
# upstream improvements into the fork is a manual judgment call (never auto-merge).
check_fork_drift() {
  local STATE_DIR="$HOME/.claude/skill-health"; mkdir -p "$STATE_DIR" 2>/dev/null || true
  local drift=() s fork up base cur
  for s in writing-plans subagent-driven-development; do
    fork="$HOME/.claude/skills/$s/SKILL.md"
    [ -f "$fork" ] || continue
    # current upstream copy: prefer the marketplace clone, else newest cached version
    up=$(find "$HOME/.claude/plugins/marketplaces" -path "*superpowers-extended-cc*/skills/$s/SKILL.md" 2>/dev/null | head -1)
    [ -n "$up" ] || up=$(find "$HOME/.claude/plugins/cache" -path "*superpowers-extended-cc*/skills/$s/SKILL.md" 2>/dev/null | sort -V | tail -1)
    [ -n "$up" ] && [ -f "$up" ] || continue
    cur=$(shasum "$up" 2>/dev/null | awk '{print $1}')
    base="$STATE_DIR/fork-upstream-$s.hash"
    if [ ! -f "$base" ]; then printf '%s\n' "$cur" > "$base"; continue; fi   # first run: set baseline, no alert
    if [ "$cur" != "$(cat "$base" 2>/dev/null)" ]; then
      drift+=("$s — upstream advanced; review & port into ~/.claude/skills/$s/  (upstream: $up)")
      printf '%s\n' "$cur" > "$base"
    fi
  done
  [ ${#drift[@]} -eq 0 ] && return 0
  echo "### FORK DRIFT — superpowers-extended-cc upstream changed since last review (port manually; never auto-merge)"
  printf '  - %s\n' "${drift[@]}"
  return 1
}

# --- claudeception fork drift: is the local CowboyPurest/Claudeception-cp fork
# behind its upstream (blader/Claudeception)? Fetches upstream (network-resilient:
# a failed fetch just reuses last-known refs, never false-alerts) and counts
# upstream-only commits. MONITOR-ONLY — porting is a manual judgment call.
check_claudeception_upstream() {
  local REPO="$HOME/Code/Claudeception-cp"
  [ -d "$REPO/.git" ] || return 0
  git -C "$REPO" remote get-url upstream >/dev/null 2>&1 || return 0
  git -C "$REPO" fetch upstream --quiet 2>/dev/null || true
  local ub behind
  ub=$(git -C "$REPO" rev-parse --verify --quiet upstream/main >/dev/null 2>&1 && echo upstream/main || echo upstream/master)
  behind=$(git -C "$REPO" rev-list --count "main..$ub" 2>/dev/null)
  [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null || return 0
  echo "### CLAUDECEPTION FORK BEHIND UPSTREAM (port manually; never auto-merge)"
  echo "  - Claudeception-cp main is $behind commit(s) behind blader/Claudeception ($ub); review: git -C $REPO log main..$ub --oneline"
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

# superpowers fork drift (upstream advanced since last review)
forkout=$(check_fork_drift); forkec=$?
if [ -n "$forkout" ]; then report+=("$forkout"); [ "$forkec" -ne 0 ] && anyhard=1; fi

# claudeception fork behind its blader/Claudeception upstream
clauout=$(check_claudeception_upstream); clauec=$?
if [ -n "$clauout" ]; then report+=("$clauout"); [ "$clauec" -ne 0 ] && anyhard=1; fi

if [ "${#report[@]}" -eq 0 ]; then
  echo "ALL CLEAN: $clean skill dirs + registry + forks, no issues."
  exit 0
fi

echo "$clean dir(s) clean; issues below:"
printf '%s\n' "${report[@]}"
[ "$anyhard" -ne 0 ] && exit 1 || exit 0
