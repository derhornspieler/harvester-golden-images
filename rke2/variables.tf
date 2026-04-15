# -----------------------------------------------------------------------------
# Harvester Connection
# -----------------------------------------------------------------------------

variable "harvester_kubeconfig_path" {
  description = "Path to Harvester kubeconfig"
  type        = string
  default     = "./kubeconfig-harvester.yaml"
}

variable "vm_namespace" {
  description = "Harvester namespace (same as cluster VMs)"
  type        = string
}

# -----------------------------------------------------------------------------
# Base Image
# -----------------------------------------------------------------------------

variable "rocky_image_url" {
  description = "Rocky 9 GenericCloud qcow2 URL (proxy-cache or private mirror)"
  type        = string

  validation {
    condition     = can(regex("^https?://", var.rocky_image_url))
    error_message = "rocky_image_url must be a valid HTTP(S) URL."
  }
}

# -----------------------------------------------------------------------------
# Package Repositories (proxy-cache or private mirror)
# -----------------------------------------------------------------------------

variable "rocky_repo_url" {
  description = "Base URL for Rocky 9 repos (BaseOS, AppStream, EPEL via proxy-cache or private mirror)"
  type        = string

  validation {
    condition     = can(regex("^https?://", var.rocky_repo_url))
    error_message = "rocky_repo_url must be a valid HTTP(S) URL."
  }
}

variable "epel_repo_url" {
  description = "Full base URL for EPEL 9 (e.g., https://epel.example.com/epel/9/Everything/x86_64). If empty, falls back to <rocky_repo_url>/epel/9/Everything/x86_64."
  type        = string
  default     = ""

  validation {
    condition     = var.epel_repo_url == "" || can(regex("^https?://", var.epel_repo_url))
    error_message = "epel_repo_url must be a valid HTTP(S) URL or empty."
  }
}

variable "rke2_repo_url" {
  description = "Base URL for RKE2 repos (common + versioned, via proxy-cache or private mirror)"
  type        = string

  validation {
    condition     = can(regex("^https?://", var.rke2_repo_url))
    error_message = "rke2_repo_url must be a valid HTTP(S) URL."
  }
}

variable "private_ca_pem" {
  description = "PEM-encoded CA certificate chain for repo/registry TLS trust"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("-----BEGIN CERTIFICATE-----[\\s\\S]+-----END CERTIFICATE-----", var.private_ca_pem))
    error_message = "private_ca_pem must contain a complete PEM certificate block."
  }
}

# -----------------------------------------------------------------------------
# Builder VM
# -----------------------------------------------------------------------------

variable "builder_cpu" {
  description = "vCPUs for utility VM (more = faster dnf inside virt-customize)"
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
  description = "Prefix for golden image name"
  type        = string
  default     = "rke2-rocky9-golden"
}

variable "image_name_override" {
  description = "Full image name override (set by CI pipeline). When set, replaces the auto-generated name entirely."
  type        = string
  default     = ""
}

variable "ssh_authorized_keys" {
  description = "SSH keys for utility VM (debug access, NOT baked into golden image)"
  type        = list(string)
  default     = []
}

variable "ntp_servers" {
  description = "NTP servers to bake into the golden image chrony config. Required for airgapped networks without public NTP reachability. Empty list leaves distro defaults (pool.ntp.org)."
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
