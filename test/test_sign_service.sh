#!/usr/bin/env bash
# test_sign_service.sh
# Automated integration & smoke tests for sign_service on local machine (test only).
# WARNING: modifies /etc/tunnel/tunnel_tokens.json (backups are made).
# Run with sudo/root.

set -euo pipefail

TOKEN_FILE="/etc/tunnel/tunnel_tokens.json"
BACKUP_TOKEN="${TOKEN_FILE}.bak-$(date +%s)"
SERVICE_URL="http://127.0.0.1:5001"
NGINX_HTTPS_URL="https://127.0.0.1"
NGINX_HOST="bitone.in"   # as in your nginx server_name
LOGFILE="/var/log/tunnel_signer.log"

TMP_DIR="$(mktemp -d)"
TEST_KEY_PRIVATE="$TMP_DIR/test_id_ed25519"
TEST_KEY_PUBLIC="$TEST_KEY_PRIVATE.pub"
CERT_OUT="$TMP_DIR/test_cert.pub"
TEST_TOKEN="INTEGRATION_TEST_TOKEN_$(date +%s)"
# Auto-detect principal as the current Linux username
TEST_PRINCIPAL="$(id -un)"
TTL_OK=300
TTL_TOO_LARGE=999999999

cleanup() {
  ret=$?
  echo "Cleaning up..."
  if [ -f "$BACKUP_TOKEN" ]; then
    echo "Restoring tokens backup..."
    cp "$BACKUP_TOKEN" "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    chown root:root "$TOKEN_FILE" || true
  fi
  rm -rf "$TMP_DIR"
  exit $ret
}
trap cleanup EXIT

echo "1) Sanity: service + ports + nginx"
sudo systemctl is-active --quiet sign_service.service && echo "sign_service.service: running" || { echo "sign_service not running"; exit 2; }
ss -ltnp | grep ":5001" -q && echo "Flask listening on 127.0.0.1:5001" || { echo "Flask not listening on 5001"; exit 3; }
nginx -t >/dev/null && echo "nginx config ok" || { echo "nginx config failed"; exit 4; }

echo "2) Backup token file"
if [ -f "$TOKEN_FILE" ]; then
  cp "$TOKEN_FILE" "$BACKUP_TOKEN"
  echo "backup created: $BACKUP_TOKEN"
else
  echo "No token file found, creating empty store then backing up"
  echo '{"tokens":{}}' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  chown root:root "$TOKEN_FILE"
  cp "$TOKEN_FILE" "$BACKUP_TOKEN"
fi

echo "3) Generate temporary SSH keypair (ed25519)"
ssh-keygen -q -t ed25519 -f "$TEST_KEY_PRIVATE" -N "" || { echo "ssh-keygen failed"; exit 5; }
PUBKEY_CONTENT="$(cat "$TEST_KEY_PUBLIC")"
echo "Public key: $PUBKEY_CONTENT"

echo "4) Insert test token into tokens JSON (gives access to $TEST_PRINCIPAL)"
sudo jq --arg t "$TEST_TOKEN" --arg name "int-test" --argjson max_ttl 3600 \
  '.tokens[$t] = {"name":$name, "principals":["'"$TEST_PRINCIPAL"'"], "max_ttl":$max_ttl, "active":true}' \
  "$BACKUP_TOKEN" | sudo tee "$TOKEN_FILE" >/dev/null
sudo chmod 600 "$TOKEN_FILE"
sudo chown root:root "$TOKEN_FILE"

echo "5) Positive test: direct Flask request (expect 200 + cert)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$SERVICE_URL/sign-cert" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d "{\"pubkey\":\"$PUBKEY_CONTENT\",\"principal\":\"$TEST_PRINCIPAL\",\"ttl\":$TTL_OK}")
HTTP=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
echo "HTTP status: $HTTP"
if [ "$HTTP" != "200" ]; then
  echo "FAIL: expected 200, got $HTTP"
  echo "Body: $BODY"
  exit 6
fi
CERT_JSON=$(echo "$BODY" | jq -r '.cert // empty')
if [ -z "$CERT_JSON" ]; then
  echo "FAIL: response missing cert field"
  echo "Body: $BODY"
  exit 7
fi
# write cert to file (single line may include newlines; ensure proper format)
echo "$CERT_JSON" > "$CERT_OUT"
chmod 600 "$CERT_OUT"

echo "6) Validate cert using ssh-keygen -Lf"
if ssh-keygen -Lf "$CERT_OUT" >/dev/null 2>&1; then
  echo "ssh-keygen -L parsed the certificate OK"
else
  echo "FAIL: ssh-keygen could not parse the returned cert"
  echo "Cert contents:"
  sed -n '1,120p' "$CERT_OUT"
  exit 8
fi

echo "7) Negative tests"
echo "7a) Missing Authorization header (expect 401)"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVICE_URL/sign-cert" \
  -H "Content-Type: application/json" \
  -d "{\"pubkey\":\"$PUBKEY_CONTENT\",\"principal\":\"$TEST_PRINCIPAL\"}")
[ "$HTTP" = "401" ] && echo "PASS 401" || { echo "FAIL expected 401 got $HTTP"; exit 9; }

echo "7b) Invalid token (expect 403)"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVICE_URL/sign-cert" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer INVALIDTOKEN" \
  -d "{\"pubkey\":\"$PUBKEY_CONTENT\",\"principal\":\"$TEST_PRINCIPAL\"}")
[ "$HTTP" = "403" ] && echo "PASS 403" || { echo "FAIL expected 403 got $HTTP"; exit 10; }

echo "7c) Principal not allowed (expect 403)"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVICE_URL/sign-cert" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d "{\"pubkey\":\"$PUBKEY_CONTENT\",\"principal\":\"notallowed\"}")
[ "$HTTP" = "403" ] && echo "PASS 403 (principal not allowed)" || { echo "FAIL expected 403 got $HTTP"; exit 11; }

echo "7d) TTL exceed token max (expect 400)"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVICE_URL/sign-cert" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d "{\"pubkey\":\"$PUBKEY_CONTENT\",\"principal\":\"$TEST_PRINCIPAL\",\"ttl\":$TTL_TOO_LARGE}")
[ "$HTTP" = "400" ] && echo "PASS 400 (ttl exceed)" || { echo "FAIL expected 400 got $HTTP"; exit 12; }

echo "8) Proxy via nginx HTTPS server block (Host header required) - using -k for self-signed"
HTTPS_RESP=$(curl -s -w "\n%{http_code}" -k -X POST "$NGINX_HTTPS_URL/sign-cert" \
  -H "Host: $NGINX_HOST" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TEST_TOKEN" \
  -d "{\"pubkey\":\"$PUBKEY_CONTENT\",\"principal\":\"$TEST_PRINCIPAL\",\"ttl\":$TTL_OK}")
HTTPS_HTTP=$(echo "$HTTPS_RESP" | tail -n1)
HTTPS_BODY=$(echo "$HTTPS_RESP" | sed '$d')
if [ "$HTTPS_HTTP" != "200" ]; then
  echo "FAIL: nginx proxy test expected 200 got $HTTPS_HTTP"
  echo "Body: $HTTPS_BODY"
  exit 13
fi
echo "nginx proxy test OK (200)"

echo "ALL TESTS PASSED ✅"

# cleanup (trap will restore backup)
exit 0
