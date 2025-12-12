#!/usr/bin/env bash
set -euo pipefail

# regen_nginx_routes.sh
# Generates per-user nginx conf files under /etc/nginx/conf.d/users/
# based on mapping in /etc/tunnel/user_ports.json
#
# Usage: sudo /usr/local/bin/regen_nginx_routes.sh
# Exits non-zero if nginx -t fails (no reload will be performed).

MAPPING="/etc/tunnel/user_ports.json"
OUT_DIR="/etc/nginx/conf.d/users"
LOCK="/var/lock/regen_nginx_routes.lock"
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

python3 - "$MAPPING" "$OUT_DIR" <<'PY' > "$TMP_DIR/regen.stdout" 2> "$TMP_DIR/regen.stderr"
import json,sys,os,re,html
mapping_file=sys.argv[1]
out_dir=sys.argv[2]

# load map
with open(mapping_file,'r') as f:
    data=json.load(f)

users=data.get("users",{})
# normalize usernames to safe filenames (allow letters, numbers, -, _)
def safe_name(u):
    return re.sub(r'[^A-Za-z0-9_\-]', '_', u)

for user, port in users.items():
    user_str=str(user)
    fname = os.path.join(out_dir, safe_name(user_str) + ".conf")
    # Build an nginx location for this user that proxies /username/... -> 127.0.0.1:port$request_uri
    conf = f"""# Auto-generated for user: {user_str}
# Proxy /{user_str} and subpaths to local port {port}
location ^~ /{user_str} {{
    proxy_pass http://127.0.0.1:{port}$request_uri;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_read_timeout 300;
    proxy_buffering off;
}}
"""
    # Write to temp file (atomic replace later by shell)
    with open(fname + ".tmp", "w") as fh:
        fh.write(conf)
    # set safe perms
    os.chmod(fname + ".tmp", 0o640)
    # rename will be done by shell after this script finishes
    print(fname + ".tmp")
PY

# Move generated tmp files into final names (atomic-ish)
# python printed tmp paths, one per user
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

# Test nginx config before reload
if "$NGINX_BIN" -t >/dev/null 2>&1; then
  systemctl reload nginx
  echo "regen_nginx_routes: nginx reloaded successfully"
  exit 0
else
  echo "ERROR: nginx config test failed; not reloading. See nginx -t output below." >&2
  "$NGINX_BIN" -t || true
  exit 5
fi
