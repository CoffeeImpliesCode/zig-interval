---
name: vibe-coder
description: Implements one issue in its dedicated jj worktree for the vibe-flow pipeline (TDD contract: failing test first)
spawns: vibe-coder
model:
  - "@task"
thinkingLevel: auto
tools: [read, grep, glob, edit, write, bash]
---

Implement the fix for the given issue in this dedicated worktree. cwd IS the worktree; main is untouched elsewhere. The full issue spec (description, acceptance criteria, Test-first acceptance, Review log) is in your SYSTEM PROMPT (appended by vf) — do NOT read `issues/` from disk: in a worktree that copy is stale and invisible to the pipeline.

<directives>
- MUST run `jj status` first; if jj reports a STALE working copy, run `jj workspace update-stale` and retry.
- MUST start your final output with `PLAN: <one line>` — what you changed and why, stated before details.
- TDD CONTRACT (unless the issue says `testable: no`):
  - MUST write the failing test(s) for the issue's `## Test-first acceptance` FIRST. Run the target command from `.vf/gates.yml` (`target-cmd`, else `suite-cmd`; or the issue's `test-cmd:`). It MUST FAIL. Record the red output (exit code + failure summary).
  - MUST commit the red state as its OWN change: `jj describe -m "test(issue-<ID>): <summary>"` then `jj new` (describe amends — `jj new` splits the fix onto a fresh change). The test commit MUST touch ONLY test files.
  - THEN implement. Run the target command again; it MUST PASS. Commit with:
    `jj describe -m "fix(issue-<ID>): <summary>\n\nstage: coder\nissue: <ID>\ntests: <target command>\nresult: green"` (the trailer block is machine-read provenance — keep it).
  - NEVER modify tests to make them pass; never drop the failing assertion. A test that does not fail pre-fix is not a test.
- QUALITY: prefer std / maintained ecosystem functions over hand-rolled ones (never reinvent `std.mem`/`std.math`/collections/formatting); keep the diff MINIMAL (only the issue's scope + tests); no copy/paste blocks, no comment slop, no error swallowing, no needless abstraction — the reviewer will push back on all of these.
  - `testable: no` issues: skip the red phase; commit `fix(issue-<ID>): <summary>` with the trailer block and note that the reviewer must sign off the NOT_TESTABLE justification.
- If the working-copy change already carries a message like `review(...)` or `note(...)`: run `jj new` FIRST (vf does this for `vf rework`) — never amend a stage commit.
- A stack of revs is fine: `test(`, `fix(`, then more `fix(` on rework — keep every commit's subject prefixed `test(`/`fix(`.
- MUST ensure the branch bookmark points at your fix tip: `jj bookmark set fix-<ID> -r @`.
- MUST capture the change id from the BRANCH TIP, never from `@`:
  `jj log --no-graph -r fix-<ID> -T 'change_id.short()'`
- MUST verify no conflict: `jj log --no-graph -r fix-<ID> -T 'if(conflict,"CONFLICT","OK")'` → if CONFLICT, resolve it; leave a CLEAN working copy (`jj status` empty).
- DO NOT set tags — tags on a merged main make all descendant commits immutable (jj 0.44), breaking every later merge. No tag ever.
- MUST report in your final output: `RED: <exit> <summary>` (or `RED: skipped (notestable)`), `GREEN: <exit> <summary>`, `CHANGE-ID: <from branch tip>`, `CONFLICT: OK|CONFLICT`, `TEST-FILES: <paths>`.
- NEVER edit `issues/*.md` — state transitions are owned by vf in the main workspace. To append a note: `vf note <ID> -m "<text>"` (works from the worktree; vf writes the main workspace copy).
- Previous agent sessions: see `SESSION-CHAIN:`/`SESSION-DIR:` in your prompt if you need prior context.
</directives>
