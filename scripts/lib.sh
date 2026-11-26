#!/usr/bin/env bash
# Gemeinsame Funktionen für setup.sh und die Hilfsskripte.
# shellcheck disable=SC2034

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_DIR/terraform"
STATE_DIR="$REPO_DIR/.state"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi

info()  { echo "${C_BLU}==>${C_RST} ${C_BLD}$*${C_RST}"; }
ok()    { echo "${C_GRN}  ✔${C_RST} $*"; }
warn()  { echo "${C_YLW}  !${C_RST} $*" >&2; }
die()   { echo "${C_RED}FEHLER:${C_RST} $*" >&2; exit 1; }

require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "Fehlende Programme: ${missing[*]} – zuerst './setup.sh requirements' ausführen."
}

# OpenTofu bevorzugen, Terraform als Fallback.
tf_bin() {
  if command -v tofu >/dev/null 2>&1; then echo tofu
  elif command -v terraform >/dev/null 2>&1; then echo terraform
  else die "Weder OpenTofu (tofu) noch Terraform gefunden – './setup.sh requirements' ausführen."
  fi
}

tf() { "$(tf_bin)" -chdir="$TF_DIR" "$@"; }

tf_out() { tf output -raw "$1" 2>/dev/null; }

load_env() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE fehlt. Vorlage kopieren: cp .env.example .env"
  # Werte aus der Kommandozeile (z. B. AUTO_APPROVE=true ./setup.sh) haben Vorrang.
  local cli_auto_approve="${AUTO_APPROVE:-}"
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  [[ -n "$cli_auto_approve" ]] && AUTO_APPROVE="$cli_auto_approve"

  : "${HCLOUD_TOKEN:?HCLOUD_TOKEN in .env setzen}"
  : "${DASHBOARD_DOMAIN:?DASHBOARD_DOMAIN in .env setzen}"
  : "${BASE_DOMAIN:?BASE_DOMAIN in .env setzen}"
  : "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL in .env setzen}"

  export TF_VAR_hcloud_token="$HCLOUD_TOKEN"
  export TF_VAR_dashboard_domain="$DASHBOARD_DOMAIN"
  export TF_VAR_base_domain="$BASE_DOMAIN"
  export TF_VAR_letsencrypt_email="$LETSENCRYPT_EMAIL"

  local pair var name
  for pair in \
    GITHUB_USER:github_user ADMIN_USER:admin_user SERVER_NAME:server_name \
    SERVER_TYPE:server_type LOCATION:location IMAGE:image TIMEZONE:timezone \
    AUTO_REBOOT_TIME:auto_reboot_time PANGOLIN_VERSION:pangolin_version \
    GERBIL_VERSION:gerbil_version TRAEFIK_VERSION:traefik_version \
    BADGER_VERSION:badger_version PROTECTION:protection SSH_PORT:ssh_port; do
    var="${pair%%:*}"; name="${pair##*:}"
    if [[ -n "${!var:-}" ]]; then export "TF_VAR_${name}=${!var}"; fi
  done

  if [[ -n "${ADMIN_ALLOWED_CIDRS:-}" ]]; then
    # "any" oder Liste mit Leerzeichen -> JSON-Liste für OpenTofu
    # shellcheck disable=SC2086
    TF_VAR_admin_allowed_cidrs="$(printf '%s\n' $ADMIN_ALLOWED_CIDRS | jq -R . | jq -sc .)"
    export TF_VAR_admin_allowed_cidrs
  fi

  ADMIN_USER="${ADMIN_USER:-ratte}"
  DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
}

server_ip()  { tf_out ipv4; }
server_ip6() { tf_out ipv6; }
server_id()  { tf_out server_id; }
server_ssh_port() { local p; p="$(tf_out ssh_port)"; echo "${p:-${SSH_PORT:-2222}}"; }

ssh_opts() {
  local id
  id="$(server_id)"
  [[ -n "$id" ]] || die "Kein Server im State gefunden – zuerst './setup.sh deploy'."
  SSH_OPTS=(
    -p "$(server_ssh_port)"
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$STATE_DIR/known_hosts_$id"
    -o LogLevel=ERROR
  )
  if [[ -n "${SSH_KEY_FILE:-}" ]]; then
    SSH_OPTS+=(-i "${SSH_KEY_FILE/#\~/$HOME}" -o IdentitiesOnly=yes)
  fi
}

remote() {
  ssh_opts
  ssh "${SSH_OPTS[@]}" "${ADMIN_USER}@$(server_ip)" "$@"
}

# DNS-A-Record über öffentlichen Resolver auflösen (umgeht lokale Caches).
resolve_a()    { dig +short A "$1" @"$DNS_RESOLVER" 2>/dev/null | grep -E '^[0-9.]+$' || true; }
resolve_aaaa() { dig +short AAAA "$1" @"$DNS_RESOLVER" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true; }
