# Betrieb

## Wichtige Pfade auf dem Server

| Pfad | Inhalt |
|---|---|
| `/opt/pangolin/docker-compose.yml` | Stack-Definition (Versionen) |
| `/opt/pangolin/.env` | Setup-Token (`PANGOLIN_SETUP_TOKEN`), nur root |
| `/opt/pangolin/config/config.yml` | Pangolin-Konfiguration inkl. Server-Secret, nur root |
| `/opt/pangolin/config/db/db.sqlite` | Pangolin-Datenbank |
| `/opt/pangolin/config/key` | WireGuard-Schlüssel von Gerbil |
| `/opt/pangolin/config/letsencrypt/acme.json` | Zertifikate |
| `/opt/pangolin/config/traefik/` | Traefik-Konfiguration und Logs |
| `/etc/pangolin-setup/settings.env` | Admin-Benutzer, Admin-Netze |
| `/usr/local/sbin/pangolin-*` | Bootstrap, Firewall, Admin-Zugang |
| `/var/log/pangolin-bootstrap.log` | Protokoll der Ersteinrichtung |

## Häufige Aufgaben

```bash
./setup.sh ssh                                   # Login
./setup.sh ssh 'cd /opt/pangolin && sudo docker compose ps'
./setup.sh ssh 'sudo docker logs -f pangolin'    # Logs (auch gerbil, traefik)
./setup.sh ssh 'sudo fail2ban-client status sshd'
./setup.sh ssh 'sudo ufw status verbose'
./setup.sh test                                  # kompletter Funktionstest
```

## Admin-Zugang einschränken

```bash
./setup.sh admin-access "203.0.113.10/32"                 # eine IP
./setup.sh admin-access "203.0.113.10/32 2001:db8::/48"   # mehrere Netze
./setup.sh admin-access any                               # wieder überall offen
```

Ablauf: Die neuen Regeln werden gesetzt und ein Rollback-Timer (3 Minuten) gestartet.
Danach baut das Skript eine **neue** SSH-Verbindung auf. Klappt sie, wird bestätigt.
Klappt sie nicht, stellt der Server die alten Regeln automatisch wieder her.

Direkt auf dem Server:

```bash
sudo pangolin-admin-access show
sudo pangolin-admin-access set "203.0.113.10/32"
sudo pangolin-admin-access confirm     # aus einer neuen Sitzung
sudo pangolin-admin-access rollback
```

Notfall bei Aussperrung: Hetzner Console → Server → **Konsole** (VNC). Der Benutzer
hat kein Passwort. Deshalb dort über *Rescue* booten oder `./setup.sh recreate`.

## Updates

**Betriebssystem**: läuft automatisch (unattended-upgrades, Neustart bei Bedarf um
`AUTO_REBOOT_TIME`). Die Container starten nach einem Neustart von selbst
(`restart: unless-stopped`).

**Pangolin/Gerbil/Traefik**:

1. Release Notes lesen: <https://github.com/fosrl/pangolin/releases>
2. Neue Versionen in `.env` setzen, z. B. `PANGOLIN_VERSION=1.28.0`
3. `./setup.sh update` (bietet vorher ein Backup an)
4. `./setup.sh test`

Für künftige Neuinstallationen auch die Standardwerte in `terraform/variables.tf` anpassen.

## Backup und Wiederherstellung

```bash
./setup.sh backup     # → .state/backups/pangolin-JJJJMMTT-HHMMSS.tar.gz
```

Gesichert werden `docker-compose.yml`, `.env` und `config/` (Datenbank, Schlüssel,
Zertifikate, Secret). Pangolin wird dafür einige Sekunden gestoppt. Bestehende
Tunnel über Gerbil laufen weiter. Das Archiv enthält Geheimnisse: sicher aufbewahren.

Wiederherstellen (z. B. nach `recreate`):

```bash
scp -P 2222 -o UserKnownHostsFile=.state/known_hosts_<id> .state/backups/pangolin-….tar.gz peng@<ip>:/tmp/
./setup.sh ssh 'cd /opt/pangolin && sudo docker compose down \
  && sudo tar -xzf /tmp/pangolin-….tar.gz -C /opt/pangolin \
  && sudo docker compose up -d && rm /tmp/pangolin-….tar.gz'
./setup.sh test
```

Optional zusätzlich Hetzner-Backups (+20 % Serverpreis) in der Console aktivieren.

## Konfiguration ändern

`user_data` und `ssh_keys` sind in OpenTofu absichtlich von Änderungen ausgenommen,
damit ein `apply` den Server nie unbeabsichtigt neu erstellt. Möglichkeiten:

- **Kleine Änderung**: direkt auf dem Server in `/opt/pangolin/config/…` anpassen und
  `sudo docker compose restart` (Templates im Repo nachziehen!)
- **Neu aufsetzen**: `./setup.sh backup`, `./setup.sh recreate`, Backup zurückspielen
- **Neuer SSH-Key**: auf dem Server in `~peng/.ssh/authorized_keys` ergänzen
  (oder `recreate`)

## Server löschen

```bash
./setup.sh destroy
```

Löscht den Server und die von diesem Setup angelegten Hetzner-SSH-Keys (Label
`managed-by=pangolin-hetzner-setup`). Bereits vorher vorhandene Keys bleiben.
DNS-Einträge danach selbst entfernen.

## Fehlersuche

| Symptom | Ursache / Lösung |
|---|---|
| Direkter Login ohne Skript | `ssh -p 2222 peng@<ip>` (bzw. dein gewählter Benutzer) |
| `SSH nicht erreichbar` | Lokaler privater Key passt nicht zum angegebenen öffentlichen Key (GitHub bzw. `SSH_PUBLIC_KEY`) → `SSH_KEY_FILE` setzen oder `ssh-add` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Wird durch eigene `known_hosts` pro Server-ID vermieden. Sonst `.state/known_hosts_*` löschen |
| cloud-init meldet Fehler | `./setup.sh ssh 'sudo cloud-init status --long; sudo tail -100 /var/log/cloud-init-output.log'` |
| Test „Traefik-Standardzertifikat“ | DNS zeigt noch nicht auf den Server oder falscher AAAA-Record. `./setup.sh ssh 'sudo docker logs traefik 2>&1 \| grep -i acme'`, danach `sudo docker restart traefik` |
| Rate-Limit von Let's Encrypt | Zu viele Neuinstallationen mit derselben Domain → warten (max. 5 Zertifikate/Woche je Domain-Set) |
| `pangolin` nicht healthy | `./setup.sh ssh 'sudo docker logs pangolin'`, meist Fehler in `config.yml` |
| Newt verbindet nicht | UDP 51820 und 21820 prüfen: `sudo ss -lnup`, Hetzner Cloud Firewall darf nicht zusätzlich blockieren |
| `Ein SSH-Key ist nicht eindeutig` (Hetzner) | Tritt nicht auf: vorhandene Keys werden erkannt und wiederverwendet |
| Setup-Token ungültig | Wurde bereits benutzt (ein Admin existiert). Login mit dem Admin-Konto |
