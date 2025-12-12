#!/bin/bash
set -euo pipefail

CA_DIR=/etc/ssh/ca
mkdir -p "$CA_DIR"
chmod 700 "$CA_DIR"

# Create CA keypair (ed25519) only if missing
if [ ! -f "$CA_DIR/ssh_ca" ]; then
  echo "Generating new CA key..."
  ssh-keygen -t ed25519 -f "$CA_DIR/ssh_ca" -C "vm-ssh-ca" -N ""
else
  echo "CA key already exists at $CA_DIR/ssh_ca — skipping generation."
fi


# TrustedUserCAKeys file location
TRUSTED_USER_CA="/etc/ssh/trusted_user_ca_keys.pem"
cp "$CA_DIR/ssh_ca.pub" "$TRUSTED_USER_CA"
chmod 644 "$TRUSTED_USER_CA"

# Ensure sshd_config trusts the CA and allows tcp forwarding
SSHD_CONF=/etc/ssh/sshd_config
grep -q "^TrustedUserCAKeys" "$SSHD_CONF" || echo "TrustedUserCAKeys $TRUSTED_USER_CA" >> "$SSHD_CONF"
grep -q "^AllowTcpForwarding" "$SSHD_CONF" || echo "AllowTcpForwarding yes" >> "$SSHD_CONF"
# keep GatewayPorts no (safer) unless you want remote ports public
grep -q "^GatewayPorts" "$SSHD_CONF" || echo "GatewayPorts no" >> "$SSHD_CONF"

# Restart or start sshd safely
if [ ! -f "$SSHD_CONF" ]; then
  echo "WARNING: $SSHD_CONF not found. openssh-server may not be installed."
  echo "Install with: sudo apt install -y openssh-server"
else
  echo "Updating sshd config completed."
fi

# If systemd exists (Ubuntu proper)
if command -v systemctl >/dev/null 2>&1 && ps -p 1 -o comm= | grep -q systemd; then
  echo "Restarting sshd using systemctl..."
  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || \
    echo "systemctl restart failed — please check sshd status."
else
  # Non-systemd (WSL or minimal environments)
  if [ -x /usr/sbin/sshd ]; then
    echo "systemd not available — starting sshd manually..."
    /usr/sbin/sshd -t && /usr/sbin/sshd || echo "Failed to start sshd manually."
  else
    echo "ERROR: sshd not found. Install openssh-server."
  fi
fi


echo "CA created: $CA_DIR/ssh_ca (private) and $CA_DIR/ssh_ca.pub (public)."
echo "TrustedUserCAKeys set to: $TRUSTED_USER_CA"

