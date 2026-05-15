#!/usr/bin/env bash
# scripts/setup/gen-vapid-keys.sh — INFRA-1301
#
# One-time generation of VAPID (Voluntary Application Server Identification)
# keypair for Web Push. Stored at .chump/push-keys.json. Idempotent: if
# keys already exist, prints existing public key and exits.
#
# Output schema (.chump/push-keys.json):
#   {
#     "vapid_public_key":  "<base64url ECDSA P-256 public key>",
#     "vapid_private_key": "<base64url ECDSA P-256 private key>",
#     "subject":           "mailto:operator@example.com",
#     "generated_at":      "ISO timestamp"
#   }
#
# Public key shape: 65-byte uncompressed point, base64url-encoded.
# Private key shape: 32-byte d-value, base64url-encoded.
# Conforms to RFC 8292 for use with the Web Push Protocol (RFC 8030).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KEYS_FILE="${CHUMP_PUSH_KEYS_FILE:-$REPO_ROOT/.chump/push-keys.json}"
SUBJECT="${CHUMP_PUSH_SUBJECT:-mailto:operator@chump.local}"

ensure_dir() { mkdir -p "$(dirname "$KEYS_FILE")"; }

if [ -f "$KEYS_FILE" ]; then
    pub=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('vapid_public_key',''))" "$KEYS_FILE" 2>/dev/null)
    if [ -n "$pub" ]; then
        echo "[gen-vapid-keys] keys already present at $KEYS_FILE"
        echo "  vapid_public_key: $pub"
        exit 0
    fi
fi

# Generate with python (cryptography lib if available; else fall back to openssl).
ensure_dir
python3 - "$KEYS_FILE" "$SUBJECT" <<'PY' || exit 1
import base64, json, os, subprocess, sys, datetime
keys_file, subject = sys.argv[1], sys.argv[2]

def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()

try:
    # Preferred path: pyca/cryptography (clean, correct, no parsing).
    from cryptography.hazmat.primitives.asymmetric import ec
    private_key = ec.generate_private_key(ec.SECP256R1())
    private_bytes = private_key.private_numbers().private_value.to_bytes(32, 'big')
    pn = private_key.public_key().public_numbers()
    public_bytes = b'\x04' + pn.x.to_bytes(32, 'big') + pn.y.to_bytes(32, 'big')
except ImportError:
    # Fallback: openssl + DER parsing. SEC1 EC private key DER layout:
    #   SEQUENCE {
    #     INTEGER 1,
    #     OCTET STRING(32) privateKey,
    #     [0] EXPLICIT OID,
    #     [1] EXPLICIT BIT STRING publicKey
    #   }
    pem = subprocess.check_output(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout'])
    der = subprocess.check_output(['openssl', 'ec', '-outform', 'DER'], input=pem, stderr=subprocess.DEVNULL)

    def read_tlv(buf, off):
        tag = buf[off]; off += 1
        ll = buf[off]; off += 1
        if ll & 0x80:
            n = ll & 0x7f
            ll = int.from_bytes(buf[off:off+n], 'big')
            off += n
        return tag, ll, off, buf[off:off+ll]

    # Outer SEQUENCE
    tag, length, content_off, _ = read_tlv(der, 0)
    assert tag == 0x30, f'expected SEQUENCE, got 0x{tag:02x}'
    p = content_off
    # INTEGER version
    _, vlen, p, _ = read_tlv(der, p); p += vlen
    # OCTET STRING privateKey
    _, klen, p, kbytes = read_tlv(der, p); p += klen
    assert klen == 32, f'private key wrong len: {klen}'
    private_bytes = kbytes
    # [0] EXPLICIT { OID } — skip the wrapped block entirely.
    _, olen, p, _ = read_tlv(der, p); p += olen
    # [1] EXPLICIT { BIT STRING } — read the [1] wrapper, then descend into BIT STRING inside.
    tag_ctx, ctx_len, ctx_off, ctx_content = read_tlv(der, p)
    assert tag_ctx == 0xa1, f'expected [1] context tag, got 0x{tag_ctx:02x}'
    # Inside the [1] wrapper, read the actual BIT STRING (tag 0x03).
    inner_tag, inner_len, inner_off, inner_bytes = read_tlv(der, ctx_off)
    assert inner_tag == 0x03, f'expected BIT STRING inside [1], got 0x{inner_tag:02x}'
    # BIT STRING content: first byte = unused-bits count (always 0 for our case),
    # rest is the uncompressed EC point (0x04 || X(32) || Y(32)) = 65 bytes.
    pub = inner_bytes[1:]
    assert len(pub) == 65 and pub[0] == 0x04, f'pub wrong: len={len(pub)} first=0x{pub[0]:02x}'
    public_bytes = pub

data = {
    'vapid_public_key':  b64url(public_bytes),
    'vapid_private_key': b64url(private_bytes),
    'subject':           subject,
    'generated_at':      datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
}
with open(keys_file, 'w') as f:
    json.dump(data, f, indent=2)
os.chmod(keys_file, 0o600)
print(f'[gen-vapid-keys] wrote {keys_file}')
print(f'  vapid_public_key: {data["vapid_public_key"]}')
PY
