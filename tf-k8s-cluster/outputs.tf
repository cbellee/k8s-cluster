output "primary_control_plane_ip" {
  description = "Primary control-plane IP address."
  value       = var.control_planes[var.primary_control_plane].ip
}

output "control_plane_ips" {
  description = "Control-plane IP addresses."
  value       = { for name, cfg in var.control_planes : name => cfg.ip }
}

output "worker_ips" {
  description = "Worker IP addresses."
  value       = { for name, cfg in var.workers : name => cfg.ip }
}

output "kubeconfig_path" {
  description = "Path to the exported kubeconfig artifact."
  value       = "${path.module}/artifacts/kubeconfig"
}
