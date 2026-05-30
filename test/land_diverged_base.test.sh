#!/usr/bin/env bash
#
# Regression test for `restack land` when the squash-merged base branch had
# advanced PAST the point its child forked from it (the common "I didn't sync
# the child before merging the base" case).
#
# Topology built below (squash-merge workflow):
#
#     main:  C0 ---------------------- S          (S = squash of base PR #149)
#              \
#     base:     L1 - L2(fork) - L3                (PR #149, MERGED + deleted on remote;
#                       \                          local copy lingers at L3)
#     mid:               G1 - G2                  (PR open, auto-retargeted base -> main)
#     top:                     F1                 (PR open, base = mid)
#
# `mid` forked from `base` at L2 but never absorbed L3. After base is squash-
# merged, base's tip (L3) is NOT an ancestor of `mid`, so the OLD discovery
# logic (which required the merged ref to be a direct ancestor of the bottom)
# found nothing and `land` refused. The correct cut is merge-base(base, mid) = L2.
#
# Pass criteria after `restack land`:
#   - origin/mid  == S + G1 + G2  (login commits dropped, replayed onto trunk)
#   - origin/top  == mid' + F1
#   - no L1/L2/L3 content commits remain in the rebased branches
#
set -euo pipefail

BASH_BIN="${BASH_BIN:-/opt/homebrew/bin/bash}"
RESTACK="${RESTACK:-/Users/kyrremoe/.claude/skills/restack/restack.sh}"

WORK="$(mktemp -d /tmp/restack_test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@t >/dev/null 2>&1 || true

# ---- mock gh ---------------------------------------------------------------
# Answers only the queries restack issues, for this fixed topology.
MOCKBIN="$WORK/bin"
mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/gh" <<'GH'
#!/usr/bin/env bash
# usage patterns we must answer (see restack.sh gh_* helpers):
#   gh pr view <b> --json baseRefName -q .baseRefName
#   gh pr view <b> --json number      -q .number
#   gh pr view <b> --json state       -q .state
#   gh pr list --base <b> --json headRefName -q '.[].headRefName'
#   gh pr list --head <b> --state merged --json number -q '.[0].number'
#   gh pr edit <b> --base <trunk>
sub="$2"
case "$sub" in
  view)
    b="$3"
    case "$*" in
      *baseRefName*) case "$b" in mid) echo main;; top) echo mid;; *) exit 1;; esac;;
      *--json\ number*) case "$b" in mid|top) echo 1;; *) exit 1;; esac;;
      *state*) case "$b" in mid|top) echo OPEN;; *) exit 1;; esac;;
      *) exit 1;;
    esac;;
  list)
    case "$*" in
      *--base\ main*)  echo mid;;
      *--base\ mid*)   echo top;;
      *--base\ top*)   : ;;                       # no children
      *--head\ base*)  echo 149;;                 # the MERGED base PR
      *--head\ *)      : ;;                        # others: not merged
      *) : ;;
    esac;;
  edit) exit 0;;                                   # retarget noop
  *) exit 0;;
esac
GH
chmod +x "$MOCKBIN/gh"
export PATH="$MOCKBIN:$PATH"

# ---- build the synthetic repo + bare remote --------------------------------
REMOTE="$WORK/remote.git"
git init -q --bare "$REMOTE"
REPO="$WORK/repo"
git init -q -b main "$REPO"
cd "$REPO"
git remote add origin "$REMOTE"

commit() { git commit -q --allow-empty -m "$1"; }
seed() { echo "$2" > "$1"; git add "$1"; }

seed base.txt c0; commit C0                # main C0

git checkout -q -b base
seed a.txt L1; commit L1
seed a.txt L2; commit L2                    # fork point
FORK=$(git rev-parse HEAD)

git checkout -q -b mid                      # mid forks here, off L2
seed g.txt G1; commit G1
seed g.txt G2; commit G2

git checkout -q -b top
seed f.txt F1; commit F1

git checkout -q base                        # base advances PAST the fork
seed a.txt L3; commit L3

# publish mid & top to the remote (their PRs are open)
git push -q origin mid top

# squash-merge base into main: one new commit S carrying base's net change,
# then "delete" base on the remote (it never had a remote branch here, so just
# ensure origin has no base ref — it doesn't). main advances to S.
git checkout -q main
seed a.txt "L1+L2+L3-squashed"; commit "S squash PR149"
git push -q origin main

# leave a lingering LOCAL base at L3 (mirrors the real repo), no remote base ref
git branch -f base "$(git rev-parse base)" >/dev/null 2>&1 || true

# ---- run land from the top branch ------------------------------------------
git checkout -q top
echo "### restack show (before):" >&2
RESTACK_TRUNK=main "$BASH_BIN" "$RESTACK" show || true
echo "### restack land:" >&2
RESTACK_TRUNK=main "$BASH_BIN" "$RESTACK" land

# ---- assertions ------------------------------------------------------------
git fetch -q origin
fail=0
chk() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

S=$(git rev-parse origin/main)
# mid' should be exactly S + 2 commits (G1,G2)
chk "mid sits directly on trunk S" "git merge-base --is-ancestor '$S' origin/mid"
chk "mid has exactly 2 commits over trunk (G1,G2; login dropped)" \
    "[ \"\$(git rev-list --count origin/main..origin/mid)\" = 2 ]"
chk "top has exactly 1 commit over mid (F1)" \
    "[ \"\$(git rev-list --count origin/mid..origin/top)\" = 1 ]"
chk "no 'L1'/'L2'/'L3' commits remain in mid" \
    "! git log --format=%s origin/main..origin/mid | grep -qE '^L[123]$'"
chk "a.txt content comes from the squash (trunk), present in mid" \
    "git cat-file -e origin/mid:a.txt 2>/dev/null && [ \"\$(git show origin/mid:a.txt)\" = 'L1+L2+L3-squashed' ]"
chk "leftover local base branch was deleted" \
    "! git show-ref -q --verify refs/heads/base"

echo
if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
