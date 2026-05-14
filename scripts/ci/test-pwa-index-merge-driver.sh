#!/usr/bin/env bash
# scripts/ci/test-pwa-index-merge-driver.sh — INFRA-1201
#
# Verifies the web/v2/index.html hot-file fix:
#   1. .gitattributes declares merge=union for web/v2/index.html
#   2. pre-commit-pwa-index-uniq.sh exists, is executable, and detects:
#      a) duplicate <script src="X.js"> lines
#      b) duplicate <chump-X></chump-X> top-level placements
#   3. The guard is wired into scripts/git-hooks/pre-commit
#   4. End-to-end: synthesize two diverging branches that each append a
#      DIFFERENT <script src=…> line; merge them; assert clean union (no
#      conflict markers). Then synthesize a same-tag duplicate scenario
#      and assert the pre-commit guard catches it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# 1. .gitattributes declares merge=union
grep -qE '^web/v2/index\.html\s+merge=union' "$REPO_ROOT/.gitattributes" \
    || fail ".gitattributes missing 'web/v2/index.html merge=union'"
ok ".gitattributes declares merge=union for web/v2/index.html"

# 2a. Guard script exists + executable
GUARD="$REPO_ROOT/scripts/git-hooks/pre-commit-pwa-index-uniq.sh"
[[ -x "$GUARD" ]] || fail "guard script missing or not executable: $GUARD"
ok "pre-commit-pwa-index-uniq.sh exists and is executable"

# 2b. Guard logic catches duplicate <script src=…>
TMP=$(mktemp -d -t pwa-uniq-test-XXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/web/v2"
cat > "$TMP/web/v2/index.html" <<'HTML'
<!DOCTYPE html>
<html><head></head><body>
  <script src="chat.js" type="module"></script>
  <script src="chat.js" type="module"></script>
  <chump-welcome></chump-welcome>
</body></html>
HTML
( cd "$TMP" && git init -q && git -c user.email=t@t -c user.name=t add web/v2/index.html && git -c user.email=t@t -c user.name=t commit -q -m init )
# Run the guard with REPO_ROOT pointing at the temp repo
( cd "$TMP" && "$GUARD" >/dev/null 2>"$TMP/err" )
RC=$?
[[ "$RC" -ne 0 ]] || fail "guard did NOT reject duplicate <script src> (expected exit 1, got $RC)"
grep -q "duplicate <script src" "$TMP/err" \
    || fail "guard error message does not mention 'duplicate <script src'"
ok "guard rejects duplicate <script src=…> lines"

# 2c. Guard catches duplicate <chump-X></chump-X> placements
cat > "$TMP/web/v2/index.html" <<'HTML'
<!DOCTYPE html>
<html><head></head><body>
  <script src="chat.js" type="module"></script>
  <chump-welcome></chump-welcome>
  <chump-welcome></chump-welcome>
</body></html>
HTML
( cd "$TMP" && git add -u && git -c user.email=t@t -c user.name=t commit -q -m dup-chump )
( cd "$TMP" && "$GUARD" >/dev/null 2>"$TMP/err2" )
RC=$?
[[ "$RC" -ne 0 ]] || fail "guard did NOT reject duplicate <chump-X> (expected exit 1, got $RC)"
grep -q "duplicate <chump-" "$TMP/err2" \
    || fail "guard error message does not mention 'duplicate <chump-'"
ok "guard rejects duplicate <chump-X></chump-X> placements"

# 2d. Guard passes when content is unique
cat > "$TMP/web/v2/index.html" <<'HTML'
<!DOCTYPE html>
<html><head></head><body>
  <script src="chat.js" type="module"></script>
  <script src="app.js" type="module"></script>
  <chump-welcome></chump-welcome>
  <chump-ootb-wizard></chump-ootb-wizard>
</body></html>
HTML
( cd "$TMP" && "$GUARD" >/dev/null 2>"$TMP/err3" )
RC=$?
[[ "$RC" -eq 0 ]] || fail "guard rejected clean file (rc=$RC). stderr: $(cat $TMP/err3)"
ok "guard passes on clean unique content"

# 3. Wired into scripts/git-hooks/pre-commit
grep -q "pre-commit-pwa-index-uniq.sh" "$REPO_ROOT/scripts/git-hooks/pre-commit" \
    || fail "pre-commit hook does not invoke pre-commit-pwa-index-uniq.sh"
ok "pre-commit hook invokes the guard"

# 4. End-to-end union merge: two branches append different <script src> lines
TMP2=$(mktemp -d -t pwa-union-test-XXXX)
mkdir -p "$TMP2/web/v2"
# Base file (mirrors current main shape)
cat > "$TMP2/web/v2/index.html" <<'HTML'
<!DOCTYPE html>
<html><head></head><body>
  <main></main>
  <script src="app.js" type="module"></script>
</body></html>
HTML
( cd "$TMP2" \
  && git init -q --initial-branch=main \
  && git config user.email t@t && git config user.name t \
  && git add -A && git commit -q -m base \
  )

# Register the merge=union for the file
echo 'web/v2/index.html merge=union' > "$TMP2/.gitattributes"
( cd "$TMP2" && git add .gitattributes && git commit -q -m attrs )

# Branch A: add chat.js
( cd "$TMP2" && git checkout -q -b feat-a \
  && python3 -c "
import re
src = open('web/v2/index.html').read()
src = src.replace('<script src=\"app.js\" type=\"module\"></script>',
                  '<script src=\"chat.js\" type=\"module\"></script>\n  <script src=\"app.js\" type=\"module\"></script>')
open('web/v2/index.html','w').write(src)
" \
  && git add -A && git commit -q -m feat-a )

# Branch B (from base after attrs): add cost-meter.js + a custom element
( cd "$TMP2" && git checkout -q main && git checkout -q -b feat-b \
  && python3 -c "
src = open('web/v2/index.html').read()
src = src.replace('<script src=\"app.js\" type=\"module\"></script>',
                  '<script src=\"cost-meter.js\" type=\"module\"></script>\n  <script src=\"app.js\" type=\"module\"></script>')
src = src.replace('<main></main>', '<main></main>\n  <chump-cost-meter></chump-cost-meter>')
open('web/v2/index.html','w').write(src)
" \
  && git add -A && git commit -q -m feat-b )

# Merge feat-a into feat-b — expect clean union resolution
( cd "$TMP2" && git merge --no-edit feat-a >/dev/null 2>&1 )
RC=$?
[[ "$RC" -eq 0 ]] || fail "union merge failed (rc=$RC); .gitattributes union not applied"

# No conflict markers
if grep -qE '<<<<<<<|=======|>>>>>>>' "$TMP2/web/v2/index.html"; then
    fail "union merge left conflict markers in index.html"
fi
# Both feat-a's chat.js and feat-b's cost-meter.js present
grep -q 'chat\.js' "$TMP2/web/v2/index.html" \
    || fail "union merge dropped chat.js from feat-a"
grep -q 'cost-meter\.js' "$TMP2/web/v2/index.html" \
    || fail "union merge dropped cost-meter.js from feat-b"
grep -q 'chump-cost-meter' "$TMP2/web/v2/index.html" \
    || fail "union merge dropped <chump-cost-meter> from feat-b"
ok "two divergent feature branches merge cleanly via union; all additions present"

rm -rf "$TMP2"

echo
echo "All INFRA-1201 PWA-index-merge-driver tests passed."
