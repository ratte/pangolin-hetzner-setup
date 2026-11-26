#!/usr/bin/env bash
# Shared functions for setup.sh and the helper scripts.
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
die()   { echo "${C_RED}ERROR:${C_RST} $*" >&2; exit 1; }

require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "Missing programs: ${missing[*]} – run './setup.sh requirements' first."
}

# Prefer OpenTofu, fall back to Terraform.
tf_bin() {
  if command -v tofu >/dev/null 2>&1; then echo tofu
  elif command -v terraform >/dev/null 2>&1; then echo terraform
  else die "Neither OpenTofu (tofu) nor Terraform found – run './setup.sh requirements'."
  fi
}

tf() { "$(tf_bin)" -chdir="$TF_DIR" "$@"; }

# Read a single output; empty if there is no state (yet).
# Not "output -raw": with an empty state it prints a warning to stdout (exit code 0).
tf_out() {
  tf output -json 2>/dev/null | jq -r --arg k "$1" '.[$k].value // empty | if type == "string" or type == "number" or type == "boolean" then . else tojson end'
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE is missing. Copy the template: cp .env.example .env"
  # Values from the command line (e.g. AUTO_APPROVE=true ./setup.sh) take precedence.
  local cli_auto_approve="${AUTO_APPROVE:-}"
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  [[ -n "$cli_auto_approve" ]] && AUTO_APPROVE="$cli_auto_approve"

  : "${DASHBOARD_DOMAIN:?set DASHBOARD_DOMAIN in .env}"
  : "${BASE_DOMAIN:?set BASE_DOMAIN in .env}"
  : "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL in .env}"

  # HCLOUD_TOKEN is only needed for OpenTofu -> ensure_hcloud_token (asks if empty).
  [[ -n "${HCLOUD_TOKEN:-}" ]] && export TF_VAR_hcloud_token="$HCLOUD_TOKEN"
  export TF_VAR_dashboard_domain="$DASHBOARD_DOMAIN"
  export TF_VAR_base_domain="$BASE_DOMAIN"
  export TF_VAR_letsencrypt_email="$LETSENCRYPT_EMAIL"

  local pair var name
  for pair in \
    ADMIN_USER:admin_user SERVER_NAME:server_name \
    SERVER_TYPE:server_type LOCATION:location IMAGE:image TIMEZONE:timezone \
    AUTO_REBOOT_TIME:auto_reboot_time PANGOLIN_VERSION:pangolin_version \
    GERBIL_VERSION:gerbil_version TRAEFIK_VERSION:traefik_version \
    BADGER_VERSION:badger_version PROTECTION:protection SSH_PORT:ssh_port; do
    var="${pair%%:*}"; name="${pair##*:}"
    if [[ -n "${!var:-}" ]]; then export "TF_VAR_${name}=${!var}"; fi
  done

  export_ssh_key_vars

  if [[ -n "${ADMIN_ALLOWED_CIDRS:-}" ]]; then
    # "any" or space-separated list -> JSON list for OpenTofu
    # shellcheck disable=SC2086
    TF_VAR_admin_allowed_cidrs="$(printf '%s\n' $ADMIN_ALLOWED_CIDRS | jq -R . | jq -sc .)"
    export TF_VAR_admin_allowed_cidrs
  fi

  ADMIN_USER="${ADMIN_USER:-peng}"

  # If the server already exists, the user from the OpenTofu state wins.
  if command -v tofu >/dev/null 2>&1 || command -v terraform >/dev/null 2>&1; then
    local state_user
    state_user="$(tf_out admin_user || true)"
    if [[ -n "$state_user" && "$state_user" != "$ADMIN_USER" ]]; then
      warn "Server was created with user '${state_user}' (.env: '${ADMIN_USER}') – using '${state_user}'."
      ADMIN_USER="$state_user"
    fi
    [[ -n "$state_user" ]] && export TF_VAR_admin_user="$ADMIN_USER"
  fi
  DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
}

# Pass SSH key sources to OpenTofu: GITHUB_USER and/or SSH_PUBLIC_KEY.
export_ssh_key_vars() {
  export TF_VAR_github_user="${GITHUB_USER:-}"
  TF_VAR_ssh_public_keys="$(jq -nc --arg k "${SSH_PUBLIC_KEY:-}" 'if $k == "" then [] else [$k] end')"
  export TF_VAR_ssh_public_keys
}

# HTTP status of the Hetzner API for a token (token not visible in the process list).
hcloud_token_status() {
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --config - \
    https://api.hetzner.cloud/v1/locations <<<"header = \"Authorization: Bearer $1\"")" || true
  echo "${status:-000}"
}

# Ensure HCLOUD_TOKEN: from .env or ask interactively (hidden input).
ensure_hcloud_token() {
  if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
    if [[ "${AUTO_APPROVE:-false}" == "true" || ! -t 0 ]]; then
      die "HCLOUD_TOKEN missing in .env (no prompt without a terminal or with AUTO_APPROVE=true)."
    fi
    local token answer status
    echo
    info "Hetzner API token missing"
    echo "    Create one: Hetzner Console → Project → Security → API tokens (Read & Write)"
    while true; do
      read -rs -p "HCLOUD_TOKEN (input hidden): " token
      echo
      token="$(tr -d '[:space:]' <<<"$token")"
      if [[ ! "$token" =~ ^[A-Za-z0-9]{64}$ ]]; then
        warn "The token must consist of 64 letters/digits."
        continue
      fi
      status="$(hcloud_token_status "$token")"
      case "$status" in
        200)     ok "Token accepted by Hetzner"; break ;;
        401|403) warn "Token rejected by Hetzner (HTTP ${status})." ;;
        *)       warn "Could not verify the token (HTTP ${status}) – using it anyway."; break ;;
      esac
    done
    read -r -p "Save token to .env (file readable only by you)? [Y/n] " answer
    if [[ ! "$answer" =~ ^[nN]$ ]]; then
      chmod 600 "$ENV_FILE"
      set_env_value HCLOUD_TOKEN "$token"
      ok "HCLOUD_TOKEN saved to .env"
    else
      warn "Token is used for this run only."
    fi
    HCLOUD_TOKEN="$token"
  fi
  export TF_VAR_hcloud_token="$HCLOUD_TOKEN"
}

valid_github_user() { [[ "$1" =~ ^[A-Za-z0-9-]{1,39}$ ]]; }

# Number of public keys at github.com/<user>.keys (0 on error).
github_key_count() {
  local body
  body="$(curl -fsS --max-time 15 "https://github.com/$1.keys" 2>/dev/null)" || { echo 0; return; }
  grep -c '^[a-z]' <<<"$body" || true
}

# Trim a public key to "<type> <base64>" (without comment).
normalize_pubkey() { awk 'NF >= 2 { print $1 " " $2; exit }' <<<"$1" | tr -d '\r'; }

valid_pubkey() {
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+={0,3}$ ]] \
    && ssh-keygen -l -f <(echo "$1") >/dev/null 2>&1
}

pubkey_fingerprint() { ssh-keygen -l -f <(echo "$1") 2>/dev/null | awk '{print $2 " " $NF}'; }

# Checks whether the local key (SSH_KEY_FILE) matches one of the server keys.
# Otherwise every login fails and fail2ban bans your own IP.
check_local_ssh_key() {
  [[ -n "${SSH_KEY_FILE:-}" ]] || return 0
  local file="${SSH_KEY_FILE/#\~/$HOME}" local_fp keys="" k
  [[ -r "$file" ]] || die "SSH_KEY_FILE=${SSH_KEY_FILE} not found."
  if [[ -r "${file}.pub" ]]; then
    local_fp="$(ssh-keygen -l -f "${file}.pub" 2>/dev/null | awk '{print $2}')"
  else
    local_fp="$(ssh-keygen -y -f "$file" 2>/dev/null | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}')"
  fi
  [[ -n "$local_fp" ]] || { warn "Cannot read the fingerprint of ${SSH_KEY_FILE} – skipping key check."; return 0; }

  [[ -n "${SSH_PUBLIC_KEY:-}" ]] && keys+="${SSH_PUBLIC_KEY}"$'\n'
  [[ -n "${GITHUB_USER:-}" ]] && keys+="$(curl -fsSL "https://github.com/${GITHUB_USER}.keys" 2>/dev/null || true)"$'\n'
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    [[ "$(ssh-keygen -l -f <(echo "$k") 2>/dev/null | awk '{print $2}')" == "$local_fp" ]] && return 0
  done <<<"$keys"
  die "The local key ${SSH_KEY_FILE} (${local_fp}) does not match any of the server keys (SSH_PUBLIC_KEY/GITHUB_USER). Fix SSH_KEY_FILE in .env – otherwise fail2ban will ban your IP."
}

valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != root ]]; }

# Set a value in .env (replace the existing line, otherwise append). Permissions are kept.
set_env_value() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$value" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

server_ip()  { tf_out ipv4; }
server_ip6() { tf_out ipv6; }
server_id()  { tf_out server_id; }
server_ssh_port() { local p; p="$(tf_out ssh_port)"; echo "${p:-${SSH_PORT:-2222}}"; }

ssh_opts() {
  local id
  id="$(server_id)"
  [[ -n "$id" ]] || die "No server found in the state – run './setup.sh deploy' first."
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

# Resolve DNS records via a public resolver (bypasses local caches).
resolve_a()    { dig +short A "$1" @"$DNS_RESOLVER" 2>/dev/null | grep -E '^[0-9.]+$' || true; }
resolve_aaaa() { dig +short AAAA "$1" @"$DNS_RESOLVER" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true; }
