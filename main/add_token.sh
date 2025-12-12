#!/usr/bin/env bash
set -euo pipefail
TOKFILE=/etc/tunnel/tunnel_tokens.json

usage() {
  echo "Usage: $0 <name> <principal1,principal2,...> <max_ttl_seconds>"
  exit 2
}

if [ $# -ne 3 ]; then usage; fi

NAME="$1"
PRINCIPALS="$2"
MAX_TTL="$3"

# generate token
TOKEN=$(openssl rand -hex 24)

# create token entry
jq --arg t "$TOKEN" --arg name "$NAME" --arg principals "$PRINCIPALS" --argjson ttl "$MAX_TTL" \
  '.tokens[$t] = {name:$name, principals:($principals|split(",")), max_ttl:$ttl, active:true} | .' \
  "$TOKFILE" > /tmp/tokens.new && mv /tmp/tokens.new "$TOKFILE"
chmod 600 "$TOKFILE"

# after generating TOKEN
ASSIGNED_PORT=$(sudo /usr/local/sbin/alloc_user_port.sh "$NAME")
# then add "port": $ASSIGNED_PORT into the jq object when writing tunnel_tokens.json
# Example jq insertion (adapt to your script)
jq --arg t "$TOKEN" --arg name "$NAME" --arg principals "$PRINCIPALS" --argjson ttl "$MAX_TTL" \
  --argjson port "$ASSIGNED_PORT" \
  '.tokens[$t] = {name:$name, principals:($principals|split(",")), max_ttl:$ttl, port:$port, active:true} | .' \
  "$TOKFILE" > /tmp/tokens.new && mv /tmp/tokens.new "$TOKFILE"
# then regen nginx
sudo /usr/local/bin/regen_nginx_routes.sh

echo "Created token: $TOKEN"
echo "Add this token to the client WSL. It can request certs for principals: $PRINCIPALS (max_ttl=$MAX_TTL)"

