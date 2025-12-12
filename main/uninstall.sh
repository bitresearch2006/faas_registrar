#!/usr/bin/env bash
set -euo pipefail

echo "==============================================="
echo " Tunnel Signer Uninstaller"
echo "==============================================="

# Installed paths from setup_tunnel_signer.sh
SERVICE_UNIT="/etc/systemd/system/sign_service.service"
SERVICE_PY="/usr/local/bin/sign_service.py"

ADD_TOKEN="/usr/local/sbin/add_token.sh"
REVOKE_TOKEN="/usr/local/sbin/revoke_token.sh"

TOKEN_DIR="/etc/tunnel"
TOKEN_FILE="/etc/tunnel/tunnel_tokens.json"

NGINX_SNIPPET="/etc/nginx/conf.d/tunnel_signer.conf"

CA_DIR="/etc/ssh/ca"
CA_KEY="$CA_DIR/ssh_ca"
CA_PUB="$CA_DIR/ssh_ca.pub"
TRUSTED_CA="/etc/ssh/trusted_user_ca_keys.pem"

LOGFILE="/var/log/tunnel_signer.log"

if (( EUID != 0 )); then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

echo "--> Stopping signing service (if exists)..."
systemctl stop sign_service.service 2>/dev/null || true
systemctl disable sign_service.service 2>/dev/null || true

echo "--> Removing systemd unit..."
rm -f "$SERVICE_UNIT"
systemctl daemon-reload

echo "--> Removing signing service file..."
rm -f "$SERVICE_PY"

echo "--> Removing admin helper scripts..."
rm -f "$ADD_TOKEN" "$REVOKE_TOKEN"

echo "--> Removing token store..."
rm -f "$TOKEN_FILE"
rm -d "$TOKEN_DIR" 2>/dev/null || true

echo "--> Removing nginx snippet..."
rm -f "$NGINX_SNIPPET"

echo "--> Testing nginx..."
if nginx -t >/dev/null 2>&1; then
    echo "   Reloading nginx..."
    systemctl reload nginx
else
    echo "WARNING: nginx test failed — your nginx config may need attention"
fi

echo "--> Removing log file..."
rm -f "$LOGFILE"

# OPTIONAL: Remove CA (DISABLED BY DEFAULT — uncomment if you want)
REMOVE_CA=false   # <-- CHANGE TO true IF YOU WANT TO DELETE CA

if [ "$REMOVE_CA" = true ]; then
    echo "--> Removing CA files (You enabled REMOVE_CA=true)"
    rm -f "$CA_KEY" "$CA_PUB"
    rm -d "$CA_DIR" 2>/dev/null || true
    rm -f "$TRUSTED_CA"
    echo "   NOTE: You must manually clean sshd_config if CA lines remain."
else
    echo "--> CA removal skipped (REMOVE_CA=false)."
    echo "    CA files preserved under: $CA_DIR"
fi

echo "--> Uninstall complete!"
echo "==============================================="
echo "What remains:"
echo "- CA directory (unless REMOVE_CA=true)"
echo "- Nginx & SSH original configs untouched"
echo
echo "All tunnel signer components have been removed."
