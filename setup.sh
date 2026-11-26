#!/usr/bin/env bash
# Pangolin on Hetzner Cloud – everything in one script.
#
#   ./setup.sh [deploy]          Requirements, create server, wait, test (default)
#   ./setup.sh requirements      Install local requirements only (requirements.md)
#   ./setup.sh plan              Show planned changes
#   ./setup.sh test              Test the running machine
#   ./setup.sh token             Show setup token and URL for the first admin
#   ./setup.sh ssh [command]     SSH into the server
#   ./setup.sh admin-access <networks|any>   Restrict SSH to networks (with auto-rollback)
#   ./setup.sh backup            Back up Pangolin config/database (to .state/backups)
#   ./setup.sh update            Update containers to the versions in .env
#   ./setup.sh recreate          Rebuild the server (data is lost – run backup first!)
#   ./setup.sh destroy           Delete the server and managed SSH keys
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

confirm() { # confirm "question"
  [[ "${AUTO_APPROVE:-false}" == "true" ]] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[yY]$ ]]
}

tf_apply() {
  local args=("$@")
  [[ "${AUTO_APPROVE:-false}" == "true" ]] && args+=(-auto-approve)
  tf apply "${args[@]}"
}

wait_for_ssh() {
  info "Waiting for SSH access as ${ADMIN_USER}@$(server_ip):$(server_ssh_port) (max. 10 min)"
  local deadline=$((SECONDS + 600))
  until remote true 2>/dev/null; do
    (( SECONDS < deadline )) || die "SSH not reachable. Does your local private key match the configured public keys? (SSH_KEY_FILE in .env)"
    sleep 10
  done
  ok "SSH reachable"
}

wait_for_cloud_init() {
  info "Waiting for cloud-init and bootstrap (packages, Docker, Pangolin – takes a few minutes)"
  local deadline=$((SECONDS + 1200)) rc
  while true; do
    rc=0
    remote 'sudo cloud-init status --wait >/dev/null 2>&1; echo "rc=$?"' 2>/dev/null | grep -q '^rc=[02]$' || rc=1
    if (( rc == 0 )) && remote 'test -f /var/lib/pangolin-setup/bootstrap-done' 2>/dev/null; then
      break
    fi
    if remote 'sudo cloud-init status 2>/dev/null | grep -q "status: error"' 2>/dev/null; then
      warn "cloud-init reports an error. Last lines of the bootstrap log:"
      remote 'sudo tail -n 30 /var/log/pangolin-bootstrap.log' || true
      die "Details: ./setup.sh ssh 'sudo cloud-init status --long; sudo less /var/log/cloud-init-output.log'"
    fi
    (( SECONDS < deadline )) || die "Timed out waiting for cloud-init."
    sleep 10
  done
  ok "Server set up"
}

wait_for_dns() {
  local ip ip6 a aaaa deadline
  ip="$(server_ip)"; ip6="$(server_ip6)"
  deadline=$((SECONDS + ${DNS_WAIT_TIMEOUT:-1800}))
  info "Checking DNS: ${DASHBOARD_DOMAIN} must point to ${ip}"
  while true; do
    a="$(resolve_a "$DASHBOARD_DOMAIN" | xargs)"
    if grep -qw -- "$ip" <<<"$a"; then
      ok "A record correct: ${DASHBOARD_DOMAIN} → ${ip}"
      break
    fi
    if (( SECONDS >= deadline )); then
      warn "DNS does not point to the server yet (found: ${a:-nothing}). The certificate follows once DNS is correct."
      return 1
    fi
    echo "    Please set these records at your DNS provider now:"
    echo "      ${DASHBOARD_DOMAIN}.   A     ${ip}"
    echo "      ${DASHBOARD_DOMAIN}.   AAAA  ${ip6}   (optional)"
    echo "      *.${BASE_DOMAIN}.   A     ${ip}   (for resources, recommended)"
    echo "    Currently: ${a:-no A record}. Checking again in 30s … (abort with Ctrl+C, later './setup.sh test')"
    sleep 30
  done
  aaaa="$(resolve_aaaa "$DASHBOARD_DOMAIN" | xargs)"
  if [[ -n "$aaaa" ]] && ! grep -qiw -- "$ip6" <<<"$aaaa"; then
    warn "AAAA record points to ${aaaa} instead of ${ip6} – Let's Encrypt may fail because of this!"
  fi
}

wait_for_cert() {
  info "Waiting for the Let's Encrypt certificate for ${DASHBOARD_DOMAIN} (max. 10 min)"
  local deadline=$((SECONDS + 600)) restarted=false start=$SECONDS
  until curl -fsS -o /dev/null --max-time 10 "https://${DASHBOARD_DOMAIN}/api/v1/" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      warn "No valid certificate yet. Logs: ./setup.sh ssh 'sudo docker logs traefik'"
      return 1
    fi
    if [[ "$restarted" == false ]] && (( SECONDS - start > 180 )); then
      warn "Restarting Traefik to retry the certificate request"
      remote 'sudo docker restart traefik >/dev/null' || true
      restarted=true
    fi
    sleep 10
  done
  ok "HTTPS reachable with a valid certificate"
}

show_token() {
  local token
  token="$(remote "sudo sed -n 's/^PANGOLIN_SETUP_TOKEN=//p' /opt/pangolin/.env")"
  [[ -n "$token" ]] || die "Setup token not found."
  echo
  info "Create the first admin"
  echo "    URL:         https://${DASHBOARD_DOMAIN}/auth/initial-setup"
  echo "    Setup token: ${token}"
  echo "    (The token is only valid until the first admin has been created.)"
}

# Ask for the username on the new server (suggestion from .env, default "peng").
prompt_admin_user() {
  local user="${ADMIN_USER:-peng}" answer
  if [[ "${AUTO_APPROVE:-false}" == "true" || ! -t 0 ]]; then
    info "Server user: ${user}"
  else
    while true; do
      read -r -p "Username on the server [${user}]: " answer
      answer="${answer:-$user}"
      if valid_username "$answer"; then user="$answer"; break; fi
      warn "Invalid: lowercase letters, digits, '_' and '-', max. 32 characters, not root."
    done
  fi
  valid_username "$user" || die "Invalid username in .env: ${user}"
  if [[ "$user" != "$(sed -n 's/^ADMIN_USER=//p' "$ENV_FILE" | tail -n1)" ]]; then
    set_env_value ADMIN_USER "$user"
    ok "ADMIN_USER=${user} saved to .env"
  fi
  ADMIN_USER="$user"
  export TF_VAR_admin_user="$user"
}

# Ask for the SSH key source for the new server: GitHub user or own key.
prompt_ssh_keys() {
  if [[ "${AUTO_APPROVE:-false}" == "true" || ! -t 0 ]]; then
    [[ -n "${GITHUB_USER:-}${SSH_PUBLIC_KEY:-}" ]] \
      || die "No SSH key: set GITHUB_USER or SSH_PUBLIC_KEY in .env (or run interactively)."
    [[ -n "${GITHUB_USER:-}" ]] && info "SSH keys from github.com/${GITHUB_USER}.keys"
    [[ -n "${SSH_PUBLIC_KEY:-}" ]] && info "SSH key from .env: $(pubkey_fingerprint "$SSH_PUBLIC_KEY")"
    export_ssh_key_vars
    return
  fi

  local default_choice=1 choice answer count input key keyfile="" default_input
  [[ -n "${SSH_PUBLIC_KEY:-}" && -z "${GITHUB_USER:-}" ]] && default_choice=2
  echo
  info "Where should the server's SSH key come from?"
  echo "    1) Public keys of a GitHub user (github.com/<user>.keys)"
  echo "    2) Your own public key (path to a .pub file or paste the key)"
  while true; do
    read -r -p "Choice [${default_choice}]: " choice
    choice="${choice:-$default_choice}"
    [[ "$choice" == 1 || "$choice" == 2 ]] && break
    warn "Please enter 1 or 2."
  done

  if [[ "$choice" == 1 ]]; then
    while true; do
      read -r -p "GitHub username${GITHUB_USER:+ [${GITHUB_USER}]}: " answer
      answer="${answer:-${GITHUB_USER:-}}"
      if ! valid_github_user "$answer"; then warn "Invalid GitHub username."; continue; fi
      count="$(github_key_count "$answer")"
      if (( count > 0 )); then ok "${count} public key(s) at github.com/${answer}.keys"; break; fi
      warn "No keys found at https://github.com/${answer}.keys."
    done
    GITHUB_USER="$answer"; SSH_PUBLIC_KEY=""
  else
    default_input=""
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
      default_input="from .env"
    else
      for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
        [[ -f "$f" ]] && { default_input="$f"; break; }
      done
    fi
    while true; do
      read -r -p "Path to a .pub file or paste the key${default_input:+ [${default_input}]}: " input
      input="${input:-$default_input}"
      keyfile=""
      if [[ "$input" == "from .env" ]]; then
        key="$(normalize_pubkey "$SSH_PUBLIC_KEY")"
      else
        input="${input/#\~/$HOME}"
        if [[ -f "$input" ]]; then keyfile="$input"; key="$(normalize_pubkey "$(head -n1 "$input")")"
        else key="$(normalize_pubkey "$input")"; fi
      fi
      if valid_pubkey "$key"; then ok "Key: $(pubkey_fingerprint "$key")"; break; fi
      warn "Not a valid public SSH key (expected e.g. 'ssh-ed25519 AAAA…' or a .pub file)."
    done
    SSH_PUBLIC_KEY="$key"; GITHUB_USER=""
    # Use the matching private key for the connection automatically.
    if [[ -n "$keyfile" && "$keyfile" == *.pub && -f "${keyfile%.pub}" && -z "${SSH_KEY_FILE:-}" ]]; then
      SSH_KEY_FILE="${keyfile%.pub}"
      set_env_value SSH_KEY_FILE "$SSH_KEY_FILE"
      ok "SSH_KEY_FILE=${SSH_KEY_FILE} saved to .env"
    fi
  fi

  set_env_value GITHUB_USER "${GITHUB_USER}"
  set_env_value SSH_PUBLIC_KEY "\"${SSH_PUBLIC_KEY}\""
  ok "SSH key source saved to .env"
  export_ssh_key_vars
}

cmd_deploy() {
  if [[ "${SKIP_REQUIREMENTS:-false}" != "true" ]]; then
    bash "$REPO_DIR/scripts/install-requirements.sh"
  fi
  load_env
  require_cmd ssh curl dig nc jq openssl
  ensure_hcloud_token
  info "Initializing OpenTofu"
  tf init -input=false -upgrade >/dev/null
  ok "Providers ready"
  if [[ -z "$(server_id)" ]]; then
    prompt_admin_user
    prompt_ssh_keys
  else
    info "Existing server, user: ${ADMIN_USER}"
    [[ -n "${GITHUB_USER:-}${SSH_PUBLIC_KEY:-}" ]] || prompt_ssh_keys
  fi
  check_local_ssh_key
  info "Creating/updating infrastructure"
  tf_apply -input=false
  ok "Server: $(server_ip) / $(server_ip6)"

  wait_for_ssh
  wait_for_cloud_init
  local dns_ok=true cert_ok=true
  wait_for_dns || dns_ok=false
  if [[ "$dns_ok" == true ]]; then wait_for_cert || cert_ok=false; else cert_ok=false; fi

  show_token
  echo
  info "Functional test"
  local test_rc=0
  bash "$REPO_DIR/scripts/test-server.sh" || test_rc=$?
  echo
  if [[ "$cert_ok" == false ]]; then
    warn "DNS/certificate not ready yet – run './setup.sh test' again once DNS is set."
  fi
  info "Done. SSH: ./setup.sh ssh   |   Dashboard: https://${DASHBOARD_DOMAIN}"
  return "$test_rc"
}

cmd_admin_access() {
  load_env
  local nets="${*:-}"
  [[ -n "$nets" ]] || die "Usage: ./setup.sh admin-access \"203.0.113.10/32 [more]\" | any"
  warn "SSH will be restricted to these networks: ${nets}"
  local myip
  myip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$myip" ]] && echo "    Your current public IPv4: ${myip}"
  confirm "Continue?" || die "Aborted."
  remote "sudo pangolin-admin-access set $(printf '%q' "$nets")"
  sleep 3
  info "Checking access with a new connection"
  if remote 'sudo pangolin-admin-access confirm'; then
    ok "New rules confirmed"
  else
    die "No access with the new rules – they will be rolled back automatically in ~3 minutes."
  fi
}

cmd_backup() {
  load_env
  local dir="$STATE_DIR/backups" file
  mkdir -p "$dir"
  chmod 700 "$dir"
  file="$dir/pangolin-$(date +%Y%m%d-%H%M%S).tar.gz"
  info "Backing up /opt/pangolin (Pangolin is stopped briefly)"
  remote 'cd /opt/pangolin && sudo docker compose stop pangolin >/dev/null 2>&1; sudo tar -czf - docker-compose.yml .env config; rc=$?; sudo docker compose start pangolin >/dev/null 2>&1; exit $rc' > "$file"
  chmod 600 "$file"
  ok "Backup: $file ($(du -h "$file" | cut -f1))"
}

cmd_update() {
  load_env
  local pv="${PANGOLIN_VERSION:-}" gv="${GERBIL_VERSION:-}" tv="${TRAEFIK_VERSION:-}"
  [[ -n "$pv$gv$tv" ]] || die "Set PANGOLIN_VERSION / GERBIL_VERSION / TRAEFIK_VERSION in .env."
  local re='^[A-Za-z0-9._-]*$'
  [[ "$pv" =~ $re && "$gv" =~ $re && "$tv" =~ $re ]] || die "Invalid version."
  confirm "Create a backup first?" && cmd_backup
  info "Updating containers (pangolin=${pv:-unchanged}, gerbil=${gv:-unchanged}, traefik=${tv:-unchanged})"
  remote "set -e; cd /opt/pangolin
    [ -n '$pv' ] && sudo sed -i 's|\(image: docker.io/fosrl/pangolin:\).*|\1$pv|' docker-compose.yml
    [ -n '$gv' ] && sudo sed -i 's|\(image: docker.io/fosrl/gerbil:\).*|\1$gv|' docker-compose.yml
    [ -n '$tv' ] && sudo sed -i 's|\(image: docker.io/traefik:\).*|\1$tv|' docker-compose.yml
    sudo docker compose pull --quiet && sudo docker compose up -d && sudo docker compose ps"
  ok "Update finished – test: ./setup.sh test"
}

cmd_recreate() {
  load_env
  warn "The server will be deleted and recreated. All Pangolin data will be lost!"
  confirm "Really rebuild?" || die "Aborted."
  ensure_hcloud_token
  tf init -input=false >/dev/null
  prompt_admin_user
  prompt_ssh_keys
  check_local_ssh_key
  tf_apply -input=false -replace=hcloud_server.pangolin
  SKIP_REQUIREMENTS=true cmd_deploy
}

cmd_destroy() {
  load_env
  warn "Server $(server_ip 2>/dev/null || echo '?') and all managed SSH keys will be deleted."
  confirm "Really delete?" || die "Aborted."
  ensure_hcloud_token
  tf init -input=false >/dev/null
  local args=(-input=false)
  [[ "${AUTO_APPROVE:-false}" == "true" ]] && args+=(-auto-approve)
  tf destroy "${args[@]}"
  ok "Deleted"
}

main() {
  local cmd="${1:-deploy}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    deploy)        cmd_deploy ;;
    requirements)  bash "$REPO_DIR/scripts/install-requirements.sh" ;;
    plan)          load_env; ensure_hcloud_token; tf init -input=false >/dev/null; tf plan -input=false ;;
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
