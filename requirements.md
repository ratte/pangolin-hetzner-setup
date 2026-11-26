# Requirements (local machine)

This software is needed on the machine that runs `./setup.sh`
(Ubuntu 22.04+/Debian 12+). `./setup.sh requirements` installs everything
automatically. The script reads the package list **directly from this file**
(the block between the `apt-packages` markers), so a package added here is
installed on the next run.

## APT packages

<!-- apt-packages:start -->
- `ca-certificates` – TLS certificates for HTTPS downloads
- `curl` – HTTP requests, certificate and endpoint tests
- `gnupg` – signing key of the OpenTofu repository
- `jq` – JSON processing (variables for OpenTofu)
- `openssh-client` – SSH access to the server (`ssh`, `ssh-keygen`)
- `bind9-dnsutils` – `dig` for DNS checks
- `netcat-openbsd` – `nc` for port tests
- `openssl` – certificate checks
- `git` – repository management
- `coreutils` – basic tools (`timeout`, `base64`, …)
<!-- apt-packages:end -->

## OpenTofu

| Software | Version | Source |
|---|---|---|
| `tofu` (OpenTofu) | ≥ 1.6 | Official APT repository `packages.opentofu.org` |

If `tofu` is missing, the script sets up the OpenTofu repository following the
official guide (<https://opentofu.org/docs/intro/install/deb/>).
If `terraform` (≥ 1.6) is installed instead, that is used.

OpenTofu downloads these providers automatically during `init`:

| Provider | Version |
|---|---|
| `hetznercloud/hcloud` | ~> 1.70 |
| `hashicorp/http` | ~> 3.4 |

## Accounts and credentials

- **Hetzner Cloud**: a project and an API token with read/write permissions
  (Console → Project → Security → API tokens)
- **SSH key**: either a GitHub user with at least one public SSH key
  (`https://github.com/<user>.keys`) or your own public key (`.pub` file).
  `./setup.sh` asks for it. The matching private key must be available locally in
  the `ssh-agent` or under `~/.ssh/` (or be given via `SSH_KEY_FILE`).
- **DNS**: access to the domain's DNS zone to point the A record (and optionally
  AAAA and a wildcard record) at the server

## On the server (automatic via cloud-init)

For information only, nothing to do here:
`docker.io`, `docker-compose-v2`, `ufw`, `nftables`, `fail2ban`, `python3-systemd`,
`unattended-upgrades`, `curl`, `jq`, `openssl` and the containers
`fosrl/pangolin`, `fosrl/gerbil` and `traefik`.
