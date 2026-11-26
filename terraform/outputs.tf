output "server_id" {
  value = hcloud_server.pangolin.id
}

output "ipv4" {
  value = hcloud_server.pangolin.ipv4_address
}

output "ipv6" {
  value = hcloud_server.pangolin.ipv6_address
}

output "admin_user" {
  value = var.admin_user
}

output "dashboard_domain" {
  value = var.dashboard_domain
}

output "dashboard_url" {
  value = "https://${var.dashboard_domain}"
}

output "initial_setup_url" {
  value = "https://${var.dashboard_domain}/auth/initial-setup"
}

output "ssh_port" {
  value = var.ssh_port
}

output "ssh_command" {
  value = "ssh -p ${var.ssh_port} ${var.admin_user}@${hcloud_server.pangolin.ipv4_address}"
}

output "ssh_key_ids" {
  value = local.server_ssh_key_ids
}
