#!/usr/bin/env bash
#
# Regression test: the TOP of a stack is squash-merged into its PARENT feature
# branch (its PR base was the parent, NOT trunk). This is NOT a land-pending —
# the child's work is already folded into the parent as one squash commit — so:
#
#   * `restack show` must say so accurately ("squash-merged into 'parent'"),
#     from EITHER viewpoint (on the child, or on the parent), and must NOT claim
#     it was "squash-merged into main" or suggest a `restack land`.
#   * `restack land` from the parent must REFUSE ("nothing to land") and leave
#     the parent untouched — landing here would wrongly drop the parent's own
#     commits.
#
# Topology (squash-merge workflow):
#
#     main:   C0                              (trunk)
#               \
#     parent:    P1 ------------- S           (S = squash of child PR, base=parent)
#                  \
#     child:        K1 - K2                   (PR MERGED into parent; branch lingers)
#
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
RESTACK="${RESTACK:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/restack.sh"}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@t >/dev/null 2>&1 || true

WORK="$(mktemp -d /tmp/restack_child.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT
fail=0
chk() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fail=1; fi; }

# ---- mock gh: parent PR open (base main); child PR MERGED (base parent) -----
MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/gh" <<'GH'
#!/usr/bin/env bash
sub="$2"
case "$sub" in
  view) b="$3"
    case "$*" in
      *baseRefName*)    case "$b" in parent) echo main;; child) echo parent;; *) exit 1;; esac;;
      *--json\ number*) case "$b" in parent|child) echo 1;; *) exit 1;; esac;;
      *state*)          case "$b" in parent) echo OPEN;; child) echo MERGED;; *) exit 1;; esac;;
      *) exit 1;; esac;;
  list)
    case "$*" in
      *--state\ merged*)                                      # MERGED-only queries
        case "$*" in
          *--head\ child*)  case "$*" in *baseRefName*) echo parent;; *) echo 1;; esac;;
          *--base\ parent*) echo child;;                      # child merged INTO parent
          *) : ;; esac;;
      *--base\ main*)   echo parent;;                          # open children
      *--base\ parent*) : ;;                                   # child is merged, not open
      *) : ;; esac;;
  edit) exit 0;; *) exit 0;; esac
GH
chmod +x "$MOCKBIN/gh"; export PATH="$MOCKBIN:$PATH"

# ---- build the repo --------------------------------------------------------
git init -q --bare "$WORK/remote.git"
git init -q -b main "$WORK/repo"; cd "$WORK/repo"; git remote add origin "$WORK/remote.git"
c(){ git commit -q --allow-empty -m "$1"; }; s(){ echo "$2">"$1"; git add "$1"; }
s base.txt c0; c C0; git push -q origin main
git checkout -q -b parent; s p.txt P1; c P1
git checkout -q -b child;  s k.txt K1; c K1; s k.txt K2; c K2
git push -q origin child
git checkout -q parent; s k.txt "K1+K2 squashed"; c "S squash child PR"; git push -q origin parent
PARENT_BEFORE="$(git rev-parse parent)"

run_show() {  # $1 = branch to stand on ; echoes combined stdout+stderr
  git checkout -q "$1"
  RESTACK_TRUNK=main "$BASH_BIN" "$RESTACK" show 2>&1
}

echo "VIEW 1: standing on the merged child"
OUT="$(run_show child)"; printf '%s\n' "$OUT" | sed 's/^/    /'
chk "names the real merge target (parent)" "printf '%s' \"\$OUT\" | grep -q \"squash-merged into 'parent'\""
chk "does NOT claim a land is pending"     "! printf '%s' \"\$OUT\" | grep -qi 'land pending'"

echo "VIEW 2: standing on the parent"
OUT="$(run_show parent)"; printf '%s\n' "$OUT" | sed 's/^/    /'
chk "names the real merge target (parent)"  "printf '%s' \"\$OUT\" | grep -q \"squash-merged into 'parent'\""
chk "does NOT say 'squash-merged into main'" "! printf '%s' \"\$OUT\" | grep -q 'squash-merged into main'"
chk "does NOT claim a land is pending"       "! printf '%s' \"\$OUT\" | grep -qi 'land pending'"

echo "SAFETY: 'restack land' from the parent must refuse and not touch parent"
git checkout -q parent
LAND="$(RESTACK_TRUNK=main "$BASH_BIN" "$RESTACK" land 2>&1 || true)"
printf '%s\n' "$LAND" | sed 's/^/    /'
chk "land refuses (nothing to land)" "printf '%s' \"\$LAND\" | grep -qi 'nothing to land'"
chk "parent SHA unchanged"           "[ \"\$(git rev-parse parent)\" = \"$PARENT_BEFORE\" ]"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
