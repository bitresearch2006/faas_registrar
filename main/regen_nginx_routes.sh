#!/usr/bin/env bash
set -euo pipefail

# regen_nginx_routes.sh
# Generates per-user nginx conf files under /etc/nginx/conf.d/users/
# based on mapping in /etc/tunnel/user_ports.json
#
# Usage: sudo /usr/local/bin/regen_nginx_routes.sh
# Exits non-zero if nginx -t fails (no reload will be performed).

MAPPING="/etc/tunnel/user_ports.json"
OUT_DIR="/etc/nginx/conf.d"
LOCK="/var/lock/regen_nginx_routes.lock"
SUBDOMAINS_FILE="/etc/tunnel/subdomains.txt"
EMAIL="bitresearch2006@gmail.com"
CERT_NAME="bitone.in"
NGINX_BIN="$(command -v nginx || true)"

if [ -z "$NGINX_BIN" ]; then
  echo "nginx not found in PATH" >&2
  exit 2
fi

if [ ! -f "$MAPPING" ]; then
  echo "Mapping file not found: $MAPPING" >&2
  exit 3
fi

mkdir -p "$OUT_DIR"
chown root:root "$OUT_DIR"
chmod 750 "$OUT_DIR"

# Acquire lock to avoid concurrent runs
exec 9>"$LOCK"
if ! flock -n 9 ; then
  echo "Another regen is in progress, exiting." >&2
  exit 4
fi

# Read mapping and write per-user files
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; flock -u 9' EXIT

# -----------------------------------------------------------------------------
# PYTHON SCRIPT START
# -----------------------------------------------------------------------------
python3 - "$MAPPING" "$OUT_DIR" <<'PY' > "$TMP_DIR/regen.stdout" 2> "$TMP_DIR/regen.stderr"
import json,sys,os,re

mapping_file=sys.argv[1]
out_dir=sys.argv[2]

with open(mapping_file,'r') as f:
    data=json.load(f)

users=data.get("users",{})

def safe_name(u):
    return re.sub(r'[^A-Za-z0-9_\-]', '_', u)

for user, port in users.items():
    user_str = str(user)
    name = safe_name(user_str)
    fname = os.path.join(out_dir, name + ".conf")

    conf = f"""# Auto-generated for user: {user_str}
server {{
    listen 443 ssl http2;
    server_name {name}.bitone.in;

    include /etc/nginx/snippets/bitone_ssl.conf;

    location / {{
        proxy_pass http://127.0.0.1:{port};
        include /etc/nginx/snippets/bitone_proxy.conf;
    }}

    access_log /var/log/nginx/{name}.bitone.in.access.log;
    error_log  /var/log/nginx/{name}.bitone.in.error.log warn;
}}
"""
    with open(fname + ".tmp", "w") as fh:
        fh.write(conf)
    os.chmod(fname + ".tmp", 0o640)
    print(fname + ".tmp")
PY
# -----------------------------------------------------------------------------
# PYTHON SCRIPT END
# -----------------------------------------------------------------------------

# Move generated tmp files into final names (atomic-ish)
while IFS= read -r tmpf; do
  final="${tmpf%'.tmp'}"
  mv -f "$tmpf" "$final"
  chown root:root "$final"
  chmod 0640 "$final"
done < "$TMP_DIR/regen.stdout"

# Remove stale files: any file in OUT_DIR not in mapping -> delete
# Build list of desired files
python3 - "$MAPPING" "$OUT_DIR" <<'PY' > "$TMP_DIR/desired.list"
import json,sys,os,re
mapping_file=sys.argv[1]
out_dir=sys.argv[2]
data=json.load(open(mapping_file))
users=data.get("users",{})
def safe_name(u):
    return re.sub(r'[^A-Za-z0-9_\\-]', '_', u)
for u in users.keys():
    print(os.path.join(out_dir, safe_name(u) + ".conf"))
PY

# remove files that exist but not desired
find "$OUT_DIR" -maxdepth 1 -type f -name '*.conf' > "$TMP_DIR/existing.list"
comm -23 <(sort "$TMP_DIR/existing.list") <(sort "$TMP_DIR/desired.list") > "$TMP_DIR/to_delete.list" || true
if [ -s "$TMP_DIR/to_delete.list" ]; then
  while IFS= read -r del; do
    # safety: only delete inside OUT_DIR
    if [[ "$del" == "$OUT_DIR/"* ]]; then
      rm -f "$del"
    fi
  done < "$TMP_DIR/to_delete.list"
fi

# -----------------------------------------------------------------------------
# Update subdomains.txt (for certificate issuance)
# -----------------------------------------------------------------------------
python3 - "$MAPPING" "$SUBDOMAINS_FILE" <<'PY'
import json,sys,re
mapping_file=sys.argv[1]
outfile=sys.argv[2]
data=json.load(open(mapping_file))
users=data.get("users",{})
def safe_name(u):
    return re.sub(r'[^A-Za-z0-9_\-]', '_', u)
names = [f"{safe_name(u)}.bitone.in" for u in users.keys()]
names.insert(0,"bitone.in")  # always include root domain
names.insert(1,"www.bitone.in")	# always include root domain
with open(outfile,"w") as fh:
    for n in sorted(set(names)):
        fh.write(n+"\n")
PY

# Test nginx config before reload
if "$NGINX_BIN" -t >/dev/null 2>&1; then
  systemctl reload nginx
  echo "regen_nginx_routes: nginx reloaded successfully"

  # -----------------------------------------------------------------------------
  # Re-issue certificate with all subdomains
  # -----------------------------------------------------------------------------
  # Only re-issue if subdomains.txt changed
  touch "$SUBDOMAINS_FILE.prev"
  if ! cmp -s "$SUBDOMAINS_FILE" "$SUBDOMAINS_FILE.prev"; then
    cp "$SUBDOMAINS_FILE" "$SUBDOMAINS_FILE.prev"
  #
  # === Why we allow Certbot to print an installer error (and ignore it) ===
  #
  # Our system uses ONE unified certificate for all subdomains.
  # Every subdomain server block includes the same SSL snippet:
  #
  #     include /etc/nginx/snippets/bitone_ssl.conf;
  #
  # That snippet always points to:
  #     /etc/letsencrypt/live/bitone.in/fullchain.pem
  #     /etc/letsencrypt/live/bitone.in/privkey.pem
  #
  # Certbot normally tries to "install" certificates into Nginx, but it only
  # scans /etc/nginx/sites-enabled/. Our dynamic subdomain configs live in
  # /etc/nginx/conf.d/users/, so Certbot cannot find them and prints:
  #
  #     "Could not automatically find a matching server block"
  #
  # This message is harmless because Nginx already loads the correct
  # certificate through the shared SSL snippet. Certbot's installer step is
  # not needed for our architecture.
  #
  # We keep using `certbot --nginx` for authentication, and we append `|| true`
  # to suppress the installer warning while still issuing the certificate.
  #
    certbot --nginx \
      $(awk '{print "-d",$0}' "$SUBDOMAINS_FILE") \
      --cert-name "$CERT_NAME" \
      --non-interactive --agree-tos -m "$EMAIL" --force-renewal || true

  fi

  exit 0
else
  echo "ERROR: nginx config test failed; not reloading. See nginx -t output below." >&2
  "$NGINX_BIN" -t || true
  exit 5
fi
