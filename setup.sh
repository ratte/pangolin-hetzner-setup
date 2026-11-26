#!/usr/bin/env bash
# Pangolin auf Hetzner Cloud – alles in einem Skript.
#
#   ./setup.sh [deploy]          Voraussetzungen, Server erstellen, warten, testen (Standard)
#   ./setup.sh requirements      Nur lokale Voraussetzungen installieren (requirements.md)
#   ./setup.sh plan              Geplante Änderungen anzeigen
#   ./setup.sh test              Funktionstest der laufenden Maschine
#   ./setup.sh token             Setup-Token und URL für den ersten Admin anzeigen
#   ./setup.sh ssh [befehl]      SSH auf den Server
#   ./setup.sh admin-access <netze|any>   SSH auf Netze einschränken (mit Auto-Rollback)
#   ./setup.sh backup            Pangolin-Konfiguration/Datenbank sichern (nach .state/backups)
#   ./setup.sh update            Container auf die Versionen aus .env aktualisieren
#   ./setup.sh recreate          Server neu aufsetzen (Daten gehen verloren – vorher backup!)
#   ./setup.sh destroy           Server und verwaltete SSH-Keys löschen
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

confirm() { # confirm "Frage"
  [[ "${AUTO_APPROVE:-false}" == "true" ]] && return 0
  local answer
  read -r -p "$1 [j/N] " answer
  [[ "$answer" =~ ^[jJyY]$ ]]
}

tf_apply() {
  local args=("$@")
  [[ "${AUTO_APPROVE:-false}" == "true" ]] && args+=(-auto-approve)
  tf apply "${args[@]}"
}

wait_for_ssh() {
  info "Warte auf SSH-Zugang als ${ADMIN_USER}@$(server_ip):$(server_ssh_port) (max. 10 min)"
  local deadline=$((SECONDS + 600))
  until remote true 2>/dev/null; do
    (( SECONDS < deadline )) || die "SSH nicht erreichbar. Passt dein lokaler privater Key zu den angegebenen öffentlichen Keys? (SSH_KEY_FILE in .env)"
    sleep 10
  done
  ok "SSH erreichbar"
}

wait_for_cloud_init() {
  info "Warte auf cloud-init und Bootstrap (Pakete, Docker, Pangolin – dauert einige Minuten)"
  local deadline=$((SECONDS + 1200)) rc
  while true; do
    rc=0
    remote 'sudo cloud-init status --wait >/dev/null 2>&1; echo "rc=$?"' 2>/dev/null | grep -q '^rc=[02]$' || rc=1
    if (( rc == 0 )) && remote 'test -f /var/lib/pangolin-setup/bootstrap-done' 2>/dev/null; then
      break
    fi
    if remote 'sudo cloud-init status 2>/dev/null | grep -q "status: error"' 2>/dev/null; then
      warn "cloud-init meldet einen Fehler. Letzte Zeilen des Bootstrap-Logs:"
      remote 'sudo tail -n 30 /var/log/pangolin-bootstrap.log' || true
      die "Details: ./setup.sh ssh 'sudo cloud-init status --long; sudo less /var/log/cloud-init-output.log'"
    fi
    (( SECONDS < deadline )) || die "Zeitüberschreitung beim Warten auf cloud-init."
    sleep 10
  done
  ok "Server eingerichtet"
}

wait_for_dns() {
  local ip ip6 a aaaa deadline
  ip="$(server_ip)"; ip6="$(server_ip6)"
  deadline=$((SECONDS + ${DNS_WAIT_TIMEOUT:-1800}))
  info "DNS prüfen: ${DASHBOARD_DOMAIN} muss auf ${ip} zeigen"
  while true; do
    a="$(resolve_a "$DASHBOARD_DOMAIN" | xargs)"
    if grep -qw -- "$ip" <<<"$a"; then
      ok "A-Record korrekt: ${DASHBOARD_DOMAIN} → ${ip}"
      break
    fi
    if (( SECONDS >= deadline )); then
      warn "DNS zeigt noch nicht auf den Server (gefunden: ${a:-nichts}). Zertifikat folgt, sobald DNS stimmt."
      return 1
    fi
    echo "    Bitte jetzt beim DNS-Anbieter setzen:"
    echo "      ${DASHBOARD_DOMAIN}.   A     ${ip}"
    echo "      ${DASHBOARD_DOMAIN}.   AAAA  ${ip6}   (optional)"
    echo "      *.${BASE_DOMAIN}.   A     ${ip}   (für Ressourcen, empfohlen)"
    echo "    Aktuell: ${a:-kein A-Record}. Neue Prüfung in 30s … (Abbruch mit Ctrl+C, später './setup.sh test')"
    sleep 30
  done
  aaaa="$(resolve_aaaa "$DASHBOARD_DOMAIN" | xargs)"
  if [[ -n "$aaaa" ]] && ! grep -qiw -- "$ip6" <<<"$aaaa"; then
    warn "AAAA-Record zeigt auf ${aaaa} statt ${ip6} – Let's Encrypt kann daran scheitern!"
  fi
}

wait_for_cert() {
  info "Warte auf Let's-Encrypt-Zertifikat für ${DASHBOARD_DOMAIN} (max. 10 min)"
  local deadline=$((SECONDS + 600)) restarted=false start=$SECONDS
  until curl -fsS -o /dev/null --max-time 10 "https://${DASHBOARD_DOMAIN}/api/v1/" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      warn "Noch kein gültiges Zertifikat. Logs: ./setup.sh ssh 'sudo docker logs traefik'"
      return 1
    fi
    if [[ "$restarted" == false ]] && (( SECONDS - start > 180 )); then
      warn "Starte Traefik neu, um die Zertifikatsanfrage zu wiederholen"
      remote 'sudo docker restart traefik >/dev/null' || true
      restarted=true
    fi
    sleep 10
  done
  ok "HTTPS mit gültigem Zertifikat erreichbar"
}

show_token() {
  local token
  token="$(remote "sudo sed -n 's/^PANGOLIN_SETUP_TOKEN=//p' /opt/pangolin/.env")"
  [[ -n "$token" ]] || die "Setup-Token nicht gefunden."
  echo
  info "Ersten Admin anlegen"
  echo "    URL:         https://${DASHBOARD_DOMAIN}/auth/initial-setup"
  echo "    Setup-Token: ${token}"
  echo "    (Der Token ist nur bis zur Erstellung des ersten Admins gültig.)"
}

# Benutzername für den neuen Server abfragen (Vorschlag aus .env, Standard "peng").
prompt_admin_user() {
  local user="${ADMIN_USER:-peng}" answer
  if [[ "${AUTO_APPROVE:-false}" == "true" || ! -t 0 ]]; then
    info "Server-Benutzer: ${user}"
  else
    while true; do
      read -r -p "Benutzername für den Server [${user}]: " answer
      answer="${answer:-$user}"
      if valid_username "$answer"; then user="$answer"; break; fi
      warn "Ungültig: Kleinbuchstaben, Ziffern, '_' und '-', max. 32 Zeichen, nicht root."
    done
  fi
  valid_username "$user" || die "Ungültiger Benutzername in .env: ${user}"
  if [[ "$user" != "$(sed -n 's/^ADMIN_USER=//p' "$ENV_FILE" | tail -n1)" ]]; then
    set_env_value ADMIN_USER "$user"
    ok "ADMIN_USER=${user} in .env gespeichert"
  fi
  ADMIN_USER="$user"
  export TF_VAR_admin_user="$user"
}

# SSH-Key-Quelle für den neuen Server abfragen: GitHub-Benutzer oder eigener Key.
prompt_ssh_keys() {
  if [[ "${AUTO_APPROVE:-false}" == "true" || ! -t 0 ]]; then
    [[ -n "${GITHUB_USER:-}${SSH_PUBLIC_KEY:-}" ]] \
      || die "Kein SSH-Key: GITHUB_USER oder SSH_PUBLIC_KEY in .env setzen (oder interaktiv starten)."
    [[ -n "${GITHUB_USER:-}" ]] && info "SSH-Keys von github.com/${GITHUB_USER}.keys"
    [[ -n "${SSH_PUBLIC_KEY:-}" ]] && info "SSH-Key aus .env: $(pubkey_fingerprint "$SSH_PUBLIC_KEY")"
    export_ssh_key_vars
    return
  fi

  local default_choice=1 choice answer count input key keyfile="" default_input
  [[ -n "${SSH_PUBLIC_KEY:-}" && -z "${GITHUB_USER:-}" ]] && default_choice=2
  echo
  info "Woher kommt der SSH-Key für den Server?"
  echo "    1) Öffentliche Keys eines GitHub-Benutzers (github.com/<benutzer>.keys)"
  echo "    2) Eigener öffentlicher Key (Pfad zur .pub-Datei oder Key einfügen)"
  while true; do
    read -r -p "Auswahl [${default_choice}]: " choice
    choice="${choice:-$default_choice}"
    [[ "$choice" == 1 || "$choice" == 2 ]] && break
    warn "Bitte 1 oder 2 eingeben."
  done

  if [[ "$choice" == 1 ]]; then
    while true; do
      read -r -p "GitHub-Benutzername${GITHUB_USER:+ [${GITHUB_USER}]}: " answer
      answer="${answer:-${GITHUB_USER:-}}"
      if ! valid_github_user "$answer"; then warn "Ungültiger GitHub-Benutzername."; continue; fi
      count="$(github_key_count "$answer")"
      if (( count > 0 )); then ok "${count} öffentliche(r) Key(s) unter github.com/${answer}.keys"; break; fi
      warn "Unter https://github.com/${answer}.keys wurden keine Keys gefunden."
    done
    GITHUB_USER="$answer"; SSH_PUBLIC_KEY=""
  else
    default_input=""
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
      default_input="aus .env"
    else
      for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
        [[ -f "$f" ]] && { default_input="$f"; break; }
      done
    fi
    while true; do
      read -r -p "Pfad zur .pub-Datei oder Key einfügen${default_input:+ [${default_input}]}: " input
      input="${input:-$default_input}"
      keyfile=""
      if [[ "$input" == "aus .env" ]]; then
        key="$(normalize_pubkey "$SSH_PUBLIC_KEY")"
      else
        input="${input/#\~/$HOME}"
        if [[ -f "$input" ]]; then keyfile="$input"; key="$(normalize_pubkey "$(head -n1 "$input")")"
        else key="$(normalize_pubkey "$input")"; fi
      fi
      if valid_pubkey "$key"; then ok "Key: $(pubkey_fingerprint "$key")"; break; fi
      warn "Kein gültiger öffentlicher SSH-Key (erwartet z. B. 'ssh-ed25519 AAAA…' oder eine .pub-Datei)."
    done
    SSH_PUBLIC_KEY="$key"; GITHUB_USER=""
    # Passenden privaten Key automatisch für die Verbindung verwenden.
    if [[ -n "$keyfile" && "$keyfile" == *.pub && -f "${keyfile%.pub}" && -z "${SSH_KEY_FILE:-}" ]]; then
      SSH_KEY_FILE="${keyfile%.pub}"
      set_env_value SSH_KEY_FILE "$SSH_KEY_FILE"
      ok "SSH_KEY_FILE=${SSH_KEY_FILE} in .env gespeichert"
    fi
  fi

  set_env_value GITHUB_USER "${GITHUB_USER}"
  set_env_value SSH_PUBLIC_KEY "\"${SSH_PUBLIC_KEY}\""
  ok "SSH-Key-Quelle in .env gespeichert"
  export_ssh_key_vars
}

cmd_deploy() {
  if [[ "${SKIP_REQUIREMENTS:-false}" != "true" ]]; then
    bash "$REPO_DIR/scripts/install-requirements.sh"
  fi
  load_env
  require_cmd ssh curl dig nc jq openssl
  info "OpenTofu initialisieren"
  tf init -input=false -upgrade >/dev/null
  ok "Provider bereit"
  if [[ -z "$(server_id)" ]]; then
    prompt_admin_user
    prompt_ssh_keys
  else
    info "Bestehender Server, Benutzer: ${ADMIN_USER}"
    [[ -n "${GITHUB_USER:-}${SSH_PUBLIC_KEY:-}" ]] || prompt_ssh_keys
  fi
  info "Infrastruktur anlegen/aktualisieren"
  tf_apply -input=false
  ok "Server: $(server_ip) / $(server_ip6)"

  wait_for_ssh
  wait_for_cloud_init
  local dns_ok=true cert_ok=true
  wait_for_dns || dns_ok=false
  if [[ "$dns_ok" == true ]]; then wait_for_cert || cert_ok=false; else cert_ok=false; fi

  show_token
  echo
  info "Funktionstest"
  local test_rc=0
  bash "$REPO_DIR/scripts/test-server.sh" || test_rc=$?
  echo
  if [[ "$cert_ok" == false ]]; then
    warn "DNS/Zertifikat noch nicht bereit – nach dem DNS-Eintrag './setup.sh test' erneut ausführen."
  fi
  info "Fertig. SSH: ./setup.sh ssh   |   Dashboard: https://${DASHBOARD_DOMAIN}"
  return "$test_rc"
}

cmd_admin_access() {
  load_env
  local nets="${*:-}"
  [[ -n "$nets" ]] || die "Verwendung: ./setup.sh admin-access \"203.0.113.10/32 [weitere]\" | any"
  warn "SSH wird auf folgende Netze beschränkt: ${nets}"
  local myip
  myip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$myip" ]] && echo "    Deine aktuelle öffentliche IPv4: ${myip}"
  confirm "Fortfahren?" || die "Abgebrochen."
  remote "sudo pangolin-admin-access set $(printf '%q' "$nets")"
  sleep 3
  info "Prüfe Zugang mit neuer Verbindung"
  if remote 'sudo pangolin-admin-access confirm'; then
    ok "Neue Regeln bestätigt"
  else
    die "Kein Zugang mit den neuen Regeln – sie werden in ~3 Minuten automatisch zurückgerollt."
  fi
}

cmd_backup() {
  load_env
  local dir="$STATE_DIR/backups" file
  mkdir -p "$dir"
  chmod 700 "$dir"
  file="$dir/pangolin-$(date +%Y%m%d-%H%M%S).tar.gz"
  info "Sichere /opt/pangolin (Pangolin wird dafür kurz gestoppt)"
  remote 'cd /opt/pangolin && sudo docker compose stop pangolin >/dev/null 2>&1; sudo tar -czf - docker-compose.yml .env config; rc=$?; sudo docker compose start pangolin >/dev/null 2>&1; exit $rc' > "$file"
  chmod 600 "$file"
  ok "Backup: $file ($(du -h "$file" | cut -f1))"
}

cmd_update() {
  load_env
  local pv="${PANGOLIN_VERSION:-}" gv="${GERBIL_VERSION:-}" tv="${TRAEFIK_VERSION:-}"
  [[ -n "$pv$gv$tv" ]] || die "PANGOLIN_VERSION / GERBIL_VERSION / TRAEFIK_VERSION in .env setzen."
  local re='^[A-Za-z0-9._-]*$'
  [[ "$pv" =~ $re && "$gv" =~ $re && "$tv" =~ $re ]] || die "Ungültige Versionsangabe."
  confirm "Vorher Backup erstellen?" && cmd_backup
  info "Aktualisiere Container (pangolin=${pv:-unverändert}, gerbil=${gv:-unverändert}, traefik=${tv:-unverändert})"
  remote "set -e; cd /opt/pangolin
    [ -n '$pv' ] && sudo sed -i 's|\(image: docker.io/fosrl/pangolin:\).*|\1$pv|' docker-compose.yml
    [ -n '$gv' ] && sudo sed -i 's|\(image: docker.io/fosrl/gerbil:\).*|\1$gv|' docker-compose.yml
    [ -n '$tv' ] && sudo sed -i 's|\(image: docker.io/traefik:\).*|\1$tv|' docker-compose.yml
    sudo docker compose pull --quiet && sudo docker compose up -d && sudo docker compose ps"
  ok "Update abgeschlossen – Test: ./setup.sh test"
}

cmd_recreate() {
  load_env
  warn "Der Server wird gelöscht und neu erstellt. Alle Pangolin-Daten gehen verloren!"
  confirm "Wirklich neu aufsetzen?" || die "Abgebrochen."
  tf init -input=false >/dev/null
  prompt_admin_user
  prompt_ssh_keys
  tf_apply -input=false -replace=hcloud_server.pangolin
  SKIP_REQUIREMENTS=true cmd_deploy
}

cmd_destroy() {
  load_env
  warn "Server $(server_ip 2>/dev/null || echo '?') und alle verwalteten SSH-Keys werden gelöscht."
  confirm "Wirklich löschen?" || die "Abgebrochen."
  tf init -input=false >/dev/null
  local args=(-input=false)
  [[ "${AUTO_APPROVE:-false}" == "true" ]] && args+=(-auto-approve)
  tf destroy "${args[@]}"
  ok "Gelöscht"
}

main() {
  local cmd="${1:-deploy}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    deploy)        cmd_deploy ;;
    requirements)  bash "$REPO_DIR/scripts/install-requirements.sh" ;;
    plan)          load_env; tf init -input=false >/dev/null; tf plan -input=false ;;
    test)          bash "$REPO_DIR/scripts/test-server.sh" ;;
    token)         load_env; show_token ;;
    ssh)           load_env; ssh_opts; exec ssh "${SSH_OPTS[@]/BatchMode=yes/BatchMode=no}" "${ADMIN_USER}@$(server_ip)" "$@" ;;
    admin-access)  cmd_admin_access "$@" ;;
    backup)        cmd_backup ;;
    update)        cmd_update ;;
    recreate)      cmd_recreate ;;
    destroy)       cmd_destroy ;;
    -h|--help|help) usage ;;
    *)             usage; exit 2 ;;
  esac
}

main "$@"
