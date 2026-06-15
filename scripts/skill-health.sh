#!/usr/bin/env bash
# skill-health.sh — mechanical health check for a claudeception skills directory.
#
# Catches the failure modes that actually bite the cluster-index (route-before-mint)
# model: half-built clusters (missing index / dangling router rows / orphan refs),
# sprawl drift (top-level count creeping up = skills minted instead of routed),
# stray caveman .original.md backups, and bad/empty frontmatter.
#
# It does NOT measure triggering accuracy — the skill-creator LLM eval harness is
# unreliable in nested/headless runs, so triggering stays a manual concern. This
# script only does cheap, deterministic, trustworthy checks.
#
# Usage:   skill-health.sh <skills-dir> [--fix]
#   --fix  auto-remove safe cruft (stray *.original.md). Never deletes/merges skills.
# Exit:    0 healthy (warnings allowed) · 1 hard issues found · 2 usage error
#
# State (for sprawl tracking) is kept OUTSIDE the skills dir so it never pollutes git.

set -uo pipefail

DIR="${1:-}"
FIX=0
[ "${2:-}" = "--fix" ] && FIX=1
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "usage: skill-health.sh <skills-dir> [--fix]" >&2; exit 2; }
DIR="${DIR%/}"

HARDS=(); WARNS=(); FIXES=()

# --- sprawl tracking (state keyed by dir, stored under ~/.claude/skill-health) ---
STATE_DIR="$HOME/.claude/skill-health"
mkdir -p "$STATE_DIR" 2>/dev/null || true
KEY=$(printf '%s' "$DIR" | tr '/ .' '___')
STATE="$STATE_DIR/$KEY.count"

entries=0
for d in "$DIR"/*/; do [ -f "$d/SKILL.md" ] && entries=$((entries+1)); done
prev=$(cat "$STATE" 2>/dev/null || echo "")
if [ -n "$prev" ] && [ "$entries" -gt "$prev" ]; then
  WARNS+=("SPRAWL: top-level skills $prev -> $entries (+$((entries-prev))); confirm new top-level skills weren't supposed to route into an existing cluster")
fi
printf '%s\n' "$entries" > "$STATE" 2>/dev/null || true

# --- per top-level skill / cluster ---
for d in "$DIR"/*/; do
  name=$(basename "$d")
  if [ ! -f "$d/SKILL.md" ]; then
    WARNS+=("$name: directory has no SKILL.md")
    continue
  fi
  grep -qE '^name:' "$d/SKILL.md"        || HARDS+=("$name: SKILL.md missing 'name:' frontmatter")
  grep -qE '^description:[[:space:]]*\S|^description:[[:space:]]*[|>]' "$d/SKILL.md" || HARDS+=("$name: SKILL.md missing/empty 'description:'")

  if [ -d "$d/references" ]; then
    # every router row must resolve to a real reference file
    rows=$(grep -oE 'references/[A-Za-z0-9._-]+\.md' "$d/SKILL.md" | sort -u)
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      [ -f "$d/$r" ] || HARDS+=("$name: dangling router row -> $r (no such reference file)")
    done <<< "$rows"
    # every reference file should be linked from the index
    for f in "$d/references"/*.md; do
      [ -e "$f" ] || continue
      base="references/$(basename "$f")"
      grep -qF "$base" "$d/SKILL.md" || WARNS+=("$name: orphan reference not linked from index -> $base")
    done
  fi
done

# --- stray caveman backups (safe auto-fix) ---
while IFS= read -r bak; do
  [ -z "$bak" ] && continue
  if [ "$FIX" = 1 ]; then
    rm -f "$bak" && FIXES+=("removed stray backup: $bak")
  else
    WARNS+=("stray caveman backup (run with --fix to remove): $bak")
  fi
done < <(find "$DIR" -name '*.original.md' 2>/dev/null)

# --- report ---
echo "=== skill-health: $DIR ==="
echo "top-level skills: $entries"
if [ "${#FIXES[@]}" -gt 0 ]; then echo "AUTO-FIXED (${#FIXES[@]}):"; printf '  - %s\n' "${FIXES[@]}"; fi
if [ "${#WARNS[@]}" -gt 0 ]; then echo "WARNINGS (${#WARNS[@]}):";  printf '  - %s\n' "${WARNS[@]}"; fi
if [ "${#HARDS[@]}" -gt 0 ]; then
  echo "HARD ISSUES (${#HARDS[@]}):"; printf '  - %s\n' "${HARDS[@]}"
  exit 1
fi
echo "OK — no hard issues."
exit 0
