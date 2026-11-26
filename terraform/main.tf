###############################################################################
# SSH keys: GitHub user (optional) and/or keys given directly
###############################################################################

data "http" "github_keys" {
  count = var.github_user == "" ? 0 : 1
  url   = "https://github.com/${var.github_user}.keys"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && length(trimspace(self.response_body)) > 0
      error_message = "No public SSH keys found at https://github.com/${var.github_user}.keys."
    }
  }
}

# All keys in the Hetzner project. Hetzner forbids duplicate keys, so existing
# keys (not managed by this setup) are reused.
data "hcloud_ssh_keys" "all" {}

locals {
  managed_label = "pangolin-hetzner-setup"

  github_keys = flatten([
    for d in data.http.github_keys : [
      for line in split("\n", replace(trimspace(d.response_body), "\r", "")) :
      trimspace(line) if length(trimspace(line)) > 0
    ]
  ])

  all_keys = concat(local.github_keys, [for k in var.ssh_public_keys : trimspace(k)])

  # Normalized to "<type> <base64>" (without comment); duplicates merged.
  keys_grouped = {
    for k in local.all_keys : join(" ", slice(split(" ", k), 0, 2)) => k...
  }
  keys_by_norm = { for norm, ks in local.keys_grouped : norm => ks[0] }

  existing_unmanaged_keys = {
    for k in data.hcloud_ssh_keys.all.ssh_keys :
    join(" ", slice(split(" ", trimspace(k.public_key)), 0, 2)) => tostring(k.id)
    if try(k.labels["managed-by"], "") != local.managed_label
  }

  keys_to_create = {
    for norm, full in local.keys_by_norm : norm => full
    if !contains(keys(local.existing_unmanaged_keys), norm)
  }

  reused_key_ids = [
    for norm, id in local.existing_unmanaged_keys : id
    if contains(keys(local.keys_by_norm), norm)
  ]
}

resource "hcloud_ssh_key" "github" {
  for_each = local.keys_to_create

  name       = "${var.server_name}-key-${substr(sha256(each.key), 0, 10)}"
  public_key = each.value
  labels = {
    "managed-by" = local.managed_label
  }
}

locals {
  server_ssh_key_ids = concat(
    [for k in hcloud_ssh_key.github : tostring(k.id)],
    local.reused_key_ids,
  )
}

###############################################################################
# Files for the server (written via cloud-init)
###############################################################################

locals {
  server_files = {
    sshd_hardening = templatefile("${path.module}/templates/sshd-hardening.conf.tftpl", {
      admin_user = var.admin_user
      ssh_port   = var.ssh_port
    })
    settings_env = templatefile("${path.module}/templates/settings.env.tftpl", {
      admin_user       = var.admin_user
      admin_cidrs      = join(" ", var.admin_allowed_cidrs)
      dashboard_domain = var.dashboard_domain
      ssh_port         = var.ssh_port
    })
    unattended_upgrades = templatefile("${path.module}/templates/52unattended-upgrades-local.tftpl", {
      auto_reboot      = var.auto_reboot_time != "off"
      auto_reboot_time = var.auto_reboot_time == "off" ? "04:00" : var.auto_reboot_time
    })
    fail2ban_jail = templatefile("${path.module}/templates/fail2ban-jail.local.tftpl", {
      ssh_port = var.ssh_port
    })
    auto_upgrades = file("${path.module}/../server/21auto-upgrades-pangolin")
    docker_daemon = file("${path.module}/../server/docker-daemon.json")
    firewall      = file("${path.module}/../server/pangolin-firewall.sh")
    admin_access  = file("${path.module}/../server/pangolin-admin-access.sh")
    bootstrap     = file("${path.module}/../server/pangolin-bootstrap.sh")

    compose = templatefile("${path.module}/templates/pangolin/docker-compose.yml.tftpl", {
      pangolin_version = var.pangolin_version
      gerbil_version   = var.gerbil_version
      traefik_version  = var.traefik_version
    })
    pangolin_config = templatefile("${path.module}/templates/pangolin/config.yml.tftpl", {
      dashboard_domain = var.dashboard_domain
      base_domain      = var.base_domain
    })
    traefik_config = templatefile("${path.module}/templates/pangolin/traefik_config.yml.tftpl", {
      letsencrypt_email = var.letsencrypt_email
      badger_version    = var.badger_version
    })
    traefik_dynamic = templatefile("${path.module}/templates/pangolin/dynamic_config.yml.tftpl", {
      dashboard_domain = var.dashboard_domain
    })
  }

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", merge(
    { for name, content in local.server_files : "${name}_b64" => base64encode(content) },
    {
      hostname      = var.server_name
      timezone      = var.timezone
      admin_user    = var.admin_user
      ssh_keys_json = jsonencode(values(local.keys_by_norm))
    },
  ))
}

###############################################################################
# Server
###############################################################################

resource "hcloud_server" "pangolin" {
  name               = var.server_name
  server_type        = var.server_type
  location           = var.location
  image              = var.image
  ssh_keys           = local.server_ssh_key_ids
  user_data          = local.user_data
  delete_protection  = var.protection
  rebuild_protection = var.protection

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  labels = {
    "managed-by" = local.managed_label
    "role"       = "pangolin"
  }

  lifecycle {
    # Changes to keys/cloud-init only apply when the server is recreated (./setup.sh recreate).
    ignore_changes = [ssh_keys, user_data, image]

    precondition {
      condition     = length(local.keys_by_norm) > 0
      error_message = "No SSH key given: set github_user or ssh_public_keys (./setup.sh asks for it)."
    }

    precondition {
      condition     = length(local.server_ssh_key_ids) > 0
      error_message = "No SSH key is available for the server."
    }

    precondition {
      condition     = length(local.user_data) <= 32768
      error_message = "cloud-init user_data exceeds the Hetzner limit of 32 KiB."
    }
  }
}
