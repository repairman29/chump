#!/usr/bin/env bash
# End-to-end proof for ONE app's Supabase on cuphead (RESILIENT-314), through public DNS +
# Caddy TLS. Run ON cuphead: keys are read from /srv/supabase-data/.env and never leave the box.
#   scripts/smoke-test.sh [api-host]      default api.postsub.io
# Includes isolation checks against a DIFFERENT app: its user + token must not work here.
set -uo pipefail
set -a; source /srv/supabase-data/.env; set +a
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H=${1:-api.postsub.io}
read -r APP _ _ _ < <(grep -vE '^\s*(#|$)' "$HERE/apps.conf" | awk -v h="$H" '$3==h')
read -r OAPP _ OH _ < <(grep -vE '^\s*(#|$)' "$HERE/apps.conf" | awk -v h="$H" '$3!=h' | head -1)
[[ -n ${APP:-} ]] || { echo "unknown host $H"; exit 2; }
U=${APP^^}; OU=${OAPP^^}
ANON=$(eval echo "\$ANON_KEY_$U"); SVC=$(eval echo "\$SERVICE_ROLE_KEY_$U"); OANON=$(eval echo "\$ANON_KEY_$OU")
ip(){ getent ahostsv4 "$1" | awk 'NR==1{print $1}'; }
IP=${PUBLIC_IP:-$(ip "$H")}
R=(--resolve "$H:443:$IP" -sS --max-time 15); OR=(--resolve "$OH:443:$(ip "$OH")" -sS --max-time 15)
B=https://$H; OB=https://$OH
pass=0; fail=0; ok(){ echo "PASS $*"; pass=$((pass+1)); }; bad(){ echo "FAIL $*"; fail=$((fail+1)); }
chk(){ [[ "$2" == "$3" ]] && ok "$1 ($2)" || bad "$1 (got $2, want $3)"; }
J(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo PARSE_ERR; }
echo "== $H -> app $APP (isolation peer: $OH -> $OAPP)"

chk "auth health" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' $B/auth/v1/health)" 200
EMAIL="r314-probe-$(date +%s)@example.com"; PW="Probe-$(openssl rand -hex 8)"
AK=(-H "apikey: $ANON" -H "Content-Type: application/json")
chk "signup" "$(curl "${R[@]}" -X POST $B/auth/v1/signup "${AK[@]}" -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" | J '"ok" if d.get("id") or d.get("user",{}).get("id") else d')" ok
TOK=$(curl "${R[@]}" -X POST "$B/auth/v1/token?grant_type=password" "${AK[@]}" -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" | J 'd.get("access_token","")')
chk "login returns JWT" "$([[ ${#TOK} -gt 100 ]] && echo yes || echo no)" yes
chk "wrong password rejected" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' -X POST "$B/auth/v1/token?grant_type=password" "${AK[@]}" -d "{\"email\":\"$EMAIL\",\"password\":\"wrong-pass-1\"}")" 400
chk "/auth/v1/user with JWT" "$(curl "${R[@]}" $B/auth/v1/user -H "apikey: $ANON" -H "Authorization: Bearer $TOK" | J 'd.get("email")')" "$EMAIL"

chk "anon sees 0 private rows" "$(curl "${R[@]}" "$B/rest/v1/items?select=is_private" -H "apikey: $ANON" | J 'sum(1 for r in d if r["is_private"])')" 0
chk "authed sees private row" "$(curl "${R[@]}" "$B/rest/v1/items?select=is_private" -H "apikey: $ANON" -H "Authorization: Bearer $TOK" | J 'sum(1 for r in d if r["is_private"])')" 1
chk "no-apikey REST refused" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' "$B/rest/v1/items")" 401
chk "anon write refused" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' -X POST "$B/rest/v1/items" "${AK[@]}" -d '{"title":"anon-write"}')" 401
chk "auth schema not exposed via REST" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' "$B/rest/v1/users" -H "apikey: $ANON" -H "Accept-Profile: auth")" 406
chk "Postgres not public" "$(timeout 5 bash -c "</dev/tcp/$IP/54322" 2>/dev/null && echo open || echo closed)" closed

# Storage round trip over public HTTPS: private bucket, service uploads + downloads, anon cannot read.
SK=(-H "apikey: $SVC" -H "Authorization: Bearer $SVC")
curl "${R[@]}" -o /dev/null -X POST $B/storage/v1/bucket "${SK[@]}" -H "Content-Type: application/json" -d '{"id":"smoke","name":"smoke","public":false}'
OBJ="probe-$(date +%s).txt"; BODY="r314 storage probe $APP $OBJ"
chk "storage upload" "$(printf %s "$BODY" | curl "${R[@]}" -o /dev/null -w '%{http_code}' -X POST "$B/storage/v1/object/smoke/$OBJ" "${SK[@]}" -H 'Content-Type: text/plain' --data-binary @-)" 200
chk "storage download" "$(curl "${R[@]}" "$B/storage/v1/object/smoke/$OBJ" "${SK[@]}")" "$BODY"
chk "storage anon read refused" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' "$B/storage/v1/object/smoke/$OBJ" -H "apikey: $ANON" -H "Authorization: Bearer $ANON")" 400
chk "storage object invisible from $OAPP" "$(curl "${OR[@]}" -o /dev/null -w '%{http_code}' "$OB/storage/v1/object/smoke/$OBJ" -H "apikey: $SVC" -H "Authorization: Bearer $SVC")" 400
curl "${R[@]}" -o /dev/null -X DELETE "$B/storage/v1/object/smoke/$OBJ" "${SK[@]}"

# Isolation: separate user bases + separate JWT secrets.
chk "$APP user cannot log in on $OAPP" "$(curl "${OR[@]}" -o /dev/null -w '%{http_code}' -X POST "$OB/auth/v1/token?grant_type=password" -H "apikey: $OANON" -H "Content-Type: application/json" -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}")" 400
chk "$APP JWT rejected by $OAPP auth" "$(curl "${OR[@]}" -o /dev/null -w '%{http_code}' $OB/auth/v1/user -H "apikey: $OANON" -H "Authorization: Bearer $TOK")" 401
chk "$APP JWT rejected by $OAPP REST" "$(curl "${OR[@]}" -o /dev/null -w '%{http_code}' "$OB/rest/v1/items" -H "apikey: $OANON" -H "Authorization: Bearer $TOK")" 401
chk "$OAPP anon key rejected here" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' "$B/rest/v1/items" -H "apikey: $OANON" -H "Authorization: Bearer $OANON")" 401

UID_=$(curl "${R[@]}" $B/auth/v1/user -H "apikey: $ANON" -H "Authorization: Bearer $TOK" | J 'd.get("id")')
curl "${R[@]}" -o /dev/null -X DELETE "$B/auth/v1/admin/users/$UID_" "${SK[@]}"
echo "== $H: $pass passed, $fail failed"; exit $((fail>0))
