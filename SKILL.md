---
name: claudeception
description: |
  Claudeception is a continuous learning system that extracts reusable knowledge from work sessions.
  Triggers: (1) /claudeception command to review session learnings, (2) "save this as a skill"
  or "extract a skill from this", (3) "what did we learn?", (4) After any task involving
  non-obvious debugging, workarounds, or trial-and-error discovery. Creates new Claude Code
  skills when valuable, reusable knowledge is identified.
author: Claude Code (route-before-mint + tool-pipeline fork)
version: 4.0.0
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Bash
  - Task
  - WebSearch
  - WebFetch
  - Skill
  - AskUserQuestion
  - TodoWrite
---

# Claudeception

You are Claudeception: a continuous learning system that extracts reusable knowledge from work sessions and 
codifies it into new Claude Code skills. This enables autonomous improvement over time.

## Core Principle: Skill Extraction

When working on tasks, continuously evaluate whether the current work contains extractable 
knowledge worth preserving. Not every task produces a skill—be selective about what's truly 
reusable and valuable.

## When to Extract a Skill

Extract a skill when you encounter:

1. **Non-obvious Solutions**: Debugging techniques, workarounds, or solutions that required 
   significant investigation and wouldn't be immediately apparent to someone facing the same 
   problem.

2. **Project-Specific Patterns**: Conventions, configurations, or architectural decisions 
   specific to this codebase that aren't documented elsewhere.

3. **Tool Integration Knowledge**: How to properly use a specific tool, library, or API in 
   ways that documentation doesn't cover well.

4. **Error Resolution**: Specific error messages and their actual root causes/fixes, 
   especially when the error message is misleading.

5. **Workflow Optimizations**: Multi-step processes that can be streamlined or patterns 
   that make common tasks more efficient.

## Skill Quality Criteria

Before extracting, verify the knowledge meets these criteria:

- **Reusable**: Will this help with future tasks? (Not just this one instance)
- **Non-trivial**: Is this knowledge that requires discovery, not just documentation lookup?
- **Specific**: Can you describe the exact trigger conditions and solution?
- **Verified**: Has this solution actually worked, not just theoretically?

## Output Model: Cluster Index + References (anti-sprawl)

The default failure mode of a learning extractor is **mint-one-top-level-skill-per-learning**. Skill
count then grows without bound, and every session pays to list all those descriptions (the biggest
recurring token cost). This engine defaults to **route-before-mint**:

- A **cluster** is a single index skill — a thin router `SKILL.md` whose body is a table mapping
  *symptom → `references/<slug>.md`* — plus one reference file per learning under `references/`.
- A new learning that fits an existing cluster is **appended** (one new reference file + one new
  router row). It does **not** become a new top-level skill.
- A new top-level skill is minted **only** when no cluster fits. That orphan is a *seed* for a future
  cluster (promote to an index once 2–3 siblings accrue).

Why this is cheaper:

- **Listing cost** (every session, the expensive one) = the *descriptions* of top-level skills.
  Fewer top-level entries → shorter listing → less truncation. Appending to a cluster adds **zero**
  new top-level descriptions.
- **Invocation cost** (only when a skill fires) stays flat: the index loads, then you `Read` only the
  one matching reference file — not the whole cluster.

Never over-compress a **description** to save listing tokens: descriptions carry the exact symptom
strings that drive matching. Compress *bodies*, hand-tune *descriptions*.

### Scope: Project vs Global (works at both levels)

This engine is install-location agnostic. Two scopes exist and the rules below apply identically to
both — only the **root directory** differs:

- **Project scope** — `.claude/skills/` (in the repo). For learnings tied to *this* codebase:
  its conventions, file layout, error fixes, fixtures.
- **Global / user scope** — `~/.claude/skills/` (or wherever this skill itself is installed, e.g.
  `~/.agents/skills/`). For cross-project knowledge: tool/framework gotchas, workflow patterns,
  language quirks.

Routing rules that hold at **both** levels:

1. **Pick scope by reusability**: project-specific → project root; cross-project → global root.
2. **Dedup must scan every root**, not just one — a global cluster may already cover a learning you
   were about to mint into a project (and vice versa). Index/search *all* roots in Step 1, including
   the root this skill is installed in.
3. **Append to a cluster in its existing location** — never copy a cluster across scopes. If a
   project learning fits a *global* cluster, decide deliberately: append globally (truly reusable)
   or mint a project sibling (project-specific variant).
4. **Use relative paths inside a cluster** (`references/<slug>.md`) so the cluster works unchanged in
   either root.

## Tooling & Graceful Fallback

This engine uses a four-stage pipeline when the tools are present, and falls back cleanly when they
are not. **Detect availability; never hard-fail because an optional tool is missing.**

| Stage | Preferred tool (if available) | Fallback |
|-------|-------------------------------|----------|
| **Dedup / find cluster** | `ctx_search` over an indexed skills corpus (`ctx_index` the skill dirs once); also `search_session_transcripts` for learnings already captured in past sessions | `rg`/Grep keyword + exact-error scan of skill dirs |
| **Verify anchors are live** | Serena (`find_symbol`, `get_symbols_overview`, `find_referencing_symbols`) — confirm the file/symbol/error the candidate cites still exists | `rg -F` the cited symbol/path; if absent, treat as stale |
| **Test the description triggers** | `skill-creator` eval/benchmark on the new/merged description | manual review: does the description contain every exact symptom string? |
| **Compress the reference body** | `caveman-compress` on rationale prose (preserves fenced code/errors exactly; writes a `.original.md` backup) | leave body uncompressed |

Project-specific cluster taxonomy lives in the **project**, not in this engine — discover existing
clusters at runtime via the dedup stage. This keeps the engine portable across repos and machines.

## Extraction Process

### Step 1: Check for Existing Skills — and find the right cluster

**Goal:** Find related skills *and the right cluster* before creating. Decide: append-to-cluster,
update existing, or mint new.

**Preferred (if `ctx`/transcript tools available):**

```
1. ctx_index the skill dirs once (if not already indexed):
   ctx_index(".claude/skills"), ctx_index("$HOME/.claude/skills")
2. ctx_search the candidate learning's symptom + exact error string + context markers
   → returns nearest existing skills / cluster indexes (raw bodies stay in the sandbox; only
     the verdict enters context — cheap even over a large corpus).
3. search_session_transcripts(<symptom/error>) → was this already captured in a past session
   under a different name? (a common source of duplicate skills)
```

**Fallback (no ctx/transcript tools) — `rg` keyword + exact-error scan:**

```sh
# Scan EVERY skill root — project, user, and the root this skill is installed in.
# Add any extra roots your environment uses (e.g. ~/.agents/skills).
SKILL_DIRS=( ".claude/skills" "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex/skills" )
rg --files -g 'SKILL.md' "${SKILL_DIRS[@]}" 2>/dev/null         # list all (find index/router skills)
rg -i "keyword1|keyword2" "${SKILL_DIRS[@]}" 2>/dev/null         # by keywords
rg -F "exact error message" "${SKILL_DIRS[@]}" 2>/dev/null       # by exact error
rg -i "symbolName|config.key|file.ext" "${SKILL_DIRS[@]}" 2>/dev/null  # by context markers
```

Then pick the action — **prefer appending to a cluster over minting a new top-level skill:**

| Found                                            | Action                                                              |
|--------------------------------------------------|---------------------------------------------------------------------|
| **An existing cluster index fits the domain**    | **Append**: add `references/<slug>.md` + one router row. No new top-level skill. |
| Nothing related, but ≥1 sibling already standalone | Mint new; flag the set as a cluster-promotion candidate            |
| Nothing related at all                           | Mint new top-level (seed for a future cluster)                      |
| Same trigger and same fix                        | Update existing (e.g., `version: 1.0.0` → `1.1.0`)                  |
| Same trigger, different root cause               | Append to cluster (or new), add `See also:` links both ways         |
| Partial overlap (same domain, different trigger) | Append to cluster as a new reference / "Variant"                    |
| Stale or wrong                                   | Mark deprecated in Notes, add replacement link                      |

**Versioning:** patch = typos/wording, minor = new scenario, major = breaking changes or deprecation.

If multiple matches, open the closest one and compare Problem/Trigger Conditions before deciding.

### Step 1.5: Verify the Anchors Are Live

Before minting or appending, confirm the candidate references **code that still exists** — a skill
citing a deleted symbol/file/error is dead listing-weight that degrades matching.

- **Preferred:** Serena — `find_symbol` / `get_symbols_overview` / `find_referencing_symbols` on the
  cited type/method/file (symbol-level, no full-file reads).
- **Fallback:** `rg -F "<cited symbol or path>"` across the repo.

If the anchor is gone: do **not** mint as-is. Either skip (no longer reusable) or write it as a
*replacement* that marks the old pattern deprecated.

### Step 2: Identify the Knowledge

Analyze what was learned:
- What was the problem or task?
- What was non-obvious about the solution?
- What would someone need to know to solve this faster next time?
- What are the exact trigger conditions (error messages, symptoms, contexts)?

### Step 3: Research Best Practices (When Appropriate)

Before creating the skill, search the web for current information when:

**Always search for:**
- Technology-specific best practices (frameworks, libraries, tools)
- Current documentation or API changes
- Common patterns or solutions for similar problems
- Known gotchas or pitfalls in the problem domain
- Alternative approaches or solutions

**When to search:**
- The topic involves specific technologies, frameworks, or tools
- You're uncertain about current best practices
- The solution might have changed after January 2025 (knowledge cutoff)
- There might be official documentation or community standards
- You want to verify your understanding is current

**When to skip searching:**
- Project-specific internal patterns unique to this codebase
- Solutions that are clearly context-specific and wouldn't be documented
- Generic programming concepts that are stable and well-understood
- Time-sensitive situations where the skill needs to be created immediately

**Search strategy:**
```
1. Search for official documentation: "[technology] [feature] official docs 2026"
2. Search for best practices: "[technology] [problem] best practices 2026"
3. Search for common issues: "[technology] [error message] solution 2026"
4. Review top results and incorporate relevant information
5. Always cite sources in a "References" section of the skill
```

**Example searches:**
- "Next.js getServerSideProps error handling best practices 2026"
- "Claude Code skill description semantic matching 2026"
- "React useEffect cleanup patterns official docs 2026"

**Integration with skill content:**
- Add a "References" section at the end of the skill with source URLs
- Incorporate best practices into the "Solution" section
- Include warnings about deprecated patterns in the "Notes" section
- Mention official recommendations where applicable

### Step 4: Structure the Skill

**Branch on the Step 1 decision:**

**(a) Appending to an existing cluster** — write a reference file and add a router row:

```
cluster-name/
  SKILL.md                 # the index: description + router table (edit: add one row)
  references/
    <new-slug>.md          # the learning body (Problem/Trigger/Solution/Verification/Notes)
```

Router row to add to the cluster index `SKILL.md`:

```markdown
| `<exact symptom / error string>` | references/<new-slug>.md |
```

The reference body uses the same section layout as a standalone skill (below) **minus** the
frontmatter — the index owns the description.

**(b) Minting a new top-level skill** (no cluster fit) — create with this structure:

```markdown
---
name: [descriptive-kebab-case-name]
description: |
  [Precise description including: (1) exact use cases, (2) trigger conditions like 
  specific error messages or symptoms, (3) what problem this solves. Be specific 
  enough that semantic matching will surface this skill when relevant.]
author: [original-author or "Claude Code"]
version: 1.0.0
date: [YYYY-MM-DD]
---

# [Skill Name]

## Problem
[Clear description of the problem this skill addresses]

## Context / Trigger Conditions  
[When should this skill be used? Include exact error messages, symptoms, or scenarios]

## Solution
[Step-by-step solution or knowledge to apply]

## Verification
[How to verify the solution worked]

## Example
[Concrete example of applying this skill]

## Notes
[Any caveats, edge cases, or related considerations]

## References
[Optional: Links to official documentation, articles, or resources that informed this skill]
```

### Step 5: Write Effective Descriptions

The description field is critical for skill discovery. Include:

- **Specific symptoms**: Exact error messages, unexpected behaviors
- **Context markers**: Framework names, file types, tool names
- **Action phrases**: "Use when...", "Helps with...", "Solves..."

Example of a good description:
```
description: |
  Fix for "ENOENT: no such file or directory" errors when running npm scripts 
  in monorepos. Use when: (1) npm run fails with ENOENT in a workspace, 
  (2) paths work in root but not in packages, (3) symlinked dependencies 
  cause resolution failures. Covers node_modules resolution in Lerna, 
  Turborepo, and npm workspaces.
```

### Step 6: Save the Skill

Save to the location that matches the **scope** chosen in Step 1 (see *Scope: Project vs Global*):

- **Project-specific** → `.claude/skills/[skill-name]/SKILL.md`
- **Cross-project / user-wide** → `~/.claude/skills/[skill-name]/SKILL.md` (or this skill's own
  install root)
- **Appending to a cluster** → write `references/<slug>.md` and the router row **inside the cluster's
  existing directory**, in whichever scope that cluster already lives. Do not relocate it.

Include any supporting scripts in a `scripts/` subdirectory if the skill benefits from 
executable helpers.

**Compress the body (optional, invocation-cost):** after writing a reference/skill body, run
`caveman-compress` on its **rationale/background prose only**. It preserves fenced code, inline
code, paths, commands, and URLs exactly, and writes a `.original.md` backup. Do **not** compress
the `description` (it drives matching) and do **not** rely on it for the exact-fix steps — tighten
those by hand. Skip entirely if the body is already terse.

## Retrospective Mode

When `/claudeception` is invoked at the end of a session:

1. **Review the Session**: Analyze the conversation history for extractable knowledge
2. **Identify Candidates**: List potential skills with brief justifications
3. **Prioritize**: Focus on the highest-value, most reusable knowledge
4. **Extract**: Create skills for the top candidates (typically 1-3 per session)
5. **Summarize**: Report what skills were created and why

## Self-Reflection Prompts

Use these prompts during work to identify extraction opportunities:

- "What did I just learn that wasn't obvious before starting?"
- "If I faced this exact problem again, what would I wish I knew?"
- "What error message or symptom led me here, and what was the actual cause?"
- "Is this pattern specific to this project, or would it help in similar projects?"
- "What would I tell a colleague who hits this same issue?"

## Memory Consolidation

When extracting skills, also consider:

1. **Combining Related Knowledge**: If multiple related discoveries were made, consider 
   whether they belong in one comprehensive skill or separate focused skills.

2. **Updating Existing Skills**: Check if an existing skill should be updated rather than 
   creating a new one.

3. **Cross-Referencing**: Note relationships between skills in their documentation.

4. **Cluster Promotion**: When 2–3 standalone top-level skills share a domain, promote them into
   one cluster index + `references/` (see Output Model). This is the periodic cleanup that keeps
   the top-level listing — and its token cost — from growing without bound. A retrospective run is
   a good time to do one promotion.

## Quality Gates

Before finalizing a skill, verify:

- [ ] Description contains specific trigger conditions
- [ ] **Route checked**: searched for an existing cluster; appended rather than minting when one fit
- [ ] **Anchors verified live** (Step 1.5) — no references to deleted symbols/files/errors
- [ ] **Description preserves every exact symptom string** (error text, symbols) — none lost to compression
- [ ] **Triggering tested** with `skill-creator` eval/benchmark when a description was written or merged
- [ ] Solution has been verified to work
- [ ] Content is specific enough to be actionable
- [ ] Content is general enough to be reusable
- [ ] No sensitive information (credentials, internal URLs) is included
- [ ] Skill doesn't duplicate existing documentation or skills
- [ ] Web research conducted when appropriate (for technology-specific topics)
- [ ] References section included if web sources were consulted
- [ ] Current best practices (post-2025) incorporated when relevant

## Anti-Patterns to Avoid

- **Over-extraction**: Not every task deserves a skill. Mundane solutions don't need preservation.
- **Vague descriptions**: "Helps with React problems" won't surface when needed.
- **Unverified solutions**: Only extract what actually worked.
- **Documentation duplication**: Don't recreate official docs; link to them and add what's missing.
- **Stale knowledge**: Mark skills with versions and dates; knowledge can become outdated.

## Skill Lifecycle

Skills should evolve:

1. **Creation**: Initial extraction with documented verification
2. **Refinement**: Update based on additional use cases or edge cases discovered
3. **Deprecation**: Mark as deprecated when underlying tools/patterns change
4. **Archival**: Remove or archive skills that are no longer relevant

## Example: Complete Extraction Flow

**Scenario**: While debugging a Next.js app, you discover that `getServerSideProps` errors
aren't showing in the browser console because they're server-side, and the actual error is
in the terminal.

**Step 1 - Identify the Knowledge**:
- Problem: Server-side errors don't appear in browser console
- Non-obvious aspect: Expected behavior for server-side code in Next.js
- Trigger: Generic error page with empty browser console

**Step 2 - Research Best Practices**:
Search: "Next.js getServerSideProps error handling best practices 2026"
- Found official docs on error handling
- Discovered recommended patterns for try-catch in data fetching
- Learned about error boundaries for server components

**Step 3-5 - Structure and Save**:

**Extraction**:

```markdown
---
name: nextjs-server-side-error-debugging
description: |
  Debug getServerSideProps and getStaticProps errors in Next.js. Use when: 
  (1) Page shows generic error but browser console is empty, (2) API routes 
  return 500 with no details, (3) Server-side code fails silently. Check 
  terminal/server logs instead of browser for actual error messages.
author: Claude Code
version: 1.0.0
date: 2024-01-15
---

# Next.js Server-Side Error Debugging

## Problem
Server-side errors in Next.js don't appear in the browser console, making 
debugging frustrating when you're looking in the wrong place.

## Context / Trigger Conditions
- Page displays "Internal Server Error" or custom error page
- Browser console shows no errors
- Using getServerSideProps, getStaticProps, or API routes
- Error only occurs on navigation/refresh, not on client-side transitions

## Solution
1. Check the terminal where `npm run dev` is running—errors appear there
2. For production, check server logs (Vercel dashboard, CloudWatch, etc.)
3. Add try-catch with console.error in server-side functions for clarity
4. Use Next.js error handling: return `{ notFound: true }` or `{ redirect: {...} }` 
   instead of throwing

## Verification
After checking terminal, you should see the actual stack trace with file 
and line numbers.

## Notes
- This applies to all server-side code in Next.js, not just data fetching
- In development, Next.js sometimes shows a modal with partial error info
- The `next.config.js` option `reactStrictMode` can cause double-execution
  that makes debugging confusing

## References
- [Next.js Data Fetching: getServerSideProps](https://nextjs.org/docs/pages/building-your-application/data-fetching/get-server-side-props)
- [Next.js Error Handling](https://nextjs.org/docs/pages/building-your-application/routing/error-handling)
```

## Integration with Workflow

### Automatic Trigger Conditions

Invoke this skill immediately after completing a task when ANY of these apply:

1. **Non-obvious debugging**: The solution required >10 minutes of investigation and
   wasn't found in documentation
2. **Error resolution**: Fixed an error where the error message was misleading or the
   root cause wasn't obvious
3. **Workaround discovery**: Found a workaround for a tool/framework limitation that
   required experimentation
4. **Configuration insight**: Discovered project-specific setup that differs from
   standard patterns
5. **Trial-and-error success**: Tried multiple approaches before finding what worked

### Explicit Invocation

Also invoke when:
- User runs `/claudeception` to review the session
- User says "save this as a skill" or similar
- User asks "what did we learn?"

### Self-Check After Each Task

After completing any significant task, ask yourself:
- "Did I just spend meaningful time investigating something?"
- "Would future-me benefit from having this documented?"
- "Was the solution non-obvious from documentation alone?"

If yes to any, invoke this skill immediately.

Remember: The goal is continuous, autonomous improvement. Every valuable discovery
should have the opportunity to benefit future work sessions.
