#!/usr/bin/env bash
# pangolin-firewall – host firewall (ufw) for the Pangolin node.
# Managed by pangolin-hetzner-setup. Idempotent, can be run again at any time.
#
# Public: 80/tcp, 443/tcp, 443/udp (HTTP/3), 51820/udp and 21820/udp (WireGuard).
# SSH (SSH_PORT/tcp, default 2222): from ADMIN_CIDRS in /etc/pangolin-setup/settings.env ("any" = everywhere).
#
# Note: Docker publishes container ports through its own iptables rules, bypassing
# ufw. The ufw rules for 80/443/51820/21820 are set anyway (IPv6 via docker-proxy,
# clarity). Internal ports (3000–3004, 8080) are not published.
set -euo pipefail

SETTINGS=/etc/pangolin-setup/settings.env
[[ -r "$SETTINGS" ]] || { echo "Missing: $SETTINGS" >&2; exit 1; }
# shellcheck source=/dev/null
source "$SETTINGS"
: "${ADMIN_CIDRS:?ADMIN_CIDRS not set}"
SSH_PORT="${SSH_PORT:-2222}"

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Remove previous admin rules (highest number first).
mapfile -t old_rules < <(ufw status numbered 2>/dev/null \
  | awk -F'[][]' '/# admin-ssh/ { gsub(/ /, "", $2); print $2 }' | sort -rn)
for n in "${old_rules[@]}"; do
  ufw --force delete "$n" >/dev/null
done

# Admin access (SSH)
for cidr in $ADMIN_CIDRS; do
  if [[ "$cidr" == "any" ]]; then
    ufw allow "${SSH_PORT}/tcp" comment 'admin-ssh' >/dev/null
  else
    ufw allow from "$cidr" to any port "$SSH_PORT" proto tcp comment 'admin-ssh' >/dev/null
  fi
done

# Public Pangolin services
ufw allow 80/tcp comment 'pangolin-http' >/dev/null
ufw allow 443/tcp comment 'pangolin-https' >/dev/null
ufw allow 443/udp comment 'pangolin-http3' >/dev/null
ufw allow 51820/udp comment 'pangolin-gerbil-wg' >/dev/null
ufw allow 21820/udp comment 'pangolin-clients-wg' >/dev/null

ufw --force enable >/dev/null
ufw status verbose
