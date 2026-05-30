restack — design notes
A small CLI that maintains a stack of dependent GitHub PRs in a squash-merge
workflow. Files: restack.sh (the tool), _restack (zsh completion),
SKILL.md (agent instructions). Install: symlink restack.sh onto PATH and
_restack onto $fpath; lives in ~/.claude/skills/restack/.
Model

A stack = a linear chain of branches bottom→top on a trunk; each PR targets
the branch below it, the bottom targets trunk.
Stateless. No metadata files. The stack is re-derived every run from the
live PR graph (each PR's base branch = the layer below it), anchored on the
branch you're standing on. New layers are picked up automatically.
Commands: show/sync/land/continue/abort/help.

Why the non-obvious choices

PR-base detection, not commit ancestry. Once you add commits to a base
branch, its tip stops being an ancestor of its children, so ancestry can't
tell "parent with new commits" from "unrelated sibling." PR bases encode the
parent links unambiguously. (Ancestry is a fallback only when gh is absent.)
Per-branch --onto <captured-old-parent-tip> walk, not a single
rebase --update-refs. Capturing each branch's original parent tip up front
is what lets appended base commits propagate without duplicates even when
trunk also moved. --update-refs silently misses that case.
Rebase onto origin/<trunk>, never check trunk out. So trunk can live in
another worktree (common setup). Local trunk is only best-effort fast-
forwarded when it isn't owned by a worktree.
bash 4+ required (uses mapfile, associative arrays). macOS ships 3.2 →
brew install bash. Empty-array expansions use ${arr[@]+"${arr[@]}"} so
set -u is safe on older 4.x too.
rerere enabled so conflict resolutions replay up the stack.
Pushes: --force-with-lease --force-if-includes --atomic (fail-safe).

Commands

sync — trunk moved, or you edited a lower branch. Rebases the stack onto
origin/trunk bottom→top (bottom cut at merge-base(bottom, origin/trunk),
higher branches cut at their parent's original tip), then force-pushes.
land — after the bottom PR is merged. Handles the standard GitHub flow
(squash-merge + auto-delete branch + dependent PR auto-retargeted to trunk):
the merged base is gone from the PR chain, so it's rediscovered as a ref
(local or remote-tracking) that is contained in the stack bottom, not in
trunk, and whose PR is MERGED. Then rebases the stack onto trunk with --onto
dropping the squashed commits, force-pushes, retargets, deletes the leftover
branch. Also still handles the merged-branch-still-in-chain case (auto-delete
off). Escape hatch: restack land --from <old-base-tip-sha>.

Squash-merge is the hard case
A regular merge keeps the base commits' identities, so plain git rebase drops
them via patch-id detection. A squash collapses N commits into 1 new commit, so
that link is gone — land must be told the cut (where the merged segment
ends in your branch). The cut = merge-base(merged-base, bottom), recovered from
the local or origin/ ref, or supplied via --from (the old base tip). merge-base
with TRUNK is the wrong end (it's the fork-from-trunk point, not the base tip).

Why merge-base(base, bottom), not the base tip. In the clean case the bottom
sits directly on the base's tip, so the two coincide. But if the base branch
advanced past the point the bottom forked from it — you appended a commit to the
base and merged it without first sync-ing the child — the base tip is no longer
even an ancestor of the bottom. The bottom's own work begins at the fork point,
so that's the cut; the un-absorbed base commits live in trunk's squash and
arrive when the bottom rebases onto trunk. An earlier version gated discovery
(and --from) on "base tip is-ancestor-of bottom" and so found nothing in this
case — the common real-world failure that motivated this. A candidate whose
fork point is already in trunk is skipped (plain-merged or already landed).
Detection edge cases

Fork (a branch is the base of two PRs): no single line. land/sync
refuse; check out the child branch for the line you want and run from there.
MERGED check after branch deletion: use gh pr list --head <branch> --state merged (works post-delete), NOT gh pr view <branch>.
Independent merges landing on trunk before/after your squash are fine — they
just become part of the trunk you rebase onto. Only real concern is conflicts,
handled by the normal resolve → git add → restack continue loop.

Guardrails (all checked up front, after fetch)

Dirty tree → refuse. Stack branch behind its remote → refuse (don't clobber a
teammate). Stack branch claimed by another worktree → refuse. Nothing actually
merged on land → refuse, suggest sync.

Known limitations

Linear stacks only (refuses forks/trees).
Depends on gh + bash 4 + GitHub's auto-retarget behavior.
Discovery leans on gh reporting the merge; --from is the deterministic
fallback. After land, sanity-check restack show before trusting the push.
Personal tool; not hardened like Graphite/gh-stack. When gh stack (GitHub
native, in private preview) goes GA, it's likely the better long-term answer.
