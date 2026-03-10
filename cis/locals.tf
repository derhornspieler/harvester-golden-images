# -----------------------------------------------------------------------------
# Per-Distro Configuration
# -----------------------------------------------------------------------------
# All distro-specific values are centralized here. The cloud-init template
# and build script reference these via templatefile variables.
# -----------------------------------------------------------------------------

locals {
  # -------------------------------------------------------------------------
  # Distro catalog — add new distros here
  # -------------------------------------------------------------------------
  distro_catalog = {
    rocky9 = {
      family           = "rhel"
      pkg_manager      = "dnf"
      default_image    = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
      ssg_package      = "scap-security-guide"
      oscap_package    = "openscap-scanner"
      datastream       = "/usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml"
      alt_datastreams  = ["ssg-cs9-ds.xml", "ssg-rhel9-ds.xml"]
      cis_profile_fmt  = "xccdf_org.ssgproject.content_profile_cis_%s_%s" # type, level
      extra_packages   = "policycoreutils-python-utils,audit,cloud-init,cloud-utils-growpart"
      ca_trust_dir     = "/etc/pki/ca-trust/source/anchors"
      ca_trust_cmd     = "update-ca-trust"
      selinux          = true
      firewall_pkg     = "iptables-services"
      disable_firewall = "systemctl disable firewalld || true"
      enable_firewall  = "systemctl enable iptables"
    }
    debian13 = {
      family           = "debian"
      pkg_manager      = "apt"
      default_image    = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
      ssg_package      = "ssg-debian"
      oscap_package    = "openscap-scanner"
      datastream       = "/usr/share/xml/scap/ssg/content/ssg-debian13-ds.xml"
      alt_datastreams  = ["ssg-debian12-ds.xml"]
      cis_profile_fmt  = "xccdf_org.ssgproject.content_profile_cis_level%s_%s" # level_number, type
      extra_packages   = "apt-transport-https,ca-certificates,cloud-init,cloud-guest-utils,auditd"
      ca_trust_dir     = "/usr/local/share/ca-certificates"
      ca_trust_cmd     = "/usr/sbin/update-ca-certificates"
      selinux          = false
      firewall_pkg     = "iptables-persistent"
      disable_firewall = "true"
      enable_firewall  = "systemctl enable netfilter-persistent || true"
    }
    ubuntu2404 = {
      family           = "debian"
      pkg_manager      = "apt"
      default_image    = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
      ssg_package      = "ssg-debderived"
      oscap_package    = "openscap-scanner"
      datastream       = "/usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml"
      alt_datastreams  = ["ssg-ubuntu2204-ds.xml"]
      cis_profile_fmt  = "xccdf_org.ssgproject.content_profile_cis_level%s_%s" # level_number, type
      extra_packages   = "apt-transport-https,ca-certificates,cloud-init,cloud-guest-utils,auditd"
      ca_trust_dir     = "/usr/local/share/ca-certificates"
      ca_trust_cmd     = "/usr/sbin/update-ca-certificates"
      selinux          = false
      firewall_pkg     = "iptables-persistent"
      disable_firewall = "true"
      enable_firewall  = "systemctl enable netfilter-persistent || true"
    }
  }

  # -------------------------------------------------------------------------
  # Resolved values for the selected distro
  # -------------------------------------------------------------------------
  distro_config = local.distro_catalog[var.distro]

  # Resolve the target distro cloud image URL (downloaded inside the builder VM)
  cloud_image_url = var.cloud_image_url != "" ? var.cloud_image_url : local.distro_config.default_image

  # Builder VM always runs Rocky 9 (it needs dnf + libguestfs-tools)
  builder_image_url = var.builder_image_url != "" ? var.builder_image_url : local.distro_catalog.rocky9.default_image

  # Resolve the image name prefix
  image_name_prefix = var.image_name_prefix != "" ? var.image_name_prefix : "${var.distro}-cis-golden"

  # Build the CIS profile ID (format differs between RHEL-family and Debian-family)
  cis_level_num = var.cis_level == "l1" ? "1" : "2"
  cis_profile_id = (
    local.distro_config.family == "rhel"
    ? format(local.distro_config.cis_profile_fmt, var.cis_type, var.cis_level)
    : format(local.distro_config.cis_profile_fmt, local.cis_level_num, var.cis_type)
  )

  # Whether to inject private CA
  has_private_ca = var.private_ca_pem != ""
}
