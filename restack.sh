#!/usr/bin/env bash
#
# restack — manual stacked-PR maintenance for a squash-merge workflow.
#
# The stack (an ordered chain of branches bottom -> top on a trunk) is
# auto-detected from your PR base branches each run. No setup, no state files.
#
#   restack show                          print stack, PR state, ahead/behind
#   restack sync                          SCENARIO 1: propagate trunk/base changes up the stack
#   restack land                          SCENARIO 2: after squash-merging the bottom PR
#   restack continue                      resume after resolving a rebase conflict
#   restack abort                         abort an in-progress restack
#
# Everything here is plain local git + `gh pr` (both GA). It needs no GitHub
# server-side "stacked PRs" feature, so it works today and stays compatible
# with `gh stack` later.
set -euo pipefail

# This script uses associative arrays and `mapfile` (bash 4+). macOS ships
# bash 3.2 at /bin/bash, so install a modern one (brew install bash) and ensure
# it's on PATH ahead of /bin/bash. The shebang resolves bash via PATH.
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "restack: needs bash 4+ (you have ${BASH_VERSION:-unknown}). On macOS: brew install bash" >&2
  exit 1
fi

GITDIR="$(git rev-parse --git-dir 2>/dev/null || true)"
STACK_FILE="$GITDIR/stack"
META_FILE="$GITDIR/stack-op"
STEPS_FILE="$GITDIR/stack-op.steps"
REMOTE="${RESTACK_REMOTE:-origin}"

die()  { echo "restack: $*" >&2; exit 1; }
info() { echo "  $*" >&2; }

require_repo() { [ -n "$GITDIR" ] || die "not a git repository."; }

require_clean() {
  [ -z "$(git status --porcelain --untracked-files=no)" ] \
    || die "working tree has uncommitted changes; commit or stash first."
}

default_trunk() {
  [ -n "${RESTACK_TRUNK:-}" ] && { echo "$RESTACK_TRUNK"; return; }
  [ -f "$GITDIR/stack-trunk" ] && { cat "$GITDIR/stack-trunk"; return; }
  local r
  if r="$(git symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null)"; then
    echo "${r#"$REMOTE"/}"; return
  fi
  local c
  for c in main master trunk; do
    git show-ref -q --verify "refs/heads/$c" && { echo "$c"; return; }
  done
  die "cannot determine trunk; set RESTACK_TRUNK=<branch>."
}

gh_base()     { gh pr view "$1" --json baseRefName -q .baseRefName 2>/dev/null; }
gh_has_pr()   { gh pr view "$1" --json number      -q .number      >/dev/null 2>&1; }
gh_children() { gh pr list --base "$1" --json headRefName -q '.[].headRefName' 2>/dev/null; }

# Primary detection: reconstruct the stack from PR base branches. Each PR's
# base IS the layer below it, so this is exact — it handles a base branch that
# has unmerged commits ahead of its children (scenario 1), which pure commit
# ancestry cannot, and it ignores unrelated/sibling branches automatically.
detect_via_prs() {
  local head="$1" cur base i child kids down=() up=() siblings=()
  cur="$head"
  for ((i=0; i<64; i++)); do
    base="$(gh_base "$cur")"
    [ -n "$base" ] || { TRUNK="$(default_trunk)"; break; }
    if gh_has_pr "$base"; then
      # Does this base feed other branches besides the one we came from?
      local k
      while read -r k; do [ -n "$k" ] && [ "$k" != "$cur" ] && siblings+=("$base:$k"); done \
        < <(gh_children "$base")
      down=("$base" ${down[@]+"${down[@]}"}); cur="$base"   # another layer below
    else
      TRUNK="$base"; break                               # base has no PR => trunk
    fi
  done
  cur="$head"
  for ((i=0; i<64; i++)); do
    mapfile -t kids < <(gh_children "$cur")
    [ "${#kids[@]}" -eq 0 ] && break
    [ "${#kids[@]}" -eq 1 ] || die \
"fork above '$cur': PRs '${kids[*]}' are all based on it, so there's no single line.
  Check out the branch for the line you want (e.g. '$cur' is the split point —
  check out one of its children) and run the command from there."
    child="${kids[0]}"; up+=("$child"); cur="$child"
  done
  BRANCHES=(${down[@]+"${down[@]}"} "$head" ${up[@]+"${up[@]}"})
  [ -n "${TRUNK:-}" ] || TRUNK="$(default_trunk)"
  local b
  for b in "${BRANCHES[@]}"; do
    git rev-parse --verify -q "$b" >/dev/null \
      || die "branch '$b' (from the PR chain) isn't local; fetch/checkout it first."
  done
  if [ "${#siblings[@]}" -gt 0 ]; then
    info "note: a base branch on this line also feeds branches NOT on this line:"
    for s in "${siblings[@]}"; do info "        ${s%%:*} -> ${s##*:}"; done
    info "      restacking will rewrite that base; restack those line(s) separately"
    info "      (check one out and run sync) or their PRs will go stale."
  fi
}

# Fallback when gh is unavailable or the current branch has no PR. Uses commit
# ancestry; cannot see a base branch that's ahead of its children (scenario 1),
# so it warns; check out the branch for the line you want if it guesses wrong.
detect_via_ancestry() {
  local head trunk b
  head="$(git symbolic-ref -q --short HEAD)" || die "detached HEAD; check out a branch in the stack."
  trunk="$(default_trunk)"
  [ "$head" != "$trunk" ] || die "you're on trunk ($trunk). Check out a branch in the stack."
  info "note: detecting via commit ancestry (no PR data); a base branch with new"
  info "      unpushed-to-children commits may be missed — verify 'restack show'."
  local cand=()
  while read -r b; do
    [ "$b" = "$trunk" ] && continue
    git merge-base --is-ancestor "$trunk" "$b" 2>/dev/null || continue
    if [ "$b" = "$head" ] \
       || git merge-base --is-ancestor "$b" "$head" 2>/dev/null \
       || git merge-base --is-ancestor "$head" "$b" 2>/dev/null; then
      cand+=("$b")
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads)
  mapfile -t BRANCHES < <(
    for b in ${cand[@]+"${cand[@]}"}; do printf '%s\t%s\n' "$(git rev-list --count "$trunk..$b")" "$b"; done \
      | sort -n | cut -f2
  )
  [ "${#BRANCHES[@]}" -gt 0 ] || die "no stack branches found above $trunk on this line."
  local i
  for ((i=0; i+1<${#BRANCHES[@]}; i++)); do
    git merge-base --is-ancestor "${BRANCHES[i]}" "${BRANCHES[i+1]}" 2>/dev/null || die \
"stack is not linear: '${BRANCHES[i]}' and '${BRANCHES[i+1]}' have diverged (a fork).
  Check out the branch for the line you want and run the command from there."
  done
  TRUNK="$trunk"
}

detect_stack() {
  local head; head="$(git symbolic-ref -q --short HEAD)" \
    || die "detached HEAD; check out a branch in the stack."
  if command -v gh >/dev/null 2>&1 && gh_has_pr "$head"; then
    detect_via_prs "$head"
  else
    detect_via_ancestry
  fi
}

load_stack() {
  if [ -f "$STACK_FILE" ]; then
    info "WARNING: a pinned stack file exists at $STACK_FILE and is being IGNORED."
    info "         This tool now always auto-detects from your PRs. The pin can"
    info "         silently exclude layers you add later — delete it: rm $STACK_FILE"
  fi
  detect_stack
}

pr_state() {  # branch -> MERGED/OPEN/CLOSED/NONE
  command -v gh >/dev/null 2>&1 || { echo NONE; return; }
  gh pr view "$1" --json state -q .state 2>/dev/null || echo NONE
}

# Robustly decide whether a branch's PR was MERGED. `gh pr view <branch>` can't
# resolve a branch whose head was deleted (the standard auto-delete flow), so
# query the PR list by head ref name, which is retained on the PR record.
branch_pr_merged() {
  command -v gh >/dev/null 2>&1 || return 1
  local n
  n="$(gh pr list --head "$1" --state merged --json number -q '.[0].number' 2>/dev/null || true)"
  [ -n "$n" ]
}

# Echo the worktree path that has <branch> checked out, if any (empty if none).
worktree_owner() {
  local want="$1" key val cur=""
  while read -r key val; do
    case "$key" in
      worktree) cur="$val" ;;
      branch)   [ "${val#refs/heads/}" = "$want" ] && { echo "$cur"; return; } ;;
    esac
  done < <(git worktree list --porcelain)
}

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------
cmd_show() {
  load_stack
  echo "trunk: $TRUNK"
  # Compare the bottom against the remote trunk if we have it (matches what
  # sync/land target); higher branches compare against their parent.
  local base_ref="$TRUNK"
  git rev-parse --verify -q "$REMOTE/$TRUNK" >/dev/null && base_ref="$REMOTE/$TRUNK"
  local parent="$base_ref" b ahead behind st
  for b in "${BRANCHES[@]}"; do
    if git rev-parse --verify -q "$b" >/dev/null; then
      ahead="$(git rev-list --count "$parent..$b" 2>/dev/null || echo '?')"
      behind="$(git rev-list --count "$b..$parent" 2>/dev/null || echo '?')"
      st="$(pr_state "$b")"
      printf '  %-30s +%s/-%s vs %s   PR:%s\n' "$b" "$ahead" "$behind" "${parent#"$REMOTE"/}" "$st"
    else
      printf '  %-30s (missing locally)\n' "$b"
    fi
    parent="$b"
  done
}

# ---------------------------------------------------------------------------
# shared rebase engine
#   Builds a plan of "<parent_ref> <cut_sha> <branch>" steps and runs them.
#   parent_ref is a NAME (resolved live, so it picks up the prior branch's
#   freshly-rebased tip); cut_sha is a fixed SHA captured before any mutation.
# ---------------------------------------------------------------------------
write_meta() { # op  push-list  retarget  delete-list
  { echo "OP=\"$1\""; echo "TRUNK=\"$TRUNK\""; echo "PUSH=\"$2\""; echo "RETARGET=\"$3\""; echo "DELETE=\"$4\""; } > "$META_FILE"
}

# We rebase ONTO "$REMOTE/$TRUNK" (the fetched remote-tracking ref), so we never
# need to check out or own the local trunk branch — which matters when trunk
# lives in another worktree. As a convenience, advance the local trunk ref to
# match the remote, but only if it isn't owned by a worktree and the move is a
# fast-forward; otherwise leave it untouched.
maybe_advance_trunk() {
  [ -n "$(worktree_owner "$TRUNK")" ] && return 0
  git rev-parse --verify -q "$TRUNK" >/dev/null || return 0
  git merge-base --is-ancestor "$TRUNK" "$REMOTE/$TRUNK" 2>/dev/null \
    && git branch -f "$TRUNK" "$REMOTE/$TRUNK" 2>/dev/null || true
}

# Refuse if any branch we must check out is claimed by another worktree. The
# rebase walk checks out and rewrites each branch in turn, which git forbids
# while the branch is checked out elsewhere — so catch it up front instead of
# crashing mid-walk and leaving orphaned state. NOTE: trunk is NOT included —
# we rebase onto the remote-tracking ref and never check trunk out.
require_branches_free() {
  local here key val cur_wt b
  here="$(git rev-parse --show-toplevel)"
  declare -A owner
  while read -r key val; do
    case "$key" in
      worktree) cur_wt="$val" ;;
      branch)   owner["${val#refs/heads/}"]="$cur_wt" ;;
    esac
  done < <(git worktree list --porcelain)
  for b in "$@"; do
    local w="${owner[$b]:-}"
    if [ -n "$w" ] && [ "$w" != "$here" ]; then
      die "branch '$b' is checked out in another worktree:
    $w
  restack checks out and rewrites each branch, which git won't allow while it's
  claimed by another worktree. Switch that worktree off '$b' (or remove it with
  'git worktree remove'), or run restack from inside it."
    fi
  done
}

# Refuse if a local stack branch is behind its remote (a teammate, another
# machine, or another worktree pushed to it). restack won't clobber their work
# — the lease-protected push would reject it anyway — but better to stop here,
# before rebasing, with a clear message than to fail confusingly at push time.
require_not_behind_origin() {
  local b behind
  for b in "$@"; do
    git rev-parse --verify -q "refs/remotes/$REMOTE/$b" >/dev/null || continue
    behind="$(git rev-list --count "$b..$REMOTE/$b" 2>/dev/null || echo 0)"
    if [ "$behind" -gt 0 ]; then
      die "local '$b' is $behind commit(s) behind $REMOTE/$b — someone pushed to it.
  Integrate their work first, e.g.:
      git checkout $b && git pull --rebase && git checkout -
  then re-run. (restack rewrites branches and won't safely overwrite a branch
  that's behind its remote.)"
    fi
  done
}

# Fetch, then validate the given branches, before any mutation.
preflight() {
  git fetch "$REMOTE" --prune
  require_branches_free "$@"
  require_not_behind_origin "$@"
}

# Pop the first remaining step line.
pop_step() { tail -n +2 "$STEPS_FILE" > "$STEPS_FILE.tmp" && mv "$STEPS_FILE.tmp" "$STEPS_FILE"; }

process_steps() {
  while [ -s "$STEPS_FILE" ]; do
    read -r parent_ref cut branch < "$STEPS_FILE"
    info "rebasing $branch onto $parent_ref (dropping through ${cut:0:9})"
    git checkout -q "$branch"
    if git rebase --onto "$parent_ref" "$cut" "$branch"; then
      pop_step
    else
      echo >&2
      echo "restack: conflict while rebasing '$branch'." >&2
      echo "  1) resolve conflicts, then: git add <files>" >&2
      echo "  2) restack continue" >&2
      echo "  (or: restack abort to roll everything back)" >&2
      exit 3
    fi
  done
  finish
}

finish() {
  # shellcheck disable=SC1090
  source "$META_FILE"
  if [ -n "${PUSH:-}" ]; then
    info "pushing: $PUSH"
    # --atomic: all-or-nothing; --force-if-includes: refuse if remote moved unexpectedly
    git push "$REMOTE" --force-with-lease --force-if-includes --atomic $PUSH
  fi
  if [ -n "${RETARGET:-}" ] && command -v gh >/dev/null 2>&1; then
    info "retargeting PR base of $RETARGET -> $TRUNK"
    gh pr edit "$RETARGET" --base "$TRUNK" >/dev/null 2>&1 \
      || info "(could not retarget $RETARGET; GitHub may have done it automatically)"
  fi
  if [ -n "${DELETE:-}" ]; then
    for b in $DELETE; do
      info "removing merged branch $b"
      git branch -D "$b" 2>/dev/null || true
      git push "$REMOTE" --delete "$b" 2>/dev/null || true
    done
  fi
  rm -f "$META_FILE" "$STEPS_FILE"
  info "done."
  ( cmd_show ) 2>/dev/null || true   # summary only; never let re-detect mask success
}

# ---------------------------------------------------------------------------
# sync  (SCENARIO 1: trunk moved and/or you appended commits to a base branch)
# ---------------------------------------------------------------------------
cmd_sync() {
  require_clean
  git config rerere.enabled true
  load_stack
  preflight "${BRANCHES[@]}"

  # Capture every original tip BEFORE we touch anything.
  declare -A OLD
  local b
  for b in "${BRANCHES[@]}"; do
    git rev-parse --verify -q "$b" >/dev/null || die "branch '$b' missing locally."
    OLD["$b"]="$(git rev-parse "$b")"
  done

  maybe_advance_trunk

  # Build plan. The bottom branch rebases onto the remote trunk, cutting at its
  # merge-base with trunk (so only the branch's own commits replay). Each higher
  # branch rebases onto its parent, cutting at the parent's ORIGINAL tip (so only
  # that branch's unique commits replay — no duplicates, and appended base
  # commits propagate because parent_ref resolves live).
  : > "$STEPS_FILE"
  local parent first=1 cut
  for b in "${BRANCHES[@]}"; do
    if [ "$first" -eq 1 ]; then
      cut="$(git merge-base "$b" "$REMOTE/$TRUNK")"
      echo "$REMOTE/$TRUNK $cut $b" >> "$STEPS_FILE"; first=0
    else
      echo "$parent ${OLD[$parent]} $b" >> "$STEPS_FILE"
    fi
    parent="$b"
  done

  write_meta "sync" "${BRANCHES[*]}" "" ""
  process_steps
}

# ---------------------------------------------------------------------------
# land  (SCENARIO 2: you squash-merged the BOTTOM PR on GitHub)
# ---------------------------------------------------------------------------
# Find a squash-merged base that has been retargeted/deleted out of the PR
# chain (the standard GitHub flow). Scans LOCAL heads *and* remote-tracking refs
# (the base often survives only as origin/<name> if it was never a local branch,
# or vice-versa). A candidate is a ref that SHARES HISTORY with the stack bottom
# and whose PR is MERGED (checked via PR list by head name, which works even
# after the branch is deleted).
#
# The cut we return is merge-base(ref, bottom), NOT the ref's tip. These differ
# when the base branch advanced past the point the bottom forked from it — i.e.
# the bottom never absorbed the base's latest commit(s) before the base was
# merged (a common "forgot to sync the child first" case). The bottom's own work
# begins at that fork point, so that's the correct place to cut; the base's tip
# may not even be an ancestor of the bottom. (In the clean case where the bottom
# sits directly on the base tip, merge-base == tip, so this is a no-op there.)
# A candidate whose fork point is already in trunk is skipped — its shared part
# is folded in (a plain merge, or already landed), so there's nothing to drop.
# Among multiple merged bases, returns the one whose cut reaches furthest into
# the bottom (closest to the bottom's own work).
#
# Sets DISCOVERED_BASE (the cut sha), DISCOVERED_NAME (leftover branch shortname),
# and DISCOVERED_TIP (the merged ref's tip, for divergence messaging).
discover_merged_base() {
  local bottom="$1" ref short s in_stack n mb best="" best_n=-1 have_gh=0
  command -v gh >/dev/null 2>&1 && have_gh=1
  DISCOVERED_BASE=""; DISCOVERED_NAME=""; DISCOVERED_TIP=""
  declare -A seen
  while read -r ref; do
    short="${ref#"$REMOTE"/}"
    [ "$short" = "$TRUNK" ] && continue
    [ "$short" = "HEAD" ] && continue
    in_stack=0; for s in "${BRANCHES[@]}"; do [ "$short" = "$s" ] && { in_stack=1; break; }; done
    [ "$in_stack" -eq 1 ] && continue
    [ -n "${seen[$short]:-}" ] && continue          # local listed first; prefer it over origin/
    seen["$short"]=1
    mb="$(git merge-base "$ref" "$bottom" 2>/dev/null)" || continue              # shares history with bottom
    [ -n "$mb" ] || continue
    git merge-base --is-ancestor "$mb" "$REMOTE/$TRUNK" 2>/dev/null && continue   # fork already in trunk => not a pending squash
    if [ "$have_gh" -eq 1 ]; then branch_pr_merged "$short" || continue; fi
    n="$(git rev-list --count "$REMOTE/$TRUNK..$mb" 2>/dev/null || echo 0)"       # rank by how far the cut reaches into bottom
    if [ "$n" -gt "$best_n" ]; then best_n="$n"; best="$mb"; DISCOVERED_NAME="$short"; DISCOVERED_TIP="$ref"; fi
  done < <( git for-each-ref --format='%(refname:short)' refs/heads
            git for-each-ref --format='%(refname:short)' "refs/remotes/$REMOTE" )
  DISCOVERED_BASE="$best"
}

cmd_land() {
  require_clean
  git config rerere.enabled true

  local from=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from)   from="${2:-}"; shift 2 ;;
      --from=*) from="${1#*=}"; shift ;;
      *) die "land: unknown argument '$1' (usage: restack land [--from <old-base-sha>])" ;;
    esac
  done

  load_stack

  # Decide what was merged, the cut commit to drop up to, the branches to
  # rebase onto trunk (rest), and the merged branches to delete (drop).
  local cut="" rest=() drop=() merged=() b seen_open=0
  for b in "${BRANCHES[@]}"; do
    if [ "$seen_open" -eq 0 ] && branch_pr_merged "$b"; then
      merged+=("$b")
    else
      seen_open=1; rest+=("$b")
    fi
  done

  if [ "${#merged[@]}" -gt 0 ]; then
    # Case A: the merged branch is still in the PR chain (auto-delete off, or
    # run before retarget). Cut at the highest merged branch's tip.
    local lastm="${merged[$((${#merged[@]} - 1))]}"
    cut="$(git rev-parse "$lastm")"
    drop=("${merged[@]}")
  else
    # Case B: standard GitHub flow — base squash-merged, its branch deleted, and
    # the dependent PR auto-retargeted to trunk, so the merged base is gone from
    # the chain. Recover the cut from a local or remote-tracking ref (or --from).
    rest=("${BRANCHES[@]}")
    local bottom="${BRANCHES[0]}"
    if [ -n "$from" ]; then
      # --from is the OLD BASE TIP (e.g. the merged PR's head). The cut is its
      # merge-base with the bottom, so it works even if the base advanced past
      # the bottom's fork point (then the tip isn't an ancestor of the bottom).
      local fromc
      fromc="$(git rev-parse --verify "${from}^{commit}" 2>/dev/null)" \
        || die "land: could not resolve --from '$from' to a commit."
      cut="$(git merge-base "$fromc" "$bottom" 2>/dev/null)" \
        || die "land: --from '$from' shares no history with '$bottom' — wrong sha?"
      [ -n "$cut" ] || die "land: --from '$from' shares no history with '$bottom' — wrong sha?"
    else
      discover_merged_base "$bottom"
      if [ -n "$DISCOVERED_BASE" ]; then
        cut="$DISCOVERED_BASE"          # already merge-base(merged-base, bottom)
        drop=("$DISCOVERED_NAME")
        info "detected squash-merged base '$DISCOVERED_NAME' (now folded into $TRUNK); dropping its commits."
        # If the bottom never absorbed the base's latest commit(s), they live in
        # the squash on trunk and arrive when we rebase the bottom onto it.
        if [ -n "$DISCOVERED_TIP" ] && [ "$(git rev-parse "$DISCOVERED_TIP")" != "$cut" ]; then
          local ahead
          ahead="$(git rev-list --count "$cut..$DISCOVERED_TIP" 2>/dev/null || echo '?')"
          info "note: '$bottom' had not absorbed the last $ahead commit(s) of '$DISCOVERED_NAME';"
          info "      they're already in $TRUNK's squash and come in via the rebase."
        fi
      fi
    fi
    [ -n "$cut" ] || die \
"nothing to land: no merged branch in the chain, and no squash-merged base found
  below '$bottom'. If a base was squash-merged and its branch is gone everywhere,
  pass its old tip explicitly:
      restack land --from \$(gh pr view <merged-pr#> --json headRefOid -q .headRefOid)
  Otherwise you probably want 'restack sync'."
    git merge-base --is-ancestor "$cut" "$bottom" 2>/dev/null \
      || die "land: the cut commit isn't in '$bottom' history (internal error)."
  fi

  [ "${#rest[@]}" -gt 0 ] || info "entire stack is merged; cleaning up only."

  preflight ${rest[@]+"${rest[@]}"}

  declare -A OLD
  for b in "${BRANCHES[@]}"; do
    git rev-parse --verify -q "$b" >/dev/null && OLD["$b"]="$(git rev-parse "$b")"
  done

  maybe_advance_trunk  # trunk (origin) already contains the squash commit

  : > "$STEPS_FILE"
  if [ "${#rest[@]}" -gt 0 ]; then
    # Bottom of `rest` replays onto the remote trunk, cutting at `cut` to drop
    # the merged (squashed) commits; the rest walk up normally.
    local parent first=1
    for b in "${rest[@]}"; do
      if [ "$first" -eq 1 ]; then
        echo "$REMOTE/$TRUNK $cut $b" >> "$STEPS_FILE"; first=0
      else
        echo "$parent ${OLD[$parent]} $b" >> "$STEPS_FILE"
      fi
      parent="$b"
    done
  fi

  local retarget=""; [ "${#rest[@]}" -gt 0 ] && retarget="${rest[0]}"
  write_meta "land" "${rest[*]:-}" "$retarget" "${drop[*]:-}"
  process_steps
}

# ---------------------------------------------------------------------------
# continue / abort
# ---------------------------------------------------------------------------
cmd_continue() {
  [ -f "$META_FILE" ] || die "no restack in progress."
  if [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ]; then
    git rebase --continue || die "still unresolved — fix conflicts, git add, then 'restack continue'."
  fi
  load_stack
  pop_step            # the step we were on is now finished
  process_steps
}

cmd_abort() {
  if [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ]; then
    git rebase --abort || true
  fi
  rm -f "$META_FILE" "$STEPS_FILE"
  info "aborted. Note: branch refs already advanced before the conflict are NOT rewound;"
  info "re-run 'restack sync' (idempotent) to finish, or use 'git reflog' to inspect."
}

# ---------------------------------------------------------------------------
cmd_help() {
  cat <<'EOF'
restack — manual stacked-PR maintenance for a squash-merge workflow

A stack is a chain of dependent branches/PRs (bottom -> top) on a trunk; each
PR targets the branch below it. restack auto-detects the chain from your PR
base branches starting at the branch you're on — no setup, no state files.
Stand on any branch in the stack (not trunk) with a clean working tree, and run:

  restack show        Read-only. Print the detected stack: trunk, each branch's
  (ls, detect)        commits ahead/behind its parent, and PR state. Run this
                      first to preview what an action would touch.

  restack sync        Trunk moved, or you added/amended commits on a lower
                      branch. Rebases each branch onto its updated parent
                      bottom -> top (propagating the change up), then
                      force-pushes the whole stack. Run from any branch.

  restack land        Run after the bottom PR is merged. Handles the standard
                      GitHub flow (squash-merge + auto-deleted branch + the
                      dependent PR auto-retargeted to trunk): it finds the
                      squash-merged base, rebases the rest onto trunk dropping
                      the merged commits, force-pushes, and deletes the leftover
                      local branch. If the merged base's local branch is also
                      gone, pass its old tip: restack land --from <sha>.

  restack continue    Resume after fixing a conflict (git add your fixes first).
                      Use this, NOT `git rebase --continue`, so the multi-branch
                      walk and final push complete.

  restack abort       Abort an in-progress restack and clean up.

  restack help        This message (also: restack with no command).

Notes:
  - Conflicts: restack pauses on the conflicted branch; rerere is enabled, so a
    resolution you make once replays automatically if it recurs up the stack.
  - Pushes use --force-with-lease --force-if-includes --atomic (fail-safe).
  - Trunk is detected as the base of the bottom PR; override: RESTACK_TRUNK=<branch>.
  - Forks: if a branch is the base of two PRs there's no single line. Check out
    the child branch for the line you want and run from there.
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    show|ls|detect)   require_repo; cmd_show ;;
    sync)             require_repo; cmd_sync ;;
    land)             require_repo; cmd_land "$@" ;;
    continue)         require_repo; cmd_continue ;;
    abort)            require_repo; cmd_abort ;;
    help|-h|--help|"") cmd_help ;;
    *) echo "restack: unknown command '$cmd'" >&2; echo >&2; cmd_help >&2; exit 1 ;;
  esac
}
main "$@"
