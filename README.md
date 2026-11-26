# Pangolin auf Hetzner Cloud

Automatisiertes, gehärtetes Setup eines [Pangolin](https://github.com/fosrl/pangolin)-Servers
(Tunnel-Reverse-Proxy mit Identity-Management, Alternative zu Cloudflare Tunnel) auf einem
Hetzner-Cloud-Server **CX23** mit Ubuntu 24.04.

Ein Befehl erstellt den Server, härtet ihn, startet Pangolin, wartet auf DNS und
Zertifikat und testet anschliessend die laufende Maschine:

```bash
cp .env.example .env && chmod 600 .env   # Token, Domain, E-Mail eintragen
./setup.sh
```

---

## Inhalt

- [Was wird eingerichtet?](#was-wird-eingerichtet)
- [Architektur](#architektur)
- [Voraussetzungen](#voraussetzungen)
- [Schnellstart](#schnellstart)
- [Konfiguration (.env)](#konfiguration-env)
- [Befehle von setup.sh](#befehle-von-setupsh)
- [Sicherheitskonzept](#sicherheitskonzept)
- [Funktionstest](#funktionstest)
- [Repository-Struktur](#repository-struktur)
- [Betrieb, Updates, Backup](docs/BETRIEB.md)
- [Fehlersuche](docs/BETRIEB.md#fehlersuche)

---

## Was wird eingerichtet?

| Bereich | Umsetzung |
|---|---|
| Server | Hetzner Cloud `cx23` (2 vCPU, 4 GB RAM, 40 GB), Ubuntu 24.04, IPv4 + IPv6 |
| Provisionierung | OpenTofu (Terraform-kompatibel) + cloud-init |
| SSH-Keys | Beim Start abgefragt: GitHub-Benutzer (`github.com/<benutzer>.keys`) oder eigener öffentlicher Key |
| Login | SSH auf **Port 2222** (22 geschlossen), Benutzer `peng` (beim Start abgefragt) mit sudo, root-Login und Passwort-Login deaktiviert |
| Firewall | **ufw auf dem Node selbst** (keine Hetzner Cloud Firewall) |
| Admin-Zugang | Zu Beginn überall offen (`ADMIN_ALLOWED_CIDRS=any`), später einschränkbar |
| Brute-Force-Schutz | fail2ban: Jails `sshd` (aggressive) und `recidive`, Bans via nftables |
| Updates | unattended-upgrades mit automatischem Neustart um 04:00 |
| Pangolin-Stack | `pangolin`, `gerbil` (WireGuard), `traefik` mit Let's Encrypt, Docker Compose |
| Geheimnisse | Server-Secret und Setup-Token werden **auf dem Server** erzeugt, nicht in cloud-init oder tfstate |
| Tests | Rund 60 automatische Prüfungen, auf dem Server und von aussen |

## Architektur

```
             Internet
                │
   ┌────────────┴─────────────────────────────────────────┐
   │ Hetzner CX23 – Ubuntu 24.04                          │
   │                                                      │
   │  ufw:  2222/tcp (SSH)  80/tcp  443/tcp  443/udp      │
   │        51820/udp  21820/udp        fail2ban (nft)    │
   │                                                      │
   │  ┌──────── Docker: /opt/pangolin ──────────────────┐ │
   │  │ gerbil  ← veröffentlicht 80, 443, 51820, 21820 │ │
   │  │   └─ traefik (teilt Netz mit gerbil)           │ │
   │  │        ├─ Let's Encrypt (HTTP-Challenge)        │ │
   │  │        └─ → pangolin :3000 API / :3002 UI       │ │
   │  │ pangolin  (SQLite in config/db)                 │ │
   │  └─────────────────────────────────────────────────┘ │
   └──────────────────────────────────────────────────────┘
                │ WireGuard (Newt-Tunnel)
        Eigene Standorte/Netze mit Newt
```

Ablauf von `./setup.sh`:

1. Lokale Voraussetzungen aus `requirements.md` installieren (inkl. OpenTofu)
2. Abfragen: Benutzername auf dem Server und SSH-Key-Quelle (GitHub-Benutzer oder
   eigener Key). Die Antworten werden in `.env` gespeichert und beim nächsten Mal
   vorgeschlagen. Mit `AUTO_APPROVE=true` gibt es keine Rückfragen, dann gelten die Werte aus `.env`.
3. `tofu apply`: SSH-Keys (von GitHub bzw. aus `.env`) holen, in Hetzner anlegen (vorhandene werden wiederverwendet), Server mit cloud-init erstellen
4. cloud-init: Pakete, Benutzer, SSH-Härtung, ufw, fail2ban, Auto-Updates, Docker, Pangolin-Dateien
5. `pangolin-bootstrap` auf dem Server: Secrets erzeugen, Images laden, Stack starten
6. Lokal warten auf SSH → cloud-init → DNS-Eintrag → gültiges Zertifikat
7. Setup-Token für den ersten Admin anzeigen
8. Funktionstest der laufenden Maschine

## Voraussetzungen

Details in **[requirements.md](requirements.md)**. Kurz:

- Ubuntu/Debian-Rechner mit sudo (das Skript installiert den Rest)
- Hetzner-Cloud-API-Token (Lesen & Schreiben)
- Ein SSH-Schlüsselpaar: der öffentliche Teil liegt auf GitHub oder als `.pub`-Datei vor, der private lokal
- Eine Domain, bei der du DNS-Einträge setzen kannst

## Schnellstart

```bash
git clone git@github.com:ratte/Pangolin-hetzner-setup.git
cd Pangolin-hetzner-setup
cp .env.example .env && chmod 600 .env
nano .env                      # HCLOUD_TOKEN, DASHBOARD_DOMAIN, BASE_DOMAIN, LETSENCRYPT_EMAIL
./setup.sh                     # fragt Server-Benutzer (Vorschlag: peng) und SSH-Key-Quelle ab
```

Während das Skript läuft, zeigt es die Server-IP an. Setze dann beim DNS-Anbieter:

| Name | Typ | Wert |
|---|---|---|
| `pangolin.example.ch` (DASHBOARD_DOMAIN) | A | IPv4 des Servers |
| `pangolin.example.ch` | AAAA | IPv6 des Servers (optional, aber dann korrekt!) |
| `*.example.ch` (BASE_DOMAIN) | A | IPv4 des Servers (für Ressourcen, empfohlen) |

Das Skript wartet, bis der A-Record stimmt (max. `DNS_WAIT_TIMEOUT`), dann auf das
Let's-Encrypt-Zertifikat. Am Ende erscheinen:

```
==> Ersten Admin anlegen
    URL:         https://pangolin.example.ch/auth/initial-setup
    Setup-Token: 3f9c…
```

Dort legst du den ersten Admin-Account an. Den Token gibt `./setup.sh token`
jederzeit erneut aus. Danach in Pangolin eine Site anlegen und auf dem Zielsystem
**Newt** mit den angezeigten Werten starten.

## Konfiguration (.env)

| Variable | Standard | Bedeutung |
|---|---|---|
| `HCLOUD_TOKEN` | – | Hetzner-API-Token (Pflicht) |
| `DASHBOARD_DOMAIN` | – | FQDN des Dashboards (Pflicht) |
| `BASE_DOMAIN` | – | Basis-Domain für Ressourcen (Pflicht) |
| `LETSENCRYPT_EMAIL` | – | E-Mail für Let's Encrypt (Pflicht) |
| `SERVER_NAME` | `pangolin` | Servername/Hostname |
| `SERVER_TYPE` | `cx23` | Hetzner-Servertyp |
| `LOCATION` | `nbg1` | Standort (`nbg1`, `fsn1`, `hel1`, …) |
| `IMAGE` | `ubuntu-24.04` | Nur Ubuntu wird unterstützt |
| `TIMEZONE` | `Europe/Zurich` | Zeitzone |
| `AUTO_REBOOT_TIME` | `04:00` | Neustart nach Kernel-Updates, `off` zum Abschalten |
| `PROTECTION` | `false` | Hetzner Lösch-/Rebuild-Schutz |
| `GITHUB_USER` | leer | SSH-Keys von `github.com/<benutzer>.keys` (wird abgefragt) |
| `SSH_PUBLIC_KEY` | leer | Eigener öffentlicher Key, in Anführungszeichen (wird abgefragt) |
| `ADMIN_USER` | `peng` | Login-Benutzer auf dem Server, wird vor dem Erstellen abgefragt |
| `SSH_PORT` | `2222` | SSH-Port auf dem Server |
| `ADMIN_ALLOWED_CIDRS` | `any` | SSH-Quellnetze beim Erstellen, mehrere in Anführungszeichen mit Leerzeichen |
| `SSH_KEY_FILE` | – | Privater Key, falls nicht im ssh-agent/Standardpfad |
| `PANGOLIN_VERSION` / `GERBIL_VERSION` / `TRAEFIK_VERSION` / `BADGER_VERSION` | siehe `terraform/variables.tf` | Fixierte Versionen |
| `AUTO_APPROVE` | `false` | Keine Rückfragen (auch per `AUTO_APPROVE=true ./setup.sh`) |
| `DNS_WAIT_TIMEOUT` | `1800` | Max. Wartezeit auf DNS (Sekunden) |
| `DNS_RESOLVER` | `1.1.1.1` | Resolver für DNS-Prüfungen |

`.env` wird als Shell-Datei eingelesen: Werte mit Leerzeichen in Anführungszeichen setzen.

## Befehle von setup.sh

| Befehl | Wirkung |
|---|---|
| `./setup.sh` / `deploy` | Alles: Voraussetzungen, Server, Warten, Token, Test |
| `./setup.sh requirements` | Nur lokale Voraussetzungen installieren |
| `./setup.sh plan` | Geplante Infrastruktur-Änderungen anzeigen |
| `./setup.sh test` | Funktionstest (Bericht in `.state/`) |
| `./setup.sh token` | Setup-Token + URL für den ersten Admin |
| `./setup.sh ssh [befehl]` | SSH auf den Server |
| `./setup.sh admin-access "<netze>"` | SSH auf Netze einschränken, mit Auto-Rollback; `any` öffnet wieder |
| `./setup.sh backup` | `/opt/pangolin` sichern nach `.state/backups/` |
| `./setup.sh update` | Container auf Versionen aus `.env` aktualisieren |
| `./setup.sh recreate` | Server neu aufsetzen (**Daten weg**, vorher `backup`) |
| `./setup.sh destroy` | Server und verwaltete SSH-Keys löschen |

## Sicherheitskonzept

- **Keine Geheimnisse in cloud-init/tfstate**: Das Pangolin-Server-Secret
  (`openssl rand -hex 32`) und der einmalige Setup-Token werden erst auf dem Server
  erzeugt. Der Hetzner-API-Token steht nur in `.env` (gitignored). Als
  Provider-Argument landet er nicht im tfstate.
- **SSH**: Port 2222 (die Socket-Aktivierung von Ubuntu 24.04 auf Port 22 wird
  abgeschaltet), nur Public-Key, nur der Admin-Benutzer (Standard `peng`), kein root, `MaxAuthTries 3`.
  Hetzner erhält die Keys ebenfalls, deshalb wird kein root-Passwort per Mail verschickt.
- **Firewall auf dem Node (ufw)**: eingehend alles blockiert ausser den nötigen Ports.
  Docker veröffentlicht Container-Ports über eigene iptables-Regeln an ufw vorbei.
  Das betrifft hier nur die ohnehin öffentlichen Ports 80/443/51820/21820. Interne
  Dienste (Pangolin 3000–3002, Gerbil 3004, Traefik-API 8080) werden **nicht**
  veröffentlicht, und der Test prüft das von aussen.
- **Admin-Zugang**: zu Beginn überall offen (Vorgabe). Einschränken mit
  `./setup.sh admin-access "203.0.113.10/32"`. Das Skript setzt die Regel, öffnet
  eine **neue** SSH-Verbindung zur Kontrolle und bestätigt erst dann. Kommt keine
  Bestätigung, wird nach 3 Minuten automatisch zurückgerollt, damit du dich
  nicht aussperrst.
- **Pangolin-Dashboard**: bleibt öffentlich erreichbar, geschützt durch Login (2FA
  in Pangolin aktivieren!). Eine IP-Sperre des Dashboards ist bewusst nicht
  eingebaut: Newt-Clients verbinden sich über dieselbe Domain (`/api/v1`), und
  geschützte Ressourcen leiten Besucher zur Anmeldung auf das Dashboard um.
  Registrierung nur per Einladung (`disable_signup_without_invite: true`).
- **fail2ban**: `sshd` (aggressive, 4 Versuche → 1 h Bann), `recidive`
  (5 Banns/Tag → 1 Woche auf allen Ports). Bans via nftables (IPv4 und IPv6).
- **Updates**: Sicherheitsupdates täglich automatisch, Neustart bei Bedarf um 04:00.
  Container-Versionen sind fixiert und werden gezielt mit `./setup.sh update` aktualisiert.
- **Änderungsschutz**: `ssh_keys` und `user_data` sind in OpenTofu von Änderungen
  ausgenommen. Neue GitHub-Keys oder geänderte Templates zerstören den Server also
  nicht versehentlich, sie gelten erst nach `./setup.sh recreate`.

## Funktionstest

`./setup.sh test` (läuft auch automatisch am Ende von `deploy`) prüft:

**Auf dem Server** (per SSH): cloud-init/Bootstrap abgeschlossen, keine
fehlgeschlagenen Units, Speicherplatz, NTP, effektive sshd-Konfiguration inkl. Port, ufw aktiv
mit allen Regeln, fail2ban mit beiden Jails, unattended-upgrades, Docker, alle drei
Container laufen (inkl. Neustart-Zähler), Pangolin-Healthcheck, interne API,
Traefik-Ping, Gerbil-Schlüssel, Datenbank, Secret gesetzt, Dateirechte, Zertifikat in
`acme.json`, lauschende Ports 2222/80/443/51820/21820.

**Von aussen**: Ports 2222/80/443 offen, Port 22 und interne Ports 3000–3004/8080 **zu**, root-Login
abgewiesen, Server bietet nur Public-Key an, DNS A/AAAA korrekt, HTTP→HTTPS-Umleitung,
gültiges Let's-Encrypt-Zertifikat (nicht das Traefik-Standardzertifikat), API meldet
`Healthy`, Setup-Seite erreichbar.

Exit-Code `0` bedeutet: alle Pflichtprüfungen bestanden. Jeder Lauf schreibt einen
Bericht nach `.state/test-report-*.txt`.

`scripts/lint.sh` prüft das Repository statisch (Bash-Syntax, shellcheck, `tofu fmt`/`validate`).

## Repository-Struktur

```
.
├── setup.sh                      # Einstiegspunkt für alles
├── requirements.md               # Lokale Voraussetzungen (vom Skript ausgewertet)
├── .env.example                  # Konfigurationsvorlage
├── terraform/
│   ├── versions.tf               # Provider (hcloud, http)
│   ├── variables.tf              # Variablen mit Validierung
│   ├── main.tf                   # SSH-Keys, Server, cloud-init-Rendering
│   ├── outputs.tf
│   └── templates/
│       ├── cloud-init.yaml.tftpl
│       ├── sshd-hardening.conf.tftpl
│       ├── settings.env.tftpl
│       ├── 52unattended-upgrades-local.tftpl
│       └── pangolin/             # docker-compose, config.yml, Traefik
├── server/                       # Dateien, die auf den Server kommen
│   ├── pangolin-bootstrap.sh     # Erststart: Secrets, Firewall, Stack
│   ├── pangolin-firewall.sh      # ufw-Regeln (idempotent)
│   ├── pangolin-admin-access.sh  # Admin-Netze mit Auto-Rollback
│   ├── fail2ban-jail.local
│   ├── 21auto-upgrades-pangolin
│   └── docker-daemon.json        # Log-Rotation
├── scripts/
│   ├── lib.sh                    # Gemeinsame Funktionen
│   ├── install-requirements.sh
│   ├── test-server.sh            # Funktionstest (lokal + remote)
│   ├── remote-checks.sh          # Prüfungen auf dem Server
│   └── lint.sh                   # Statische Prüfung
└── docs/
    └── BETRIEB.md                # Betrieb, Updates, Backup, Fehlersuche
```
