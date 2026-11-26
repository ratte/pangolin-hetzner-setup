#!/usr/bin/env bash
# pangolin-bootstrap – einmalige Einrichtung beim ersten Boot (von cloud-init aufgerufen).
# Verwaltet von pangolin-hetzner-setup. Idempotent: erneuter Aufruf ist unkritisch.
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
log "SSH-Konfiguration prüfen und neu laden"
sshd -t
systemctl restart ssh

# --- Firewall ----------------------------------------------------------------
log "Firewall (ufw) einrichten"
/usr/local/sbin/pangolin-firewall

# --- fail2ban ----------------------------------------------------------------
log "fail2ban aktivieren"
touch /var/log/fail2ban.log
systemctl enable fail2ban
systemctl restart fail2ban

# --- Automatische Sicherheitsupdates ------------------------------------------
log "unattended-upgrades aktivieren"
systemctl enable --now unattended-upgrades

# --- Docker ------------------------------------------------------------------
log "Docker aktivieren"
systemctl enable --now docker
usermod -aG docker "$ADMIN_USER"

# --- Pangolin ----------------------------------------------------------------
cd "$PANGOLIN_DIR"
mkdir -p config/db config/letsencrypt config/traefik/logs

if grep -q '__SERVER_SECRET__' config/config.yml; then
  log "Server-Secret erzeugen"
  secret="$(openssl rand -hex 32)"
  sed -i "s|__SERVER_SECRET__|${secret}|" config/config.yml
  unset secret
fi
chmod 600 config/config.yml

if [[ ! -s .env ]]; then
  log "Setup-Token erzeugen"
  umask 077
  printf 'PANGOLIN_SETUP_TOKEN=%s\n' "$(openssl rand -hex 16)" > .env
fi
chmod 600 .env

log "Container-Images laden"
for attempt in 1 2 3 4 5; do
  if docker compose pull --quiet; then
    break
  fi
  if [[ $attempt -eq 5 ]]; then
    log "FEHLER: docker compose pull fehlgeschlagen"
    exit 1
  fi
  log "Pull fehlgeschlagen, neuer Versuch in 15s ($attempt/5)"
  sleep 15
done

log "Pangolin-Stack starten"
docker compose up -d

log "Auf Health-Status von Pangolin warten (max. 5 min)"
for _ in $(seq 1 60); do
  status="$(docker inspect -f '{{.State.Health.Status}}' pangolin 2>/dev/null || echo unknown)"
  if [[ "$status" == "healthy" ]]; then
    log "Pangolin ist healthy"
    break
  fi
  sleep 5
done
docker compose ps

touch "$STATE_DIR/bootstrap-done"
log "== pangolin-bootstrap abgeschlossen"
