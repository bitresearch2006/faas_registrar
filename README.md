# Tunnel Signer + Dynamic Reverse-Tunnel Router

This system provides automated, secure exposure of local services running on **WSL or Linux clients** to the public internet via a **central VM** using SSH reverse tunnels and dynamic Nginx routing.

The design follows a **token-based authentication model** with short-lived SSH certificates and strict per-user isolation.

---

## Features

* Token-based SSH certificate signing
* Automatic reverse tunnel from each client to the VM
* Dynamic per-user port allocation
* Automatic Nginx route generation
* Per-user subdomain routing
* Token revocation support
* Atomic configuration updates
* Strict localhost port binding

Each user can expose a local service as:

```
https://<username>.bitone.in
```

---

## Architecture Overview

### Identity Model

Each token defines:

* `name` → Subdomain name
* `principals` → Allowed SSH login identities
* `port` → Assigned reverse tunnel port
* `max_cert_ttl` → Maximum allowed certificate lifetime
* `active` → Whether token can be used

Mapping flow:

```
Token → Principal(s) → Port → Subdomain
```

---

## System Architecture

### 1. Client

Client:

* Requests certificate using token
* Receives signed SSH certificate
* Establishes reverse tunnel:

```bash
ssh -N -R 127.0.0.1:<assigned_port>:localhost:8080 principal@bitone.in
```

---

### 2. VM Components

| Component                        | Purpose                   |
| -------------------------------- | ------------------------- |
| `/etc/ssh/ca/`                   | SSH Certificate Authority |
| `sign_service.py`                | Certificate signing API   |
| `/etc/tunnel/tunnel_tokens.json` | Token store               |
| `/etc/tunnel/user_ports.json`    | Port mapping              |
| `regen_nginx_routes.sh`          | Nginx route generator     |

---

## Token Store Format

Example:

```json
{
  "tokens": {
    "<token>": {
      "name": "gitlab",
      "principals": ["bitresearch2006"],
      "port": 9002,
      "max_cert_ttl": 3600,
      "active": true
    }
  }
}
```

Validation rules:

* `name` must be non-empty
* `port` must exist
* No two active tokens may share a port
* `active` must be true to sign certificates

---

## API Specification

### POST /sign-cert

Request JSON:

```json
{
  "public_key": "ssh-ed25519 AAAA...",
  "token": "<token>"
}
```

Server validation:

* Token exists
* Token active
* Port assigned
* Name valid

Response:

```json
{
  "certificate": "ssh-ed25519-cert AAAA..."
}
```

Errors:

* 400 – Invalid request
* 401 – Invalid or inactive token

---

## Nginx Routing

For each active token:

```
server_name <name>.bitone.in;
proxy_pass http://127.0.0.1:<port>;
```

Routing regeneration ensures:

* Stale configs removed
* `nginx -t` validated before reload
* Safe atomic writes

---

## Setup Procedure

```bash
sudo bash setup_tunnel_signer.sh
```

Installer performs:

* Creates SSH CA
* Installs signing service
* Initializes token store
* Configures Nginx structure
* Enables systemd service

---

## Operational Workflow

### Add User

```bash
sudo add_token.sh "alice" "bitresearch2006" 3600
```

Returns:

* Token
* Assigned port

Client connects using returned principal.

---

### Revoke Token

```bash
sudo revoke_token.sh <token>
```

Actions:

* Marks token inactive
* Removes routing
* Reloads Nginx

---

## Token Inspection

Token store:

```
/etc/tunnel/tunnel_tokens.json
```

Examples:

```bash
jq . /etc/tunnel/tunnel_tokens.json
jq -r '.tokens | keys[]' /etc/tunnel/tunnel_tokens.json
jq -r '.tokens | to_entries[] | select(.value.active==true) | "\(.key) -> \(.value.name)"' \
  /etc/tunnel/tunnel_tokens.json
```

## Maintenance

### Remove Inactive Tokens

```bash
sudo jq '.tokens |= with_entries(select(.value.active==true))' \
  /etc/tunnel/tunnel_tokens.json > tmp && sudo mv tmp /etc/tunnel/tunnel_tokens.json
```

Restart signing service after modification:

```bash
sudo systemctl restart sign_service.service
```

---

## Security Guarantees

* Short-lived SSH certificates
* Token-based authorization
* Reverse tunnels bound to localhost
* No direct public port exposure
* Atomic config updates
* Revocation immediately disables signing

---

## Threat Model

* Tokens are secret and must not be shared
* Certificate TTL limits misuse window
* Port mapping prevents lateral access
* Only HTTPS is publicly exposed

---

## Conclusion

This system provides:

* Secure WSL → VM tunneling
* Per-user isolation
* Automatic routing
* Token-based authentication
* Operational safety for multi-user environments

Designed for scalable, secure remote service exposure.
