# Option B: Packer + Kickstart with oscap-anaconda-addon

## Overview

This document describes the graduation path from the current virt-customize
approach (Option A) to a Packer + Kickstart build that applies CIS hardening
**during OS installation** via the `oscap-anaconda-addon`.

## Why Graduate to Option B?

| Aspect | Option A (current) | Option B (Packer) |
|--------|-------------------|-------------------|
| Hardening timing | Post-install remediation | Install-time (no vulnerability window) |
| Partitioning | Default cloud image layout | CIS-compliant partitions (separate /home, /var, /var/log, /var/log/audit, /tmp) |
| Audit compliance | "Remediated after the fact" | "Built compliant from day one" |
| Reproducibility | Depends on cloud image state | Full control from ISO |
| Build location | Inside Harvester (utility VM) | Local QEMU or CI runner |

## When to Switch

- Auditors require install-time hardening evidence
- CIS controls that require specific partitioning (1.1.x rules) are needed
- You need to support multiple OS versions or custom kernel configs
- CI/CD pipeline for image building is established

## Architecture

```
Rocky 9 Minimal ISO
    |
    v
Packer (QEMU builder) on CI runner or build VM
  + Kickstart with %addon com_redhat_oscap (CIS L1)
  + Shell provisioners (qemu-guest-agent, cloud-init, CA trust)
    |
    v
Compressed qcow2 artifact
    |
    v
Upload to Harbor as OCI artifact (or HTTP-served)
    |
    v
Harvester VirtualMachineImage CRD (sourceType: download)
    |
    v
Terraform provisions VMs from golden image
```

## Prerequisites

- Build VM with nested virtualization (or bare-metal CI runner)
- `packer`, `qemu-system-x86_64`, `qemu-img` installed
- Rocky 9 Minimal ISO available (via proxy-cache or local mirror)
- Network access to private repos during build

## Packer Template

```hcl
# rocky9-cis.pkr.hcl

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

variable "iso_url" {
  type    = string
  default = "https://dl.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9-latest-x86_64-minimal.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:XXXXXXXX"
}

variable "private_ca_pem" {
  type      = string
  sensitive = true
}

source "qemu" "rocky9_cis" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "output"
  vm_name          = "rocky9-cis-golden.qcow2"
  format           = "qcow2"
  disk_size        = "40G"
  memory           = 4096
  cpus             = 4
  accelerator      = "kvm"
  headless         = true

  http_directory = "http"
  http_port_min  = 8100
  http_port_max  = 8150

  boot_wait    = "5s"
  boot_command = [
    "<tab> inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg<enter>"
  ]

  communicator     = "ssh"
  ssh_username     = "root"
  ssh_password     = "packer-temp-password"
  ssh_timeout      = "30m"
  shutdown_command = "shutdown -P now"
}

build {
  sources = ["source.qemu.rocky9_cis"]

  # Install private CA
  provisioner "file" {
    source      = "files/private-ca.pem"
    destination = "/etc/pki/ca-trust/source/anchors/private-ca.pem"
  }

  provisioner "shell" {
    inline = [
      "update-ca-trust",

      # Install qemu-guest-agent and cloud-init
      "dnf install -y qemu-guest-agent cloud-init cloud-utils-growpart",
      "systemctl enable qemu-guest-agent",

      # Verify CIS compliance (oscap-anaconda-addon already applied during install)
      "oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_server_l1 --report /var/log/cis-report.html /usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml || true",

      # Clean up for templating
      "cloud-init clean --logs",
      "truncate -s 0 /etc/machine-id",
      "rm -f /etc/ssh/ssh_host_*",
      "rm -f /etc/udev/rules.d/70-persistent-*",
      "dnf clean all",
      "rm -rf /var/cache/dnf/*",

      # Remove packer temp password
      "passwd -d root",
      "passwd -l root",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "qemu-img convert -c -O qcow2 output/rocky9-cis-golden.qcow2 output/rocky9-cis-golden-compressed.qcow2",
      "mv output/rocky9-cis-golden-compressed.qcow2 output/rocky9-cis-golden.qcow2",
    ]
  }
}
```

## Kickstart File

```
# http/ks.cfg — Rocky 9 CIS L1 Server Kickstart

# System
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
rootpw --plaintext packer-temp-password
selinux --enforcing
firewall --disabled

# Network (DHCP during install, cloud-init handles production config)
network --bootproto=dhcp --device=link --activate --onboot=on

# Partitioning (CIS-compliant separate mounts)
zerombr
clearpart --all --initlabel
autopart --type=lvm --encrypted=no

# NOTE: For strict CIS compliance, replace autopart with explicit:
# part /boot     --fstype=xfs --size=1024
# part /boot/efi --fstype=efi --size=600
# part pv.01     --size=1 --grow
# volgroup vg0 pv.01
# logvol /              --vgname=vg0 --size=8192  --name=root
# logvol /home          --vgname=vg0 --size=4096  --name=home
# logvol /tmp           --vgname=vg0 --size=2048  --name=tmp
# logvol /var           --vgname=vg0 --size=8192  --name=var
# logvol /var/log       --vgname=vg0 --size=4096  --name=varlog
# logvol /var/log/audit --vgname=vg0 --size=2048  --name=varlogaudit
# logvol /var/tmp       --vgname=vg0 --size=2048  --name=vartmp
# logvol swap           --vgname=vg0 --size=2048  --name=swap

# Packages
%packages
@^minimal-environment
scap-security-guide
openscap-scanner
audit
policycoreutils-python-utils
iptables-services
%end

# CIS hardening during installation
%addon com_redhat_oscap
  content-type = scap-security-guide
  profile = cis_server_l1
%end

# Post-install
%post --log=/root/ks-post.log
# Enable audit
systemctl enable auditd

# Disable firewalld in favor of iptables
systemctl disable firewalld || true
systemctl enable iptables
%end

# Reboot after install
reboot
```

## Upload to Harvester

After Packer produces the qcow2, upload to Harvester:

### Option 1: Via Harbor (recommended for CI/CD)

```bash
# Push qcow2 as OCI artifact to Harbor
oras push harbor.example.com/library/rocky9-cis-golden:$(date +%Y%m%d) \
  output/rocky9-cis-golden.qcow2:application/octet-stream

# Create VirtualMachineImage pointing to Harbor
kubectl apply -f - <<EOF
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: rocky9-cis-golden-$(date +%Y%m%d)
  namespace: rke2-prod
spec:
  displayName: "rocky9-cis-golden-$(date +%Y%m%d)"
  sourceType: download
  url: "https://harbor.example.com/v2/library/rocky9-cis-golden/blobs/<digest>"
  storageClassParameters:
    migratable: "true"
    numberOfReplicas: "3"
    staleReplicaTimeout: "30"
EOF
```

### Option 2: Via HTTP (current pattern)

Serve the qcow2 from any HTTP endpoint accessible to the Harvester cluster,
then create the VirtualMachineImage CRD as above.

## CI/CD Pipeline (GitLab)

```yaml
# .gitlab-ci.yml
stages:
  - build
  - upload
  - register

build-golden-image:
  stage: build
  tags: [bare-metal]  # needs KVM
  script:
    - packer init rocky9-cis.pkr.hcl
    - packer build -var "private_ca_pem=$(cat private-ca.pem)" rocky9-cis.pkr.hcl
  artifacts:
    paths:
      - output/rocky9-cis-golden.qcow2
    expire_in: 1 day

upload-to-harbor:
  stage: upload
  script:
    - oras push harbor.example.com/library/rocky9-cis-golden:${CI_PIPELINE_ID} output/rocky9-cis-golden.qcow2:application/octet-stream

register-in-harvester:
  stage: register
  script:
    - |
      kubectl --kubeconfig=$HARVESTER_KUBECONFIG apply -f - <<EOF
      apiVersion: harvesterhci.io/v1beta1
      kind: VirtualMachineImage
      metadata:
        name: rocky9-cis-golden-${CI_PIPELINE_ID}
        namespace: rke2-prod
      spec:
        displayName: "rocky9-cis-golden-${CI_PIPELINE_ID}"
        sourceType: download
        url: "https://harbor.example.com/v2/library/rocky9-cis-golden/blobs/sha256:TODO"
      EOF
```

## Migration Checklist

- [ ] Build VM or CI runner with nested virt / KVM access
- [ ] Rocky 9 Minimal ISO mirrored to proxy-cache
- [ ] Packer installed on build environment
- [ ] Kickstart tested with correct CIS profile
- [ ] qcow2 boots successfully on Harvester
- [ ] CIS compliance report shows acceptable score
- [ ] Harbor repository created for image artifacts
- [ ] CI/CD pipeline configured and tested
- [ ] Old virt-customize builder decommissioned
