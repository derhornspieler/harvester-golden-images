# -----------------------------------------------------------------------------
# Harvester Connection
# -----------------------------------------------------------------------------

variable "harvester_kubeconfig_path" {
  description = "Path to Harvester kubeconfig"
  type        = string
  default     = "./kubeconfig-harvester.yaml"
}

variable "vm_namespace" {
  description = "Harvester namespace for the golden image"
  type        = string
}

# -----------------------------------------------------------------------------
# Distro Selection
# -----------------------------------------------------------------------------

variable "distro" {
  description = "Target distro for the golden image"
  type        = string
  default     = "rocky9"

  validation {
    condition     = contains(["rocky9", "debian12", "ubuntu2404", "fedora42"], var.distro)
    error_message = "distro must be one of: rocky9, debian12, ubuntu2404, fedora42"
  }
}

# -----------------------------------------------------------------------------
# Base Image
# -----------------------------------------------------------------------------

variable "cloud_image_url" {
  description = "Cloud image qcow2 URL (proxy-cache or upstream). Overrides the distro default if set."
  type        = string
  default     = ""

  validation {
    condition     = var.cloud_image_url == "" || can(regex("^https?://", var.cloud_image_url))
    error_message = "cloud_image_url must be a valid HTTP(S) URL or empty (to use distro default)."
  }
}

# -----------------------------------------------------------------------------
# Package Repositories (proxy-cache or private mirror)
# -----------------------------------------------------------------------------

variable "repo_mirror_url" {
  description = "Base URL for distro repos via proxy-cache or private mirror. Structure depends on distro."
  type        = string
  default     = ""

  validation {
    condition     = var.repo_mirror_url == "" || can(regex("^https?://", var.repo_mirror_url))
    error_message = "repo_mirror_url must be a valid HTTP(S) URL or empty (to use upstream repos)."
  }
}

variable "private_ca_pem" {
  description = "PEM-encoded CA certificate chain for repo/registry TLS trust. Empty string disables CA injection."
  type        = string
  sensitive   = true
  default     = ""
}

# -----------------------------------------------------------------------------
# CIS Hardening
# -----------------------------------------------------------------------------

variable "cis_level" {
  description = "CIS hardening level: l1 or l2"
  type        = string
  default     = "l1"

  validation {
    condition     = contains(["l1", "l2"], var.cis_level)
    error_message = "cis_level must be l1 or l2."
  }
}

variable "cis_type" {
  description = "CIS target type: server or workstation"
  type        = string
  default     = "server"

  validation {
    condition     = contains(["server", "workstation"], var.cis_type)
    error_message = "cis_type must be server or workstation."
  }
}

variable "cis_tailoring_file" {
  description = "Optional: path to an XCCDF tailoring file for CIS exceptions (relative to templates/)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Builder VM
# -----------------------------------------------------------------------------

variable "builder_image_url" {
  description = "Cloud image for the builder VM (must be Rocky 9). Overrides the default upstream URL."
  type        = string
  default     = ""

  validation {
    condition     = var.builder_image_url == "" || can(regex("^https?://", var.builder_image_url))
    error_message = "builder_image_url must be a valid HTTP(S) URL or empty (to use upstream Rocky 9)."
  }
}

variable "builder_cpu" {
  description = "vCPUs for utility VM"
  type        = number
  default     = 4
}

variable "builder_memory" {
  description = "Memory for utility VM"
  type        = string
  default     = "4Gi"
}

variable "builder_disk_size" {
  description = "Disk for utility VM (needs space for 2x qcow2 + tools)"
  type        = string
  default     = "30Gi"
}

variable "image_name_prefix" {
  description = "Prefix for golden image name. Defaults to <distro>-cis-golden."
  type        = string
  default     = ""
}

variable "ssh_authorized_keys" {
  description = "SSH keys for utility VM (debug access, NOT baked into golden image)"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Harvester Networking
# -----------------------------------------------------------------------------

variable "harvester_network_name" {
  description = "Harvester VM network name"
  type        = string
}

variable "harvester_network_namespace" {
  description = "Harvester VM network namespace"
  type        = string
}
