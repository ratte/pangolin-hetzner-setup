#!/usr/bin/env bash
# pangolin-bootstrap – one-time setup on first boot (called by cloud-init).
# Managed by pangolin-hetzner-setup. Idempotent: running it again is safe.
set -euo pipefail

LOG=/var/log/pangolin-bootstrap.log
STATE_DIR=/var/lib/pangolin-setup
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date -Is)] $*"; }

# shellcheck source=/dev/null
source /etc/pangolin-setup/settings.env
: "${ADMIN_USER:?}" "${PANGOLIN_DIR:?}"
mkdir -p "$STATE_DIR"

log "== Start pangolin-bootstrap"

# --- SSH ---------------------------------------------------------------------
log "Moving SSH to port ${SSH_PORT:-2222}"
sshd -t
# Since 24.04, Ubuntu starts sshd via socket activation (ssh.socket, port 22).
# Switch to the classic ssh.service so that "Port" from sshd_config applies.
systemctl disable --now ssh.socket 2>/dev/null || true
rm -f /etc/systemd/system/ssh.service.d/00-socket.conf /etc/systemd/system/ssh.socket.d/addresses.conf
systemctl daemon-reload
systemctl enable ssh.service
systemctl restart ssh.service

# --- Firewall ----------------------------------------------------------------
log "Setting up the firewall (ufw)"
/usr/local/sbin/pangolin-firewall

# --- fail2ban ----------------------------------------------------------------
log "Enabling fail2ban"
touch /var/log/fail2ban.log
systemctl enable fail2ban
systemctl restart fail2ban

# --- Automatic security updates ----------------------------------------------
log "Enabling unattended-upgrades"
systemctl enable --now unattended-upgrades

# --- Docker ------------------------------------------------------------------
log "Enabling Docker"
systemctl enable --now docker
usermod -aG docker "$ADMIN_USER"

# --- Pangolin ----------------------------------------------------------------
cd "$PANGOLIN_DIR"
mkdir -p config/db config/letsencrypt config/traefik/logs

if grep -q '__SERVER_SECRET__' config/config.yml; then
  log "Generating the server secret"
  secret="$(openssl rand -hex 32)"
  sed -i "s|__SERVER_SECRET__|${secret}|" config/config.yml
  unset secret
fi
chmod 600 config/config.yml

if [[ ! -s .env ]]; then
  log "Generating the setup token"
  umask 077
  printf 'PANGOLIN_SETUP_TOKEN=%s\n' "$(openssl rand -hex 16)" > .env
fi
chmod 600 .env

log "Pulling container images"
for attempt in 1 2 3 4 5; do
  if docker compose pull --quiet; then
    break
  fi
  if [[ $attempt -eq 5 ]]; then
    log "ERROR: docker compose pull failed"
    exit 1
  fi
  log "Pull failed, retrying in 15s ($attempt/5)"
  sleep 15
done

log "Starting the Pangolin stack"
docker compose up -d

log "Waiting for Pangolin to become healthy (max. 5 min)"
for _ in $(seq 1 60); do
  status="$(docker inspect -f '{{.State.Health.Status}}' pangolin 2>/dev/null || echo unknown)"
  if [[ "$status" == "healthy" ]]; then
    log "Pangolin is healthy"
    break
  fi
  sleep 5
done
docker compose ps

touch "$STATE_DIR/bootstrap-done"
log "== pangolin-bootstrap finished"
