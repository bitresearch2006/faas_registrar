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
F_TUNNEL_CONF="$SRC_DIR/bitone.in"                  # ngnix configuration
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
# Use python -m pip to avoid depending on pip3 binary name
PY_BIN="$VENV_DIR/bin/python3"
PIP_CMD="$PY_BIN -m pip"

# ensure pip is available inside venv; try ensurepip as fallback
"$PY_BIN" -m ensurepip --upgrade || true


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
"$PIP_CMD" install --upgrade pip setuptools wheel
"$PIP_CMD" install --no-cache-dir flask

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

#
# ---------------------- Verification stage ----------------------
#
# This block performs post-install verification checks and prints a summary.
#
echo "--> Running post-install verification checks..."

VER_FAILED=0
VER_TOTAL=0
VER_PASSED=0

# helper: record check result
record_ok() { VER_TOTAL=$((VER_TOTAL+1)); VER_PASSED=$((VER_PASSED+1)); printf " [ OK ] %s\n" "$1"; }
record_fail() { VER_TOTAL=$((VER_TOTAL+1)); VER_FAILED=$((VER_FAILED+1)); printf " [FAIL] %s\n" "$1"; }

# check file exists and permissions (mode as octal string)
check_file_mode() {
  local path="$1"; local want_mode="$2"; local desc="$3"
  if [ -f "$path" ]; then
    # get actual mode (owner bits)
    actual_mode=$(stat -c "%a" "$path" 2>/dev/null || echo "000")
    if [ "$actual_mode" = "$want_mode" ]; then
      record_ok "$desc: $path (mode $actual_mode)"
    else
      record_fail "$desc: $path exists but mode is $actual_mode (expected $want_mode)"
    fi
  else
    record_fail "$desc: $path missing"
  fi
}

# check systemd service active/enabled
check_systemd_service() {
  local svc="$1"
  if systemctl is-enabled --quiet "$svc" && systemctl is-active --quiet "$svc"; then
    record_ok "systemd: $svc enabled & active"
  else
    # gather some info
    echo "   --- systemctl status $svc ---"
    systemctl --no-pager status "$svc" || true
    record_fail "systemd: $svc not enabled/active"
  fi
}

# check that nginx test is OK (we already tested earlier, re-run to be safe)
if nginx -t >/dev/null 2>&1; then
  record_ok "nginx config test"
else
  nginx -t || true
  record_fail "nginx config test failed"
fi

# check sign service systemd
check_systemd_service "sign_service.service"

# check that sign_service responds on the local /sign-cert path (expect 200 or 405 or 404 depending on method)
check_endpoint() {
  local url="http://127.0.0.1/sign-cert"
  # prefer curl, fall back to wget
  http_code=""
  if command -v curl >/dev/null 2>&1; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" || echo "")
  elif command -v wget >/dev/null 2>&1; then
    http_code=$(wget -qO- --timeout=3 --server-response "$url" 2>&1 | awk '/HTTP/{print $2; exit}' || echo "")
  else
    http_code=""
  fi

  if [ -z "$http_code" ]; then
    record_fail "sign_service endpoint: no response from $url"
  else
    case "$http_code" in
      200|201|204|405|404)
        record_ok "sign_service endpoint: $url responded with HTTP $http_code"
        ;;
      *)
        record_fail "sign_service endpoint: $url responded with HTTP $http_code"
        ;;
    esac
  fi
}
check_endpoint

# verify token file JSON parseable and permissions
if command -v jq >/dev/null 2>&1; then
  if [ -f "$TOKEN_FILE" ]; then
    if jq empty "$TOKEN_FILE" >/dev/null 2>&1; then
      record_ok "token JSON parseable: $TOKEN_FILE"
    else
      record_fail "token JSON invalid: $TOKEN_FILE"
    fi
  else
    record_fail "token file missing: $TOKEN_FILE"
  fi
else
  record_fail "jq not available to validate $TOKEN_FILE"
fi

# quick check user_ports.json parseable
if [ -f "$USER_PORTS" ]; then
  if jq empty "$USER_PORTS" >/dev/null 2>&1; then
    record_ok "user_ports JSON parseable: $USER_PORTS"
  else
    record_fail "user_ports JSON invalid: $USER_PORTS"
  fi
else
  record_fail "user_ports file missing: $USER_PORTS"
fi

# check trusted CA
if [ -f "$TRUSTED_CA" ]; then
  record_ok "trusted CA present: $TRUSTED_CA"
else
  record_fail "trusted CA missing: $TRUSTED_CA"
fi

# check presence and mode of critical installed files
check_file_mode "$SERVICE_PY" "700" "sign_service script"
check_file_mode "$SERVICE_UNIT" "644" "systemd unit"
check_file_mode "$ADD_TOKEN_DST" "700" "add_token script"
check_file_mode "$REVOKE_TOKEN_DST" "700" "revoke_token script"
check_file_mode "$ALLOC_PORT_DST" "700" "alloc_user_port script"
check_file_mode "$REGEN_NGINX_DST" "700" "regen_nginx_routes script"
check_file_mode "$REMOVE_PORT_DST" "700" "remove_user_port script"
check_file_mode "$LOGFILE" "600" "log file"

# check nginx users dir exists and is readable
if [ -d "$NGINX_USERS_DIR" ]; then
  record_ok "nginx users dir exists: $NGINX_USERS_DIR"
else
  record_fail "nginx users dir missing: $NGINX_USERS_DIR"
fi

# final summary
echo
echo "=== Verification summary ==="
echo "  Total checks: $VER_TOTAL"
echo "  Passed:       $VER_PASSED"
echo "  Failed:       $VER_FAILED"
echo

if [ "$VER_FAILED" -gt 0 ]; then
  echo "ERROR: some verification checks failed. Inspect the output above and fix the issues before relying on the service."
  # Non-zero exit to indicate failure for automation
  exit 4
else
  echo "All verification checks passed."
fi

#
# ---------------------- End verification ----------------------
#
echo "=== Installation finished ==="
echo "Token store: $TOKEN_FILE"
echo "User->port map: $USER_PORTS"
echo "Per-user nginx dir: $NGINX_USERS_DIR"
echo "Sign service: systemctl status sign_service.service"
echo "Admin helpers: $ADD_TOKEN_DST , $REVOKE_TOKEN_DST"
echo "Port allocator: $ALLOC_PORT_DST"
echo "Nginx regen: $REGEN_NGINX_DST"
echo "Remove port helper: $REMOVE_PORT_DST"
echo "Nginx snippet: $F_TUNNEL_CONF"
echo "Log: $LOGFILE"
echo
echo "Next steps (example):"
echo "  sudo /usr/local/sbin/add_token.sh \"alice\" \"bitresearch\" 3600"
echo "  (add_token.sh should call alloc_user_port.sh and regen_nginx_routes.sh)"
echo
echo "Done."
