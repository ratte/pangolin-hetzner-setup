# Voraussetzungen (lokale Maschine)

Diese Software wird auf dem Rechner gebraucht, von dem aus `./setup.sh` läuft
(Ubuntu 22.04+/Debian 12+). `./setup.sh requirements` installiert alles
automatisch. Das Skript liest die Paketliste **direkt aus dieser Datei**
(Block zwischen den `apt-packages`-Markierungen). Wer hier ein Paket ergänzt,
bekommt es also beim nächsten Lauf mitinstalliert.

## APT-Pakete

<!-- apt-packages:start -->
- `ca-certificates` – TLS-Zertifikate für HTTPS-Downloads
- `curl` – HTTP-Abfragen, Zertifikats- und Endpunkt-Tests
- `gnupg` – Signaturschlüssel des OpenTofu-Repositorys
- `jq` – JSON-Verarbeitung (Variablen für OpenTofu)
- `openssh-client` – SSH-Zugriff auf den Server (`ssh`, `ssh-keygen`)
- `bind9-dnsutils` – `dig` für DNS-Prüfungen
- `netcat-openbsd` – `nc` für Port-Tests
- `openssl` – Zertifikatsprüfung
- `git` – Repository-Verwaltung
- `coreutils` – Basiswerkzeuge (`timeout`, `base64`, …)
<!-- apt-packages:end -->

## OpenTofu

| Software | Version | Quelle |
|---|---|---|
| `tofu` (OpenTofu) | ≥ 1.6 | Offizielles APT-Repository `packages.opentofu.org` |

Das Skript richtet das OpenTofu-Repository gemäss der offiziellen Anleitung
(<https://opentofu.org/docs/intro/install/deb/>) ein, falls `tofu` fehlt.
Ist stattdessen `terraform` (≥ 1.6) installiert, wird dieses verwendet.

OpenTofu lädt beim `init` automatisch diese Provider:

| Provider | Version |
|---|---|
| `hetznercloud/hcloud` | ~> 1.70 |
| `hashicorp/http` | ~> 3.4 |

## Konten und Zugangsdaten

- **Hetzner Cloud**: Projekt und API-Token mit Lese-/Schreibrechten
  (Console → Projekt → Sicherheit → API-Tokens)
- **GitHub**: Benutzer `ratte` mit mindestens einem öffentlichen SSH-Key
  (<https://github.com/ratte.keys>). Der passende private Key muss lokal im
  `ssh-agent` oder unter `~/.ssh/` liegen (oder per `SSH_KEY_FILE` angegeben werden).
- **DNS**: Zugriff auf die DNS-Zone der Domain, um den A-Record (und optional
  AAAA sowie einen Wildcard-Record) auf den Server zu setzen

## Auf dem Server (automatisch per cloud-init)

Nur zur Information, hier ist nichts zu tun:
`docker.io`, `docker-compose-v2`, `ufw`, `nftables`, `fail2ban`, `python3-systemd`,
`unattended-upgrades`, `curl`, `jq`, `openssl` sowie die Container
`fosrl/pangolin`, `fosrl/gerbil` und `traefik`.
