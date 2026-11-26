variable "hcloud_token" {
  description = "Hetzner Cloud API-Token (Lesen & Schreiben) des Projekts."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.hcloud_token) == 64
    error_message = "Der Hetzner-API-Token muss 64 Zeichen lang sein."
  }
}

variable "server_name" {
  description = "Name und Hostname des Servers."
  type        = string
  default     = "pangolin"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.server_name))
    error_message = "server_name: nur a-z, 0-9 und '-', max. 63 Zeichen."
  }
}

variable "server_type" {
  description = "Hetzner-Servertyp."
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner-Standort (z. B. nbg1, fsn1, hel1)."
  type        = string
  default     = "nbg1"
}

variable "image" {
  description = "Betriebssystem-Image. Ausgelegt auf Ubuntu 26.04 (docker-compose-v2 aus Ubuntu-Paketen)."
  type        = string
  default     = "ubuntu-26.04"

  validation {
    condition     = startswith(var.image, "ubuntu-")
    error_message = "Nur Ubuntu-Images werden unterstützt (z. B. ubuntu-26.04)."
  }
}

variable "github_user" {
  description = "Optional: GitHub-Benutzer, dessen öffentliche SSH-Keys (https://github.com/<user>.keys) verwendet werden. Leer = keine."
  type        = string
  default     = ""

  validation {
    condition     = var.github_user == "" || can(regex("^[A-Za-z0-9-]{1,39}$", var.github_user))
    error_message = "Ungültiger GitHub-Benutzername."
  }
}

variable "ssh_public_keys" {
  description = "Optional: zusätzliche öffentliche SSH-Keys (z. B. \"ssh-ed25519 AAAA...\")."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for k in var.ssh_public_keys :
      can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) [A-Za-z0-9+/]+={0,3}( .*)?$", trimspace(k)))
    ])
    error_message = "ssh_public_keys enthält einen ungültigen öffentlichen SSH-Key."
  }
}

variable "admin_user" {
  description = "Login-Benutzer auf dem Server (root-Login wird deaktiviert)."
  type        = string
  default     = "peng"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_user)) && var.admin_user != "root"
    error_message = "admin_user: gültiger Linux-Benutzername, nicht root."
  }
}

variable "admin_allowed_cidrs" {
  description = "Quellnetze für SSH. [\"any\"] = überall offen (Startzustand). Später z. B. [\"203.0.113.10/32\"]."
  type        = list(string)
  default     = ["any"]

  validation {
    condition     = length(var.admin_allowed_cidrs) > 0 && alltrue([for c in var.admin_allowed_cidrs : c == "any" || can(cidrhost(c, 0))])
    error_message = "admin_allowed_cidrs: \"any\" oder gültige CIDR-Netze (z. B. 203.0.113.10/32)."
  }
}

variable "ssh_port" {
  description = "TCP-Port des SSH-Servers."
  type        = number
  default     = 2222

  validation {
    condition     = var.ssh_port >= 1 && var.ssh_port <= 65535 && floor(var.ssh_port) == var.ssh_port && !contains([80, 443, 3000, 3001, 3002, 3004, 8080], var.ssh_port)
    error_message = "ssh_port: 1–65535 und nicht von Pangolin belegt (80, 443, 3000–3004, 8080)."
  }
}

variable "dashboard_domain" {
  description = "FQDN des Pangolin-Dashboards, z. B. pangolin.example.ch."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.dashboard_domain))
    error_message = "dashboard_domain muss ein gültiger, kleingeschriebener FQDN sein."
  }
}

variable "base_domain" {
  description = "Basis-Domain für Ressourcen, z. B. example.ch."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.base_domain))
    error_message = "base_domain muss eine gültige, kleingeschriebene Domain sein."
  }
}

variable "letsencrypt_email" {
  description = "E-Mail-Adresse für Let's Encrypt."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.letsencrypt_email))
    error_message = "letsencrypt_email ist keine gültige E-Mail-Adresse."
  }
}

variable "timezone" {
  description = "Zeitzone des Servers."
  type        = string
  default     = "Europe/Zurich"
}

variable "auto_reboot_time" {
  description = "Uhrzeit für automatische Neustarts nach Sicherheitsupdates (HH:MM) oder \"off\"."
  type        = string
  default     = "04:00"

  validation {
    condition     = var.auto_reboot_time == "off" || can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.auto_reboot_time))
    error_message = "auto_reboot_time: HH:MM oder \"off\"."
  }
}

variable "pangolin_version" {
  description = "Image-Tag von fosrl/pangolin."
  type        = string
  default     = "1.27.1"
}

variable "gerbil_version" {
  description = "Image-Tag von fosrl/gerbil."
  type        = string
  default     = "1.6.0"
}

variable "traefik_version" {
  description = "Image-Tag von traefik."
  type        = string
  default     = "v3.7.16"
}

variable "badger_version" {
  description = "Version des Traefik-Plugins fosrl/badger."
  type        = string
  default     = "v1.8.0"
}

variable "protection" {
  description = "Hetzner Lösch-/Rebuild-Schutz aktivieren (verhindert auch 'destroy')."
  type        = bool
  default     = false
}
