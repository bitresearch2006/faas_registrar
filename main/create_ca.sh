#!/bin/bash
set -euo pipefail

CA_DIR=/etc/ssh/ca
mkdir -p "$CA_DIR"
chmod 700 "$CA_DIR"

# Create CA keypair (ed25519)
ssh-keygen -t ed25519 -f "$CA_DIR/ssh_ca" -C "vm-ssh-ca" -N ""

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

# Restart sshd
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart sshd || systemctl restart ssh
else
  service ssh restart
fi

echo "CA created: $CA_DIR/ssh_ca (private) and $CA_DIR/ssh_ca.pub (public)."
echo "TrustedUserCAKeys set to: $TRUSTED_USER_CA"

