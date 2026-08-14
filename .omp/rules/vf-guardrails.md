---
name: vf-guardrails
description: vibe-flow pipeline guardrails — issue-file ownership, TDD commit discipline, report contract
alwaysApply: false
---

# vf-guardrails (vibe-flow)

Stream-level guardrails for pipeline agents. These are advisory (TTSR cannot
drive vf's state machine — vf owns transitions in the main workspace).

## Issue-file ownership

- NEVER edit `issues/*.md` in a worktree: that copy is invisible to the pipeline.
- State transitions are owned by `vf` in the main workspace.
- To append a note from anywhere: run `vf note <ID> -m "<text>"`.

## Commit discipline

- Commit subjects MUST be prefixed: `test(`, `fix(`, `review(`, `senior(`, `note(`.
- The failing test commit MUST precede the fix commit (`jj new` between them).
- NEVER set tags on unmerged work (tags immutabilize commits in jj).
- REVIEWERS (read-only stages): NEVER run `jj edit`, `jj new`, `jj workspace add/forget`,
  `jj bookmark`, `jj rebase`, `jj tag`, `jj abandon` — mutating the shared `fix-<ID>`
  commits abandons the worktree's commits and corrupts the branch.

## Report contract

- End reports with machine-readable fields on their own lines:
  `VERDICT:` / `REASON:` / `BLOCKERS:` / `CONFIDENCE:` / `PLAN:` / `RED:` / `GREEN:` / `CHANGE-ID:` / `CONFLICT:` / `TEST-FILES:`
