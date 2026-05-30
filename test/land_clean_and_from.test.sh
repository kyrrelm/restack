#!/usr/bin/env bash
#
# Two regression checks for `restack land`:
#   (1) CLEAN case — the bottom sits directly on the merged base's tip
#       (merge-base == tip). Must behave exactly as before the merge-base change.
#   (2) --from with a DIVERGED base — passing the old base tip (not an ancestor
#       of the bottom) must resolve to the fork point and land correctly.
#
set -euo pipefail
BASH_BIN="${BASH_BIN:-/opt/homebrew/bin/bash}"
RESTACK="${RESTACK:-/Users/kyrremoe/.claude/skills/restack/restack.sh}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@t >/dev/null 2>&1 || true

fail=0
chk() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fail=1; fi; }

make_mock_gh() {  # $1=dir ; mid->base main, top->mid ; base PR #149 MERGED
  mkdir -p "$1"
  cat > "$1/gh" <<'GH'
#!/usr/bin/env bash
sub="$2"
case "$sub" in
  view) b="$3"
    case "$*" in
      *baseRefName*) case "$b" in mid) echo main;; top) echo mid;; *) exit 1;; esac;;
      *--json\ number*) case "$b" in mid|top) echo 1;; *) exit 1;; esac;;
      *state*) case "$b" in mid|top) echo OPEN;; *) exit 1;; esac;;
      *) exit 1;; esac;;
  list)
    case "$*" in
      *--base\ main*) echo mid;;
      *--base\ mid*)  echo top;;
      *--head\ base*) echo 149;;
      *) : ;; esac;;
  edit) exit 0;; *) exit 0;; esac
GH
  chmod +x "$1/gh"
}

# ----------------------------------------------------------------------------
echo "TEST 1: clean case (bottom on base tip, gh discovery)"
W1="$(mktemp -d /tmp/restack_clean.XXXXXX)"; trap 'rm -rf "$W1" "${W2:-}"' EXIT
make_mock_gh "$W1/bin"
git init -q --bare "$W1/remote.git"
git init -q -b main "$W1/repo"; cd "$W1/repo"; git remote add origin "$W1/remote.git"
c(){ git commit -q --allow-empty -m "$1"; }; s(){ echo "$2">"$1"; git add "$1"; }
s base.txt c0; c C0
git checkout -q -b base; s a.txt L1; c L1; s a.txt L2; c L2     # base tip = L2
git checkout -q -b mid; s g.txt G1; c G1; s g.txt G2; c G2      # mid forks AT base tip (clean)
git checkout -q -b top; s f.txt F1; c F1
git push -q origin mid top
git checkout -q main; s a.txt squashed; c "S"; git push -q origin main
git checkout -q top
( export PATH="$W1/bin:$PATH"; RESTACK_TRUNK=main "$BASH_BIN" "$RESTACK" land >/dev/null 2>&1 )
git fetch -q origin
chk "mid has exactly 2 commits over trunk" "[ \"\$(git rev-list --count origin/main..origin/mid)\" = 2 ]"
chk "top has exactly 1 commit over mid"    "[ \"\$(git rev-list --count origin/mid..origin/top)\" = 1 ]"
chk "no L1/L2 commits remain in mid" "! git log --format=%s origin/main..origin/mid | grep -qE '^L[12]$'"

# ----------------------------------------------------------------------------
echo "TEST 2: --from with a diverged base (no gh discovery; explicit old tip)"
W2="$(mktemp -d /tmp/restack_from.XXXXXX)"
# no mock gh on PATH here on purpose? land still calls load_stack which needs
# detection. Keep the mock so detection works, but exercise the --from cut path.
make_mock_gh "$W2/bin"
git init -q --bare "$W2/remote.git"
git init -q -b main "$W2/repo"; cd "$W2/repo"; git remote add origin "$W2/remote.git"
s base.txt c0; c C0
git checkout -q -b base; s a.txt L1; c L1; s a.txt L2; c L2
git checkout -q -b mid; s g.txt G1; c G1; s g.txt G2; c G2      # forks at L2
git checkout -q -b top; s f.txt F1; c F1
git checkout -q base; s a.txt L3; c L3                          # base advances past fork
OLDTIP=$(git rev-parse base)                                    # the "old base tip" a user would pass
git push -q origin mid top
git checkout -q main; s a.txt squashed; c "S"; git push -q origin main
git branch -qD base                                            # base gone entirely; only --from sha remains
git checkout -q top
( export PATH="$W2/bin:$PATH"; RESTACK_TRUNK=main "$BASH_BIN" "$RESTACK" land --from "$OLDTIP" >/dev/null 2>&1 )
git fetch -q origin
chk "mid has exactly 2 commits over trunk (G1,G2)" "[ \"\$(git rev-list --count origin/main..origin/mid)\" = 2 ]"
chk "top has exactly 1 commit over mid (F1)"       "[ \"\$(git rev-list --count origin/mid..origin/top)\" = 1 ]"
chk "no L1/L2/L3 commits remain in mid" "! git log --format=%s origin/main..origin/mid | grep -qE '^L[123]$'"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
