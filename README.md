# restack

A small, stateless CLI for maintaining a chain of dependent GitHub PRs (a "stack")
in a **squash-merge** workflow. It does the fiddly rebase bookkeeping — propagating
changes up the stack, and rebasing onto trunk after the bottom PR merges — without
asking you to install a platform, log in, or maintain a metadata file. Just stand on
any branch in the stack and it auto-detects the whole chain from your PR base branches.

```
restack show     # preview the detected stack + PR states
restack sync     # trunk moved or you edited a lower branch — propagate it up
restack land     # the bottom PR got squash-merged — rebase the rest onto trunk
```

## Why this exists

A stack is an ordered list of branches, bottom → top, on a trunk (usually `main`).
Each branch's PR targets the branch below it; the bottom targets trunk. Keeping that
chain healthy by hand is error-prone: squash-merging collapses N commits into one new
commit, which breaks the original commit chain, so a plain `git rebase` (even with
`--update-refs`) can silently duplicate or drop commits.

restack captures every branch's original parent tip *before* mutating anything and
rebases each branch with `--onto`, which is what makes it correct even in the awkward
case where a base branch has commits its children haven't absorbed yet.

## What makes it different

Compared to Graphite, git-town, and git-machete:

- **Stateless.** There is no `.git/machete`-style definition file to create or keep in
  sync. The stack is re-derived on every run from your live PR base branches (each PR's
  base *is* the layer below it). Nothing to initialize, nothing to clean up.
- **Fits the default GitHub flow.** `land` works with squash-merge + auto-delete-branch
  + auto-retarget already turned on — it rediscovers the merged base even after its
  branch is gone. You don't merge *through* restack; you merge in the GitHub UI as usual.
- **Zero install weight.** Just local `git` + the `gh` CLI (both GA). No daemon, no
  account, no server-side feature.
- **Worktree-aware and fail-safe.** It rebases onto `origin/<trunk>` (never checks trunk
  out, so trunk can live in another worktree), refuses to clobber a branch a teammate has
  pushed to, and pushes with `--force-with-lease --force-if-includes --atomic`.

It is **not** a Graphite replacement — it has no stack-creation or navigation commands
and handles linear stacks only (it refuses forks/trees). It's the lightweight option for
people hand-rebasing stacks who don't want to adopt a heavier tool. It's also designed to
be a clean swap for GitHub's forthcoming native `gh stack` once that goes GA.

## Requirements

- **bash 4+.** macOS ships bash 3.2, so `brew install bash` and make sure it's ahead of
  `/bin/bash` on your `PATH` (the script resolves bash via `PATH`).
- **`gh` CLI**, authenticated against your repo.

## Install

### Quick install (drop-in skill)

MacOS ships with an old version of bash,
```sh
brew install bash        # macOS only — skip if you already have bash 4+
```

```sh
mkdir -p ~/.claude/skills/restack && \
for f in restack.sh SKILL.md _restack; do \
  curl -fsSL "https://raw.githubusercontent.com/kyrrelm/restack/main/$f" \
    -o ~/.claude/skills/restack/"$f"; \
done && chmod +x ~/.claude/skills/restack/restack.sh
```

That's everything Claude Code needs — it discovers the skill from `SKILL.md`
and drives `restack.sh` by its in-skill path. No symlink or shell setup
required for the agent to use it.

### Optional: use `restack` in your own terminal

The drop-in above is enough for Claude. If you also want to run `restack`
yourself from the shell (with tab-completion), symlink it onto your `PATH`:

```sh
mkdir -p ~/.local/bin ~/.zsh/completions
ln -sf ~/.claude/skills/restack/restack.sh ~/.local/bin/restack
ln -sf ~/.claude/skills/restack/_restack   ~/.zsh/completions/_restack
chmod +x ~/.claude/skills/restack/restack.sh
```

Then in `~/.zshrc`:

```sh
export PATH="$HOME/.local/bin:$PATH"
fpath=("$HOME/.zsh/completions" $fpath)
autoload -Uz compinit && compinit
```

The snippet above is for **bare zsh**. If you use a framework (oh-my-zsh,
prezto, etc.), it runs its own `compinit`, so add **only** the `fpath=(...)`
line and put it **above** where the framework is sourced — drop the
`autoload`/`compinit` line. (oh-my-zsh builds completions at source time, so
appending `fpath` at the bottom of `~/.zshrc` is too late.)

Reload your shell (`exec zsh`) and run `restack help` to confirm it's on your
`PATH`. If the tab-completion doesn't show up, a stale completion cache is the
usual culprit: `rm -f ~/.zcompdump && compinit`.

## Usage

Stand on any branch in the stack (not trunk) with a clean working tree.

| Command | When |
|---------|------|
| `restack show` | Read-only. Print the detected stack, each branch's commits ahead/behind its parent, and PR state. **Run this first** to confirm what restack found. |
| `restack sync` | Nothing merged yet; trunk moved or you added/amended commits on a lower branch. Rebases each branch onto its updated parent bottom → top, then force-pushes the whole stack. |
| `restack land` | The bottom PR was squash-merged. Finds the merged base, rebases the rest onto trunk dropping the squashed commits, force-pushes, retargets the new bottom PR, and deletes the leftover branch. |
| `restack continue` | Resume after resolving a rebase conflict (`git add` your fixes first). Use this, **not** `git rebase --continue`, so the multi-branch walk and final push complete. |
| `restack abort` | Abort an in-progress restack. |

### When a rebase conflicts

restack stops and names the conflicted branch. Don't run `git rebase --continue` directly
(it finishes only one sub-rebase and loses the stack walk). Instead:

1. Resolve the conflict markers.
2. `git add <files>`
3. `restack continue`

`rerere` is enabled, so a resolution you make once replays automatically if the same
conflict recurs higher up the stack.

### If the merged branch is gone everywhere

`land` normally rediscovers the squash-merged base on its own. If its local *and*
remote-tracking refs are both gone, pass the old base tip explicitly:

```sh
restack land --from $(gh pr view <merged-pr#> --json headRefOid -q .headRefOid)
```

## Notes

- **Forks** (a branch that's the base of two PRs): there's no single line, so restack
  refuses when you stand on the split point. Check out the child branch for the line you
  want and run from there. Each line is restacked independently.
- Override the remote with `RESTACK_REMOTE=upstream restack sync`, or the trunk with
  `RESTACK_TRUNK=<branch>`.
- This is a personal tool, not hardened to the level of Graphite or gh-stack. Always
  `restack show` before trusting a push.

See `DESIGN_NOTES.md` for the reasoning behind the non-obvious choices (PR-base detection
vs. commit ancestry, the per-branch `--onto` walk, the squash-merge cut), and `SKILL.md`
for the agent-facing instructions.
