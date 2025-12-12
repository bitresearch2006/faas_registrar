#!/usr/bin/env python3
"""
sign_service.py - SSH cert signing service supporting multiple tokens.
Listens on 127.0.0.1:5001 by default. Exposes POST /sign-cert
Request JSON: { "pubkey": "...", "principal": "username", "ttl": 3600 }
Header: Authorization: Bearer <token>

Token store: /etc/tunnel/tunnel_tokens.json
CA private key: /etc/ssh/ca/ssh_ca
"""
from flask import Flask, request, jsonify, abort
import os, subprocess, tempfile, time, json, logging

app = Flask(__name__)

# CONFIG
TOKEN_FILE = "/etc/tunnel/tunnel_tokens.json"
CA_KEY = "/etc/ssh/ca/ssh_ca"
DEFAULT_TTL = 3600          # default if client doesn't provide ttl
GLOBAL_MAX_TTL = 31536000   # safety hard cap (1 year)
LOGFILE = "/var/log/tunnel_signer.log"

# Setup logging
logging.basicConfig(filename=LOGFILE,
                    level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")

def load_tokens():
    if not os.path.exists(TOKEN_FILE):
        return {}
    with open(TOKEN_FILE, "r") as f:
        try:
            data = json.load(f)
            return data.get("tokens", {})
        except Exception as e:
            logging.error("Failed to parse token file: %s", e)
            return {}

def authorize_token(bearer):
    tokens = load_tokens()
    entry = tokens.get(bearer)
    if not entry:
        return None
    if not entry.get("active", True):
        return None
    return entry

@app.route("/whoami", methods=["GET"])
def whoami():
    # require Authorization: Bearer <token>
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        logging.warning("Missing bearer token on /whoami from %s", request.remote_addr)
        abort(401)
    token = auth.split(None, 1)[1].strip()
    entry = authorize_token(token)
    if not entry:
        logging.warning("Unauthorized /whoami attempt from %s", request.remote_addr)
        abort(403)
    # return the name and allocated port for this token (if present)
    name = entry.get("name")
    port = entry.get("port")
    return jsonify({"name": name, "port": port}), 200

@app.route("/sign-cert", methods=["POST"])
def sign_cert():
    # Auth header
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        logging.warning("Missing bearer token from %s", request.remote_addr)
        abort(401)
    token = auth.split(None, 1)[1].strip()
    entry = authorize_token(token)
    if not entry:
        logging.warning("Unauthorized token attempt from %s", request.remote_addr)
        abort(403)

    # parse JSON
    data = request.get_json(force=True, silent=True)
    if not data or "pubkey" not in data or "principal" not in data:
        return jsonify({"error":"pubkey and principal required"}), 400

    pubkey = data["pubkey"].strip()
    principal = data["principal"].strip()
    ttl = int(data.get("ttl", DEFAULT_TTL))

    # check principal allowed
    allowed_principals = entry.get("principals", [])
    if principal not in allowed_principals:
        logging.warning("Principal not allowed: %s requested by token %s", principal, entry.get("name"))
        return jsonify({"error":"principal not allowed for this token"}), 403

    # check TTL limits: token-specific max_ttl then global cap
    token_max = int(entry.get("max_ttl", DEFAULT_TTL))
    if ttl <= 0:
        return jsonify({"error":"ttl must be positive"}), 400
    if ttl > token_max:
        return jsonify({"error":"ttl exceeds token max (%d seconds)" % token_max}), 400
    if ttl > GLOBAL_MAX_TTL:
        return jsonify({"error":"ttl exceeds global max (%d seconds)" % GLOBAL_MAX_TTL}), 400

    # write pubkey to temp file
    try:
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            pubfile = f.name
            f.write(pubkey + "\n")
        certfile = pubfile + "-cert.pub"
        ident = f"issued-{principal}-{int(time.time())}"
        cmd = [
            "ssh-keygen", "-s", CA_KEY,
            "-I", ident,
            "-n", principal,
            "-V", f"+{ttl}s",
            pubfile
        ]
        subprocess.check_output(cmd, stderr=subprocess.STDOUT)
        with open(certfile, "r") as cf:
            cert = cf.read()
        # logging
        logging.info("Issued cert for principal=%s token_name=%s ttl=%ds client_ip=%s",
                     principal, entry.get("name"), ttl, request.remote_addr)
        # cleanup temp files
        os.remove(pubfile)
        os.remove(certfile)
        return jsonify({"cert": cert}), 200
    except subprocess.CalledProcessError as e:
        out = e.output.decode() if hasattr(e, "output") else str(e)
        logging.error("Signing failed: %s", out)
        return jsonify({"error": "signing failed", "detail": out}), 500
    except Exception as e:
        logging.exception("Unexpected error")
        return jsonify({"error":"internal error"}), 500
    
if __name__ == "__main__":
    # bind to localhost only; run via systemd in production
    app.run(host="127.0.0.1", port=5001)
