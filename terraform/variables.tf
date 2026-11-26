variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read & Write) of the project."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.hcloud_token) == 64
    error_message = "The Hetzner API token must be 64 characters long."
  }
}

variable "server_name" {
  description = "Name and hostname of the server."
  type        = string
  default     = "pangolin"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.server_name))
    error_message = "server_name: only a-z, 0-9 and '-', max. 63 characters."
  }
}

variable "server_type" {
  description = "Hetzner server type."
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner location (e.g. nbg1, fsn1, hel1)."
  type        = string
  default     = "nbg1"
}

variable "image" {
  description = "Operating system image. Designed for Ubuntu 26.04 (docker-compose-v2 from Ubuntu packages)."
  type        = string
  default     = "ubuntu-26.04"

  validation {
    condition     = startswith(var.image, "ubuntu-")
    error_message = "Only Ubuntu images are supported (e.g. ubuntu-26.04)."
  }
}

variable "github_user" {
  description = "Optional: GitHub user whose public SSH keys (https://github.com/<user>.keys) are used. Empty = none."
  type        = string
  default     = ""

  validation {
    condition     = var.github_user == "" || can(regex("^[A-Za-z0-9-]{1,39}$", var.github_user))
    error_message = "Invalid GitHub username."
  }
}

variable "ssh_public_keys" {
  description = "Optional: additional public SSH keys (e.g. \"ssh-ed25519 AAAA...\")."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for k in var.ssh_public_keys :
      can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) [A-Za-z0-9+/]+={0,3}( .*)?$", trimspace(k)))
    ])
    error_message = "ssh_public_keys contains an invalid public SSH key."
  }
}

variable "admin_user" {
  description = "Login user on the server (root login is disabled)."
  type        = string
  default     = "peng"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_user)) && var.admin_user != "root"
    error_message = "admin_user: valid Linux username, not root."
  }
}

variable "admin_allowed_cidrs" {
  description = "Source networks for SSH. [\"any\"] = open everywhere (initial state). Later e.g. [\"203.0.113.10/32\"]."
  type        = list(string)
  default     = ["any"]

  validation {
    condition     = length(var.admin_allowed_cidrs) > 0 && alltrue([for c in var.admin_allowed_cidrs : c == "any" || can(cidrhost(c, 0))])
    error_message = "admin_allowed_cidrs: \"any\" or valid CIDR networks (e.g. 203.0.113.10/32)."
  }
}

variable "ssh_port" {
  description = "TCP port of the SSH server."
  type        = number
  default     = 2222

  validation {
    condition     = var.ssh_port >= 1 && var.ssh_port <= 65535 && floor(var.ssh_port) == var.ssh_port && !contains([80, 443, 3000, 3001, 3002, 3004, 8080], var.ssh_port)
    error_message = "ssh_port: 1–65535 and not used by Pangolin (80, 443, 3000–3004, 8080)."
  }
}

variable "dashboard_domain" {
  description = "FQDN of the Pangolin dashboard, e.g. pangolin.example.com."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.dashboard_domain))
    error_message = "dashboard_domain must be a valid lowercase FQDN."
  }
}

variable "base_domain" {
  description = "Base domain for resources, e.g. example.com."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.base_domain))
    error_message = "base_domain must be a valid lowercase domain."
  }
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.letsencrypt_email))
    error_message = "letsencrypt_email is not a valid email address."
  }
}

variable "timezone" {
  description = "Time zone of the server."
  type        = string
  default     = "Europe/Zurich"
}

variable "auto_reboot_time" {
  description = "Time for automatic reboots after security updates (HH:MM) or \"off\"."
  type        = string
  default     = "04:00"

  validation {
    condition     = var.auto_reboot_time == "off" || can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.auto_reboot_time))
    error_message = "auto_reboot_time: HH:MM or \"off\"."
  }
}

variable "pangolin_version" {
  description = "Image tag of fosrl/pangolin."
  type        = string
  default     = "1.27.1"
}

variable "gerbil_version" {
  description = "Image tag of fosrl/gerbil."
  type        = string
  default     = "1.6.0"
}

variable "traefik_version" {
  description = "Image tag of traefik."
  type        = string
  default     = "v3.7.16"
}

variable "badger_version" {
  description = "Version of the Traefik plugin fosrl/badger."
  type        = string
  default     = "v1.8.0"
}

variable "protection" {
  description = "Enable Hetzner delete/rebuild protection (also prevents 'destroy')."
  type        = bool
  default     = false
}
