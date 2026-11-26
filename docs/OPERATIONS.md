# Operations

## Important paths on the server

| Path | Content |
|---|---|
| `/opt/pangolin/docker-compose.yml` | Stack definition (versions) |
| `/opt/pangolin/.env` | Setup token (`PANGOLIN_SETUP_TOKEN`), root only |
| `/opt/pangolin/config/config.yml` | Pangolin configuration incl. server secret, root only |
| `/opt/pangolin/config/db/db.sqlite` | Pangolin database |
| `/opt/pangolin/config/key` | Gerbil's WireGuard key |
| `/opt/pangolin/config/letsencrypt/acme.json` | Certificates |
| `/opt/pangolin/config/traefik/` | Traefik configuration and logs |
| `/etc/pangolin-setup/settings.env` | Admin user, admin networks |
| `/usr/local/sbin/pangolin-*` | Bootstrap, firewall, admin access |
| `/var/log/pangolin-bootstrap.log` | Log of the initial setup |

## Common tasks

```bash
./setup.sh ssh                                   # log in
./setup.sh ssh 'cd /opt/pangolin && sudo docker compose ps'
./setup.sh ssh 'sudo docker logs -f pangolin'    # logs (also gerbil, traefik)
./setup.sh ssh 'sudo fail2ban-client status sshd'
./setup.sh ssh 'sudo ufw status verbose'
./setup.sh test                                  # full functional test
```

## Restricting admin access

```bash
./setup.sh admin-access "203.0.113.10/32"                 # one IP
./setup.sh admin-access "203.0.113.10/32 2001:db8::/48"   # several networks
./setup.sh admin-access any                               # open everywhere again
```

How it works: the new rules are applied and a rollback timer (3 minutes) starts.
The script then opens a **new** SSH connection. If it succeeds, the change is confirmed.
If it fails, the server restores the old rules automatically.

Directly on the server:

```bash
sudo pangolin-admin-access show
sudo pangolin-admin-access set "203.0.113.10/32"
sudo pangolin-admin-access confirm     # from a new session
sudo pangolin-admin-access rollback
```

Emergency if you are locked out: Hetzner Console → server → **Console** (VNC). The user
has no password, so boot into *Rescue* there or run `./setup.sh recreate`.

## Updates

**Operating system**: runs automatically (unattended-upgrades, reboot if needed at
`AUTO_REBOOT_TIME`). The containers start by themselves after a reboot
(`restart: unless-stopped`).

**Pangolin/Gerbil/Traefik**:

1. Read the release notes: <https://github.com/fosrl/pangolin/releases>
2. Set the new versions in `.env`, e.g. `PANGOLIN_VERSION=1.28.0`
3. `./setup.sh update` (offers a backup first)
4. `./setup.sh test`

For future installations, also update the defaults in `terraform/variables.tf`.

## Backup and restore

```bash
./setup.sh backup     # → .state/backups/pangolin-YYYYMMDD-HHMMSS.tar.gz
```

The backup contains `docker-compose.yml`, `.env` and `config/` (database, keys,
certificates, secret). Pangolin is stopped for a few seconds. Existing tunnels
through Gerbil keep running. The archive contains secrets: store it safely.

Restore (e.g. after `recreate`):

```bash
scp -P 2222 -o UserKnownHostsFile=.state/known_hosts_<id> .state/backups/pangolin-….tar.gz peng@<ip>:/tmp/
./setup.sh ssh 'cd /opt/pangolin && sudo docker compose down \
  && sudo tar -xzf /tmp/pangolin-….tar.gz -C /opt/pangolin \
  && sudo docker compose up -d && rm /tmp/pangolin-….tar.gz'
./setup.sh test
```

Optionally also enable Hetzner backups (+20 % of the server price) in the Console.

## Changing the configuration

`user_data` and `ssh_keys` are deliberately excluded from changes in OpenTofu, so
that an `apply` never recreates the server by accident. Options:

- **Small change**: edit directly on the server in `/opt/pangolin/config/…` and run
  `sudo docker compose restart` (update the templates in the repo as well!)
- **Rebuild**: `./setup.sh backup`, `./setup.sh recreate`, restore the backup
- **New SSH key**: add it on the server to `~peng/.ssh/authorized_keys`
  (or `recreate`)

## Deleting the server

```bash
./setup.sh destroy
```

Deletes the server and the Hetzner SSH keys created by this setup (label
`managed-by=pangolin-hetzner-setup`). Keys that existed before are kept.
Remove the DNS records yourself afterwards.

## Troubleshooting

| Symptom | Cause / solution |
|---|---|
| Direct login without the script | `ssh -p 2222 peng@<ip>` (or the user you chose) |
| `SSH not reachable` | The local private key does not match the configured public key (GitHub or `SSH_PUBLIC_KEY`) → set `SSH_KEY_FILE` or `ssh-add` |
| Port 2222 suddenly `Connection refused` | fail2ban has banned your IP after failed logins (usually a wrong `SSH_KEY_FILE`). Fix the key and wait for the ban to expire (1 h). `./setup.sh deploy` checks the key beforehand |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Avoided by a separate `known_hosts` per server ID. Otherwise delete `.state/known_hosts_*` |
| cloud-init reports an error | `./setup.sh ssh 'sudo cloud-init status --long; sudo tail -100 /var/log/cloud-init-output.log'` |
| Test "Traefik default certificate" | DNS does not point to the server yet or the AAAA record is wrong. `./setup.sh ssh 'sudo docker logs traefik 2>&1 \| grep -i acme'`, then `sudo docker restart traefik` |
| Let's Encrypt rate limit | Too many reinstallations with the same domain → wait (max. 5 certificates/week per domain set) |
| `pangolin` not healthy | `./setup.sh ssh 'sudo docker logs pangolin'`, usually an error in `config.yml` |
| Newt does not connect | Check UDP 51820 and 21820: `sudo ss -lnup`; a Hetzner Cloud Firewall must not block them in addition |
| `SSH key not unique` (Hetzner) | Does not happen: existing keys are detected and reused |
| Setup token invalid | It has already been used (an admin exists). Log in with the admin account |
