#!/usr/bin/env bash
# uninstall.sh
# Usage: sudo ./uninstall.sh
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
echo "Running uninstall script from: $SCRIPT_PATH"
set -euo pipefail

SERVICE="sign_service.service"
SERVICE_UNIT="/etc/systemd/system/sign_service.service"
SERVICE_PY="/usr/local/bin/sign_service.py"
ADD="/usr/local/sbin/add_token.sh"
REVOKE="/usr/local/sbin/revoke_token.sh"
ALLOC="/usr/local/sbin/alloc_user_port.sh"
REGEN="/usr/local/bin/regen_nginx_routes.sh"
REMOVE="/usr/local/sbin/remove_user_port.sh"
NGINX_SNIPPET="/etc/nginx/conf.d/tunnel_signer.conf"
NGINX_USERS_DIR="/etc/nginx/conf.d/users"
SSL_SNIPPET="/etc/nginx/snippets/bitone_ssl.conf"
PROXY_SNIPPET="/etc/nginx/snippets/bitone_proxy.conf"
TOKEN_DIR="/etc/tunnel"
LOG="/var/log/tunnel_signer.log"
CA_DIR="/etc/ssh/ca"
TRUSTED="/etc/ssh/trusted_user_ca_keys.pem"
UNINSTALL_DST="/usr/local/sbin/uninstall_tunnel_signer.sh"

echo "This will stop and remove tunnel signer components installed by setup."
read -p "Proceed? (type YES): " CONF
if [ "$CONF" != "YES" ]; then echo "Aborted"; exit 1; fi

echo "--> Stopping & disabling service"
systemctl stop "$SERVICE" 2>/dev/null || true
systemctl disable "$SERVICE" 2>/dev/null || true

echo "--> Removing systemd unit"
rm -f "$SERVICE_UNIT"
systemctl daemon-reload

echo "--> Removing service binary"
rm -f "$SERVICE_PY"

echo "--> Removing admin helpers"
rm -f "$ADD" "$REVOKE" "$ALLOC" "$REGEN" "$REMOVE"

echo "--> Removing nginx snippet and per-user files"
rm -f "$NGINX_SNIPPET"
if [ -d "$NGINX_USERS_DIR" ]; then rm -rf "$NGINX_USERS_DIR"; fi

echo "--> Removing nginx TLS/proxy snippets"
rm -f "$SSL_SNIPPET" "$PROXY_SNIPPET"

echo "--> Removing token & mapping store"
rm -rf "$TOKEN_DIR"

echo "--> Removing log file"
rm -f "$LOG"

echo "--> nginx test/reload"
if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx
  echo "nginx reloaded"
else
  echo "nginx test failed; check config"
fi

echo
echo "CA keys are preserved by default for safety."
read -p "Remove CA files under $CA_DIR and trusted file $TRUSTED? (type DELETE to remove): " DELCA
if [ "$DELCA" = "DELETE" ]; then
  rm -rf "$CA_DIR"
  rm -f "$TRUSTED"
  echo "CA files removed. You must also remove TrustedUserCAKeys from sshd_config manually if present."
  echo "Restart sshd after editing sshd_config: sudo systemctl restart sshd"
else
  echo "CA files preserved."
fi

rm -f "$UNINSTALL_DST"
echo "Uninstall complete."
