output "utility_vm_name" {
  value = harvester_virtualmachine.utility.name
}

output "utility_vm_namespace" {
  value = harvester_virtualmachine.utility.namespace
}

output "utility_vm_ip" {
  description = "IP address of the utility VM (for HTTP download)"
  value       = harvester_virtualmachine.utility.network_interface[0].ip_address
}

output "distro" {
  description = "Distro used for this build"
  value       = var.distro
}

output "image_name_prefix" {
  description = "Resolved image name prefix"
  value       = local.image_name_prefix
}

output "cis_profile" {
  description = "CIS profile applied"
  value       = local.cis_profile_id
}

output "golden_image_name" {
  description = "Final golden image name (override or auto-generated)"
  value       = var.image_name_override != "" ? var.image_name_override : local.image_name_prefix
}
