#!/usr/bin/env bash
set -euo pipefail

TOKFILE=/etc/tunnel/tunnel_tokens.json

usage() {
  echo "Usage: $0 <token>"
  exit 2
}

if [ $# -ne 1 ]; then usage; fi

TOKEN="$1"

# try to read the token entry and extract the name (username) if present
if [ -f "$TOKFILE" ]; then
  NAME=$(jq -r --arg t "$TOKEN" '.tokens[$t].name // empty' "$TOKFILE")
else
  NAME=""
fi

# mark token inactive (existing behavior)
jq --arg t "$TOKEN" 'if .tokens[$t] then .tokens[$t].active = false else . end' \
  "$TOKFILE" > /tmp/tokens.new && mv /tmp/tokens.new "$TOKFILE"
chmod 600 "$TOKFILE"

echo "Token $TOKEN revoked (set active=false)"

# if we found a username, try to remove its port mapping and regenerate nginx
if [ -n "$NAME" ]; then
  echo "Found associated username: $NAME — attempting to remove user port mapping..."
  if command -v /usr/local/sbin/remove_user_port.sh >/dev/null 2>&1; then
    /usr/local/sbin/remove_user_port.sh "$NAME"
    echo "User mapping removal attempted for $NAME"
  else
    echo "Warning: remove_user_port.sh not found at /usr/local/sbin/remove_user_port.sh; please remove mapping manually."
  fi
fi
