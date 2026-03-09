# Harvester Golden Images

[![CI](https://github.com/example-user/harvester-golden-images/actions/workflows/ci.yml/badge.svg)](https://github.com/example-user/harvester-golden-images/actions/workflows/ci.yml)

Golden image builders for [Harvester HCI](https://harvesterhci.io/). Produces pre-configured, hardened QCOW2 images that are imported directly into Harvester for VM deployments.

## Image Types

| Image | Description | Distros | Status |
|-------|-------------|---------|--------|
| [CIS-Hardened](cis/) | Multi-distro base images with CIS Level 1/2 hardening via OpenSCAP | Rocky 9, Debian 12, Ubuntu 24.04\*, Fedora 42\* | Production / Experimental\* |
| [RKE2 Node](rke2/) | Rocky 9 images pre-baked for RKE2 Kubernetes nodes (20-30s boot) | Rocky 9 | Production |

\* Ubuntu 24.04 and Fedora 42 are experimental and not built by default.

## Quick Start

```bash
git clone https://github.com/example-user/harvester-golden-images.git
cd harvester-golden-images

# Configure each image type
cp cis/terraform.tfvars.example cis/terraform.tfvars
cp rke2/terraform.tfvars.example rke2/terraform.tfvars
# Edit both with your Harvester details, proxy-cache URLs, and CA certs

# Build all three production images (cis-rocky9, cis-debian12, rke2)
./build.sh build all

# Or build individually
./build.sh build cis-rocky9
./build.sh build cis-debian12
./build.sh build rke2

# Experimental images (not built by default)
./build.sh build cis-ubuntu2404
./build.sh build cis-fedora42

# List all golden images in Harvester
./build.sh list

# Delete an old image
./build.sh delete rocky9-cis-golden-20260309
```

## Architecture

Both image types share the same build pattern:

```
Operator runs ./build.sh
  |
  v
Terraform creates temporary builder VM (Rocky 9) on Harvester
  |
  v
Cloud-init runs virt-customize to bake config into target qcow2
  |
  v
Builder VM serves golden.qcow2 via HTTP :8080
  |
  v
build.sh creates VirtualMachineImage CRD -> Harvester imports image
  |
  v
Terraform destroys builder VM -> golden image remains in Harvester
```

## Versions

| Component | Version |
|-----------|---------|
| Terraform | `>= 1.5.0` (tested with `1.14.5`) |
| Provider: `harvester/harvester` | `~> 0.6` (locked `0.6.7`) |
| Provider: `hashicorp/kubernetes` | `~> 2.0` (locked `2.36.0`) |

## Cloud Image Sources

| Distro | Image | Source |
|--------|-------|--------|
| Rocky Linux 9 | `Rocky-9-GenericCloud-Base.latest.x86_64.qcow2` | [rockylinux.org](https://dl.rockylinux.org/pub/rocky/9/images/x86_64/) |
| Debian 12 (Bookworm) | `debian-12-generic-amd64.qcow2` | [cloud.debian.org](https://cloud.debian.org/images/cloud/bookworm/latest/) |
| Ubuntu 24.04 (Noble) | `ubuntu-24.04-server-cloudimg-amd64.img` | [cloud-images.ubuntu.com](https://cloud-images.ubuntu.com/releases/noble/release/) |
| Fedora 42 | `Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2` | [fedoraproject.org](https://dl.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/) |

## Project Structure

```
harvester-golden-images/
├── build.sh                    # Top-level orchestrator (builds all by default)
├── cis/                        # CIS-hardened multi-distro image builder
│   ├── build.sh                # CIS build script (supports -f distros/*.tfvars)
│   ├── main.tf                 # Terraform resources
│   ├── locals.tf               # Distro catalog (packages, paths, profiles)
│   ├── variables.tf            # Input variables
│   ├── templates/
│   │   └── cloud-init.yaml.tpl # Builder VM cloud-init
│   ├── distros/
│   │   ├── rocky9.tfvars.example
│   │   ├── debian12.tfvars.example
│   │   ├── ubuntu2404.tfvars.example
│   │   └── fedora42.tfvars.example
│   └── docs/
│       └── option-b-packer-kickstart.md
├── rke2/                       # RKE2-optimized Rocky 9 image builder
│   ├── build.sh                # RKE2 build script
│   ├── main.tf                 # Terraform resources
│   ├── variables.tf            # Input variables
│   └── templates/
│       └── cloud-init.yaml.tpl # Builder VM cloud-init
└── .github/workflows/
    ├── ci.yml                  # Unified CI (lint, validate, security scan)
    └── release.yml             # GitHub Release on tag
```

## Per-Image Documentation

- **[CIS-Hardened Images](cis/README.md)** -- Configuration, CIS profiles, known limitations, distro-specific notes
- **[RKE2 Node Images](rke2/README.md)** -- What gets baked in, networking, firewall rules, integration with RKE2 cluster Terraform

## Prerequisites

- `terraform` >= 1.5.0
- `kubectl` with access to a Harvester cluster
- `jq`
- Harvester kubeconfig saved as `kubeconfig-harvester.yaml` in each image directory

## License

MIT
