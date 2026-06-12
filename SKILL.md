---
name: restack
description: >-
  Maintain and inspect manually-stacked GitHub PRs in a squash-merge workflow.
  Use whenever the user has — or might have — a chain of dependent branches/PRs
  (a "stack") and wants to (1) inspect its state: confirm they're in a stack, see
  the layers/trunk/PR states or how far branches have drifted ("am I in a stack",
  "what's my stack look like", "show/check my stack", "is this branch stacked");
  (2) propagate changes up after the trunk moved or a lower branch gained commits
  ("rebase my stack", "propagate my base changes up", "update the stacked PRs",
  "my stack is out of date"); or (3) rebase the rest onto trunk after the bottom
  PR was squash-merged ("I merged the base PR", "land my stack"). The read-only
  `restack show` auto-detects the stack from PR base branches, so prefer it over
  hand-running git/gh even just to answer "are we in a stack?". Works on any repo
  today — needs only local git + the `gh` CLI, not GitHub's private-preview
  Stacked PRs feature.
---

# restack — manual stacked-PR maintenance

A stack is an ordered list of branches, bottom → top, sitting on a trunk
(usually `main`). Each branch's PR targets the branch below it; the bottom
targets trunk. Squash-merging breaks the original commit chain, so the rule is
**always rebase, never merge**, and drop the squashed commits with `--onto`.

The `restack.sh` script (next to this file) does the bookkeeping. Always prefer
it over hand-running git, because it captures every branch's original parent tip
*before* mutating anything — which is what lets it propagate appended
base-branch commits without creating duplicates, the one case a naive
`git rebase --update-refs` gets wrong.

**Invoke it as `~/.claude/skills/restack/restack.sh <command>`** — the script in
this skill's own directory (substitute the actual base dir if the skill is
installed elsewhere). Wherever this doc writes `restack <cmd>` for brevity, run
it via that path, unless the user has put `restack` on their `PATH`. Do not
assume a global `restack` exists; the drop-in install creates no symlink.

## No setup needed — the stack is auto-detected

Stand on any branch in the stack and the script reconstructs the whole chain
from your **PR base branches** (each PR's base is the layer below it). This is
exact: it correctly includes a base branch that has new commits its children
haven't absorbed yet (scenario 1) — something pure commit-ancestry can't tell
apart from an unrelated sibling — and it ignores branches that aren't in the PR
chain. New layers you add later are picked up automatically as long as the PR's
base is set correctly. Trunk is the base of the bottom PR.

If `gh` is unavailable or the current branch has no PR yet, it falls back to
commit-ancestry detection (which warns, since it can miss an ahead-of-children
base). Either way, run `restack show` first to confirm what it found.

There are **no setup commands and no state files** — nothing to initialize,
nothing to clean up when a stack is done. Do not look for or create a config.

### Forks (the only case detection can't auto-resolve)

If a branch is the base of two PRs, there's no single line, so detection refuses
when you're standing *on* that split branch. The fix is simply to **check out
the branch for the line you want** (a child above the split) and run the command
from there — detection then follows that one line and ignores the sibling. Do
**not** try to pin or configure anything; just tell the user to check out the
line they mean. Each line of a fork is restacked independently by standing on it.

When a base *below* the current branch also feeds an off-line sibling, the script
prints a note (not an error): restacking rewrites that shared base, so the other
line(s) must be restacked separately or their PRs go stale. Surface this note to
the user.

If you ever see a warning that a stray `.git/stack` file exists, tell the user —
it's an inert leftover (pinning was removed) and is being ignored; they can
delete it.

## Choosing the command

- **Nothing merged yet; trunk moved, or the user added commits to a lower
  branch** → `restack sync`. Rebases each branch onto its (updated) parent,
  propagating changes up, then force-pushes the whole stack.
- **The bottom PR was merged** → `restack land`. Works with the standard GitHub
  flow: squash-merge via the PR UI with auto-delete-branch on, which deletes the
  merged branch and auto-retargets the dependent PR to trunk. `land` finds the
  squash-merged base — even though it's gone from the PR chain — by locating the
  local branch that's contained in the stack bottom, isn't in trunk, and whose
  PR is `MERGED`. It then rebases the stack onto trunk with `--onto` (dropping
  the squashed commits), force-pushes, retargets, and deletes the leftover local
  branch. If that local branch is also gone, the user passes the old base tip:
  `restack land --from <sha>` (e.g.
  `restack land --from $(gh pr view <num> --json headRefOid -q .headRefOid)`).
  It also still handles the case where the merged branch is *still* in the chain
  (auto-delete off). If nothing looks merged, it refuses and suggests `sync`.

Run `restack show` first to display the detected stack and PR states so the
user can confirm. Position doesn't matter beyond needing to be on *some* branch
in the stack (not trunk) so detection has an anchor.

`restack show` also flags a **pending land**: after you squash-merge a lower PR,
GitHub folds it into trunk and retargets the dependent PR, but your local branch
still sits on the old un-squashed commits — so its ahead-count is inflated and
the line otherwise looks like a healthy single branch. `show` detects this (the
same way `land` does) and prints a `⚠ land pending` banner naming the merged base
and the true post-land count, e.g. `(+25 → +18)`. When you see it, run
`restack land`.

## When a rebase conflicts

The script stops and prints the conflicted branch. Do **not** run
`git rebase --continue` directly — that finishes only one sub-rebase and loses
the stack walk. Instead:

1. Resolve the conflict markers in the listed files.
2. `git add <files>`
3. `restack continue` — resumes the remaining branches, then pushes.

`restack abort` rolls back the in-progress rebase. (Branches already advanced in
an earlier step aren't rewound; re-running `restack sync` is idempotent and
finishes the job, or use `git reflog` to inspect.)

## Guardrails

These are checked up front (after fetching), so the tool refuses cleanly before
touching anything rather than failing partway through:

- Dirty working tree → refuses; commit or stash first.
- Trunk diverged from its remote → refuses; reconcile trunk first.
- A stack branch is **behind its remote** (a teammate, another machine, or
  another worktree pushed to it) → refuses and tells the user to integrate it
  first (e.g. `git checkout <b> && git pull --rebase`). It will not overwrite
  their work. Surface this clearly; the user must reconcile before re-running.
- A **stack branch** is checked out in another worktree → refuses, naming the
  worktree (the rebase rewrites each branch, which git forbids while it's
  claimed elsewhere). Trunk being in another worktree is fine — restack rebases
  onto the remote-tracking trunk (`origin/<trunk>`) and never checks trunk out.
- Pushes are `--force-with-lease --force-if-includes --atomic` — a stale view or
  partial push fails safe rather than clobbering a teammate, as a backstop to
  the pre-flight checks above.

Requires **bash 4+**. macOS ships bash 3.2, so the user may need
`brew install bash` (the script's shebang resolves bash via PATH).

## Notes

- This is intentionally compatible with GitHub's forthcoming `gh stack`: both
  drive the same local git operations, so adopting `gh stack` later is a clean
  swap. The only thing `gh stack` adds that this can't is the server-side Stack
  object that visually links PRs, which is in private preview.
- Override the remote with `RESTACK_REMOTE=upstream restack sync`.
