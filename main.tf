# -----------------------------------------------------------------------------
# Base cloud image (temporary — used only by the builder VM)
# -----------------------------------------------------------------------------

resource "harvester_image" "base" {
  name               = "golden-builder-${var.distro}-base"
  namespace          = var.vm_namespace
  display_name       = "golden-builder-${var.distro}-base"
  source_type        = "download"
  url                = local.builder_image_url
  storage_class_name = "harvester-longhorn"

  timeouts {
    create = "30m"
  }
}

# -----------------------------------------------------------------------------
# Cloud-init Secret (exceeds KubeVirt 2048 byte inline limit)
# -----------------------------------------------------------------------------

resource "kubernetes_secret" "cloudinit" {
  metadata {
    name      = "${local.image_name_prefix}-builder-cloudinit"
    namespace = var.vm_namespace
  }

  data = {
    userdata = templatefile("${path.module}/templates/cloud-init.yaml.tpl", {
      ssh_authorized_keys = var.ssh_authorized_keys
      cloud_image_url     = local.cloud_image_url
      private_ca_pem      = var.private_ca_pem
      has_private_ca      = local.has_private_ca
      repo_mirror_url     = var.repo_mirror_url
      cis_profile_id      = local.cis_profile_id
      cis_tailoring_file  = var.cis_tailoring_file
      distro              = var.distro
      distro_config       = local.distro_config
      image_name_prefix   = local.image_name_prefix
    })
  }
}

# -----------------------------------------------------------------------------
# Utility VM — runs virt-customize and serves result via HTTP
# -----------------------------------------------------------------------------

resource "harvester_virtualmachine" "utility" {
  name      = "${local.image_name_prefix}-builder"
  namespace = var.vm_namespace
  cpu       = var.builder_cpu
  memory    = var.builder_memory

  run_strategy = "RerunOnFailure"
  hostname     = "golden-builder"
  machine_type = "q35"
  efi          = true
  secure_boot  = false

  network_interface {
    name           = "nic-1"
    network_name   = "${var.harvester_network_namespace}/${var.harvester_network_name}"
    wait_for_lease = true
  }

  disk {
    name        = "rootdisk"
    type        = "disk"
    size        = var.builder_disk_size
    bus         = "virtio"
    boot_order  = 1
    image       = harvester_image.base.id
    auto_delete = true
  }

  cloudinit {
    user_data_secret_name = kubernetes_secret.cloudinit.metadata[0].name
  }

  timeouts {
    create = "30m"
  }
}
