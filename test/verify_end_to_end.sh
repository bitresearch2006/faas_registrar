#!/usr/bin/env bash
#
# verify_end_to_end.sh
#
# End-to-end automated verification of sign_service via https://bitone.in
# - Requires: curl, jq, ssh-keygen, openssl, add_token.sh & revoke_token.sh (optional)
# - Designed to run on the server where sign_service, nginx and token store exist.
# - Uses -k for curl to accept self-signed certs (remove -k if you use trusted certs).
#
# Run: sudo ./verify_end_to_end.sh
#
set -euo pipefail
IFS=$'\n\t'

# Config - adjust if needed
SIGNER_HOST="https://bitone.in"     # will be called with -k by default
SIGNER_HOST_DIRECT="http://127.0.0.1:5001"
TOKEN_FILE="/etc/tunnel/tunnel_tokens.json"
ADD_TOKEN_CMD="/usr/local/sbin/add_token.sh"
REVOKE_TOKEN_CMD="/usr/local/sbin/revoke_token.sh"
LOGFILE="/var/log/tunnel_signer.log"

TMPDIR="$(mktemp -d /tmp/signer-test.XXXX)"
TEST_KEY_PRIV="$TMPDIR/test_id_ed25519"
TEST_KEY_PUB="$TMPDIR/test_id_ed25519.pub"
CERT_OUT="$TMPDIR/test_cert.pub"
BACKUP_TOKEN="${TOKEN_FILE}.bak.$(date +%s)"
USE_ADD_HELPER=false
CREATED_TOKEN=""
TEST_PRINCIPAL="bitresearch"
TTL_OK=300
TTL_TOO_LARGE=999999999

cleanup() {
  rc=$?
  echo
  echo "Cleaning up..."
  # Revoke token if we created it via helper and it still exists
  if [ -n "${CREATED_TOKEN:-}" ]; then
    if [ -x "$REVOKE_TOKEN_CMD" ]; then
      echo " - Revoking token via helper..."
      set +e
      sudo "$REVOKE_TOKEN_CMD" "$CREATED_TOKEN" >/dev/null 2>&1 || true
      set -e
    else
      # remove token from JSON if backup exists
      if [ -f "$BACKUP_TOKEN" ]; then
        echo " - Restoring token JSON backup..."
        sudo cp "$BACKUP_TOKEN" "$TOKEN_FILE"
        sudo chown root:root "$TOKEN_FILE" || true
        sudo chmod 600 "$TOKEN_FILE" || true
      fi
    fi
  else
    # If we created a backup but didn't insert token via helper, restore original file
    if [ -f "$BACKUP_TOKEN" ]; then
      echo " - Restoring token JSON backup..."
      sudo cp "$BACKUP_TOKEN" "$TOKEN_FILE"
      sudo chown root:root "$TOKEN_FILE" || true
      sudo chmod 600 "$TOKEN_FILE" || true
    fi
  fi

  rm -rf "$TMPDIR"
  exit $rc
}
trap cleanup EXIT

echo "=== End-to-end verification via $SIGNER_HOST ==="
echo "Temporary dir: $TMPDIR"
echo

# 0) Checks: required tools
for cmd in curl jq ssh-keygen openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command missing: $cmd"
    exit 2
  fi
done

# 1) Sanity checks: systemd service & nginx & signer listening
echo "1) Sanity checks"
if systemctl is-active --quiet sign_service.service; then
  echo " - sign_service.service: running"
else
  echo "ERROR: sign_service.service not running"
  exit 3
fi

if nginx -t >/dev/null 2>&1; then
  echo " - nginx config: OK"
else
  echo "ERROR: nginx config test failed"
  nginx -t || true
  exit 4
fi

# check direct listener
if ss -ltnp | grep -q '127.0.0.1:5001'; then
  echo " - Flask listening on 127.0.0.1:5001"
else
  echo "ERROR: Flask not listening on 127.0.0.1:5001"
  ss -ltnp | grep 5001 || true
  exit 5
fi

echo

# 2) Backup token file
echo "2) Backing up token file"
if [ -f "$TOKEN_FILE" ]; then
  sudo cp "$TOKEN_FILE" "$BACKUP_TOKEN"
  sudo chown root:root "$BACKUP_TOKEN" || true
  echo " - backup created: $BACKUP_TOKEN"
else
  echo " - token store not found; creating empty store"
  echo '{"tokens":{}}' | sudo tee "$TOKEN_FILE" >/dev/null
  sudo chmod 600 "$TOKEN_FILE"
  sudo chown root:root "$TOKEN_FILE"
  sudo cp "$TOKEN_FILE" "$BACKUP_TOKEN"
fi

# 3) Create temporary token (prefer helper)
echo "3) Creating temporary token"
if [ -x "$ADD_TOKEN_CMD" ]; then
  echo " - Using helper: $ADD_TOKEN_CMD"
  USE_ADD_HELPER=true
  # helper prints 'Created token: <token>' - capture that
  OUT="$("$ADD_TOKEN_CMD" "e2e-test" "automated verification" "$TTL_OK" 2>&1)"
  echo "$OUT"
  # extract hex-like token
  TOK="$(printf "%s" "$OUT" | sed -n 's/.*Created token:[[:space:]]*\([a-f0-9]\+\).*/\1/p' || true)"
  if [ -z "$TOK" ]; then
    # fallback: try to parse last JSON entry (risky)
    TOK=""
  fi
  if [ -n "$TOK" ]; then
    CREATED_TOKEN="$TOK"
    echo " - Created token: $CREATED_TOKEN"
  else
    echo "WARN: Could not parse token from helper output. Will fall back to jq insertion."
    USE_ADD_HELPER=false
  fi
fi

if ! $USE_ADD_HELPER; then
  # Insert token via jq into JSON (idempotent)
  CREATED_TOKEN="E2E_TEST_TOKEN_$(date +%s)"
  sudo jq --arg t "$CREATED_TOKEN" --arg name "e2e-test" --argjson max_ttl $TTL_OK \
    '.tokens[$t] = {"name":$name, "principals": ["'"$TEST_PRINCIPAL"'"], "max_ttl":$max_ttl, "active":true}' \
    "$BACKUP_TOKEN" | sudo tee "$TOKEN_FILE" >/dev/null
  sudo chmod 600 "$TOKEN_FILE"
  sudo chown root:root "$TOKEN_FILE"
  echo " - Inserted token into $TOKEN_FILE: $CREATED_TOKEN"
  # reload nginx/routes if helper exists
  if command -v regen_nginx_routes >/dev/null 2>&1; then
    echo " - Running regen_nginx_routes..."
    sudo regen_nginx_routes || true
  fi
fi

echo

# 4) Generate temporary SSH keypair
echo "4) Generating temporary SSH keypair"
ssh-keygen -t ed25519 -f "$TEST_KEY_PRIV" -N "" -q
PUBCONTENT="$(sed -n '1p' "$TEST_KEY_PUB")"
echo " - Pubkey: ${PUBCONTENT:0:80}..."

# 5) Positive test: POST to HTTPS path (via nginx). Using -k for self-signed.
echo "5) Positive test: POST via HTTPS -> $SIGNER_HOST/sign-cert"
JSON_PAY=$(jq -n --arg pub "$PUBCONTENT" --arg princ "$TEST_PRINCIPAL" --argjson ttl $TTL_OK \
  '{pubkey:$pub, principal:$princ, ttl:$ttl}')
# use Host header to make sure nginx selects the right server block
HTTP_RESP=$(curl -s -w "\n%{http_code}" -k -H "Host: bitone.in" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CREATED_TOKEN" \
  -X POST "$SIGNER_HOST/sign-cert" \
  -d "$JSON_PAY")
HTTP_CODE=$(echo "$HTTP_RESP" | tail -n1)
HTTP_BODY=$(echo "$HTTP_RESP" | sed '$d')
echo " - HTTP code: $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: expected 200 from signer via HTTPS, got $HTTP_CODE"
  echo "Body: $HTTP_BODY"
  exit 6
fi
CERT_JSON=$(echo "$HTTP_BODY" | jq -r '.cert // empty')
if [ -z "$CERT_JSON" ]; then
  echo "ERROR: response missing cert field"
  echo "$HTTP_BODY"
  exit 7
fi
# save cert for validation
echo "$CERT_JSON" > "$CERT_OUT"
chmod 600 "$CERT_OUT"
echo " - Received cert saved to $CERT_OUT"

# 6) Validate cert with ssh-keygen
echo "6) Validating returned certificate with ssh-keygen -Lf"
if ssh-keygen -Lf "$CERT_OUT" >/dev/null 2>&1; then
  echo " - ssh-keygen parsed certificate OK"
else
  echo "ERROR: ssh-keygen failed to parse certificate"
  ssh-keygen -Lf "$CERT_OUT" || true
  exit 8
fi

# 7) Negative tests (missing auth, invalid token, principal not allowed, ttl too large)
echo "7) Negative tests"

echo "  7a) Missing Authorization (expect 401)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k -H "Host: bitone.in" \
  -H "Content-Type: application/json" \
  -X POST "$SIGNER_HOST/sign-cert" -d "$JSON_PAY")
if [ "$HTTP_CODE" = "401" ]; then
  echo "   - PASS (401)"
else
  echo "   - FAIL expected 401 got $HTTP_CODE"
  exit 9
fi

echo "  7b) Invalid token (expect 403)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k -H "Host: bitone.in" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer INVALIDTOKEN" \
  -X POST "$SIGNER_HOST/sign-cert" -d "$JSON_PAY")
if [ "$HTTP_CODE" = "403" ]; then
  echo "   - PASS (403)"
else
  echo "   - FAIL expected 403 got $HTTP_CODE"
  exit 10
fi

echo "  7c) Principal not allowed (expect 403)"
BADPAY=$(jq -n --arg pub "$PUBCONTENT" --argjson ttl $TTL_OK '{pubkey:$pub, principal:"notallowed", ttl:$ttl}')
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k -H "Host: bitone.in" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CREATED_TOKEN" \
  -X POST "$SIGNER_HOST/sign-cert" -d "$BADPAY")
if [ "$HTTP_CODE" = "403" ]; then
  echo "   - PASS (403 principal not allowed)"
else
  echo "   - FAIL expected 403 got $HTTP_CODE"
  exit 11
fi

echo "  7d) TTL exceed token max (expect 400)"
BADPAY2=$(jq -n --arg pub "$PUBCONTENT" --arg princ "$TEST_PRINCIPAL" --argjson ttl $TTL_TOO_LARGE '{pubkey:$pub, principal:$princ, ttl:$ttl}')
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k -H "Host: bitone.in" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CREATED_TOKEN" \
  -X POST "$SIGNER_HOST/sign-cert" -d "$BADPAY2")
if [ "$HTTP_CODE" = "400" ]; then
  echo "   - PASS (400 ttl exceed)"
else
  echo "   - FAIL expected 400 got $HTTP_CODE"
  exit 12
fi

echo

# 8) Direct test to Flask (bypass nginx) for sanity
echo "8) Direct test to Flask (bypass nginx) expecting 200"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CREATED_TOKEN" \
  -X POST "$SIGNER_HOST_DIRECT/sign-cert" -d "$JSON_PAY")
if [ "$HTTP_CODE" = "200" ]; then
  echo " - PASS direct Flask"
else
  echo " - FAIL direct Flask expected 200 got $HTTP_CODE"
  exit 13
fi

echo
echo "ALL TESTS PASSED ✅"
# successful exit -> cleanup will revoke / restore
exit 0
