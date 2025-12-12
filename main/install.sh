#!/usr/bin/env bash
set -euo pipefail

# setup_tunnel_signer.sh (updated)
# Place this script in the same directory as:
# vm_create_ca.sh, sign_service.py, sign_service.service,
# add_token.sh, revoke_token.sh, tunnel_signer.conf,
# alloc_user_port.sh, regen_nginx_routes.sh, remove_user_port.sh
#
# Run as root:
# sudo bash setup_tunnel_signer.sh

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source files expected
F_CA_CREATE="$SRC_DIR/create_ca.sh"
F_SIGN_SERVICE_PY="$SRC_DIR/sign_service.py"
F_SIGN_SERVICE_UNIT="$SRC_DIR/sign_service.service"
F_ADD_TOKEN="$SRC_DIR/add_token.sh"
F_REVOKE_TOKEN="$SRC_DIR/revoke_token.sh"
F_TUNNEL_CONF="$SRC_DIR/tunnel_signer.conf"
F_ALLOC_PORT="$SRC_DIR/alloc_user_port.sh"
F_REGEN_NGINX="$SRC_DIR/regen_nginx_routes.sh"
F_REMOVE_PORT="$SRC_DIR/remove_user_port.sh"

CA_DIR="/etc/ssh/ca"
TRUSTED_CA="/etc/ssh/trusted_user_ca_keys.pem"

# Destinations
SERVICE_PY="/usr/local/bin/sign_service.py"
SERVICE_UNIT="/etc/systemd/system/sign_service.service"
ADD_TOKEN_DST="/usr/local/sbin/add_token.sh"
REVOKE_TOKEN_DST="/usr/local/sbin/revoke_token.sh"
ALLOC_PORT_DST="/usr/local/sbin/alloc_user_port.sh"
REGEN_NGINX_DST="/usr/local/bin/regen_nginx_routes.sh"
REMOVE_PORT_DST="/usr/local/sbin/remove_user_port.sh"
NGINX_USERS_DIR="/etc/nginx/conf.d/users"

# install the provided site config into sites-available and enable it
NGINX_SITE="/etc/nginx/sites-available/bitone.in"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/bitone.in"

TOKEN_DIR="/etc/tunnel"
TOKEN_FILE="$TOKEN_DIR/tunnel_tokens.json"
USER_PORTS="$TOKEN_DIR/user_ports.json"
LOGFILE="/var/log/tunnel_signer.log"

# --- set up python virtualenv for the signing service ---
VENV_DIR="/opt/tunnel_signer/venv"
PY_BIN="$VENV_DIR/bin/python3"
PIP_BIN="$VENV_DIR/bin/pip3"


echo "=== Tunnel signer installer (updated) ==="

if (( EUID != 0 )); then
  echo "ERROR: run as root (sudo)"; exit 1
fi

# Confirm all source files exist
for f in "$F_CA_CREATE" "$F_SIGN_SERVICE_PY" "$F_SIGN_SERVICE_UNIT" "$F_ADD_TOKEN" "$F_REVOKE_TOKEN" "$F_TUNNEL_CONF" "$F_ALLOC_PORT" "$F_REGEN_NGINX" "$F_REMOVE_PORT"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing required file: $f" >&2
    exit 2
  fi
done

echo "--> Installing OS packages (python3, pip, jq, openssl, nginx)..."
apt-get update -y
apt-get install -y python3 python3-pip jq openssl nginx

# ensure python venv support exists
if ! python3 -c "import ensurepip" >/dev/null 2>&1 && ! python3 -c "import venv" >/dev/null 2>&1; then
  echo "python3 venv/ensurepip not available. Trying to install python3-venv via apt..."
  if command -v apt >/dev/null 2>&1; then
    apt update
    # try generic package first, then try a versioned one
    apt install -y python3-venv || apt install -y python3.$(python3 -c 'import sys; print("{}.{}".format(sys.version_info.major, sys.version_info.minor))')-venv
  else
    echo "apt not found — cannot auto-install python3-venv. Please install python3-venv package manually."
    exit 1
  fi
fi

# create venv if missing
if [ ! -x "$PY_BIN" ]; then
  echo "--> Creating python virtualenv at $VENV_DIR"
  mkdir -p "$(dirname "$VENV_DIR")"
  python3 -m venv "$VENV_DIR"
  chown -R root:root "$VENV_DIR"
  chmod -R 750 "$VENV_DIR"
fi

# upgrade pip inside venv and install runtime deps
"$PIP_BIN" install --upgrade pip setuptools wheel
"$PIP_BIN" install --no-cache-dir flask

# sanity check
if ! "$PY_BIN" -c "import flask" >/dev/null 2>&1; then
  echo "ERROR: flask not available inside venv $VENV_DIR" >&2
  exit 1
fi
echo "   Flask installed in venv: $VENV_DIR"
# --- end venv setup ---

# Ensure openssh-server exists (create_ca.sh needs sshd + config)
if [ ! -f /etc/ssh/sshd_config ] || [ ! -x /usr/sbin/sshd ]; then
  echo "[INFO] openssh-server not found — installing..."
  apt-get install -y openssh-server
fi

# Run CA creation script (provided by user)
echo "--> Running vm_create_ca.sh to create CA and configure sshd..."
chmod +x "$F_CA_CREATE"
bash "$F_CA_CREATE"

# ensure trusted CA exists (vm_create_ca.sh should have produced it)
if [ ! -f "${CA_DIR}/ssh_ca" ] && [ ! -f "${CA_DIR}/ssh_ca.pub" ]; then
  echo "WARNING: CA keys not found under $CA_DIR; please check $CA_SCRIPT_SRC output." >&2
fi
if [ -f "${CA_DIR}/ssh_ca.pub" ] && [ ! -f "$TRUSTED_CA" ]; then
  cp "${CA_DIR}/ssh_ca.pub" "$TRUSTED_CA"
  chmod 644 "$TRUSTED_CA"
fi

# Create token & mapping directories/files if needed
mkdir -p "$TOKEN_DIR"
chown root:root "$TOKEN_DIR"
chmod 700 "$TOKEN_DIR"

if [ ! -f "$TOKEN_FILE" ]; then
  echo '{"tokens":{}}' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  chown root:root "$TOKEN_FILE"
  echo "--> Created token file: $TOKEN_FILE"
else
  echo "--> Token file exists: $TOKEN_FILE"
fi

if [ ! -f "$USER_PORTS" ]; then
  cat > "$USER_PORTS" <<'JSON'
{"users": {}, "port_range": {"min": 9001, "max": 9100}}
JSON
  chmod 600 "$USER_PORTS"
  chown root:root "$USER_PORTS"
  echo "--> Created user_ports mapping: $USER_PORTS"
else
  echo "--> user_ports mapping exists: $USER_PORTS"
fi

# Copy signing service
echo "--> Installing sign_service.py -> $SERVICE_PY"
cp "$F_SIGN_SERVICE_PY" "$SERVICE_PY"
chmod 700 "$SERVICE_PY"
chown root:root "$SERVICE_PY"

# Install systemd unit
echo "--> Installing systemd unit -> $SERVICE_UNIT"
cp "$F_SIGN_SERVICE_UNIT" "$SERVICE_UNIT"
chmod 644 "$SERVICE_UNIT"
systemctl daemon-reload
systemctl enable --now sign_service.service
systemctl status --no-pager sign_service.service || true

# Copy admin helpers and scripts
echo "--> Installing admin scripts"
cp "$F_ADD_TOKEN" "$ADD_TOKEN_DST"
cp "$F_REVOKE_TOKEN" "$REVOKE_TOKEN_DST"
cp "$F_ALLOC_PORT" "$ALLOC_PORT_DST"
cp "$F_REGEN_NGINX" "$REGEN_NGINX_DST"
cp "$F_REMOVE_PORT" "$REMOVE_PORT_DST"

chmod 700 "$ADD_TOKEN_DST" "$REVOKE_TOKEN_DST" "$ALLOC_PORT_DST" "$REGEN_NGINX_DST" "$REMOVE_PORT_DST"
chown root:root "$ADD_TOKEN_DST" "$REVOKE_TOKEN_DST" "$ALLOC_PORT_DST" "$REGEN_NGINX_DST" "$REMOVE_PORT_DST"

# create nginx per-user dir and snippet
mkdir -p "$NGINX_USERS_DIR"
chown root:root "$NGINX_USERS_DIR"
chmod 750 "$NGINX_USERS_DIR"

echo "--> Installing nginx site for bitone.in"
cp "$F_TUNNEL_CONF" "$NGINX_SITE"
ln -sf "$NGINX_SITE" "$NGINX_SITE_ENABLED"
chmod 644 "$NGINX_SITE"
# Log file
touch "$LOGFILE"
chmod 600 "$LOGFILE"
chown root:root "$LOGFILE"


# Test nginx config and reload
echo "--> Testing nginx configuration..."
if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx
  echo "   nginx reloaded"
else
  echo "ERROR: nginx config test failed. Run 'nginx -t' to inspect." >&2
  nginx -t || true
  exit 3
fi

echo "=== Installation finished ==="
echo "Token store: $TOKEN_FILE"
echo "User->port map: $USER_PORTS"
echo "Per-user nginx dir: $NGINX_USERS_DIR"
echo "Sign service: systemctl status sign_service.service"
echo "Admin helpers: $ADD_TOKEN_DST , $REVOKE_TOKEN_DST"
echo "Port allocator: $ALLOC_PORT_DST"
echo "Nginx regen: $REGEN_NGINX_DST"
echo "Remove port helper: $REMOVE_PORT_DST"
echo "Nginx snippet: $NGINX_SNIPPET"
echo "Log: $LOGFILE"
echo
echo "Next steps (example):"
echo "  sudo /usr/local/sbin/add_token.sh \"alice\" \"bitresearch\" 3600"
echo "  (add_token.sh should call alloc_user_port.sh and regen_nginx_routes.sh)"
echo
echo "Done."
