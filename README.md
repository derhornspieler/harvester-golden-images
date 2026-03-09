# Harvester Golden Image Builder

[![CI](https://github.com/example-user/harvester-golden-image/actions/workflows/ci.yml/badge.svg)](https://github.com/example-user/harvester-golden-image/actions/workflows/ci.yml)

Multi-distro CIS-hardened golden image builder for [Harvester HCI](https://harvesterhci.io/). Uses a temporary Rocky 9 builder VM running `virt-customize` + OpenSCAP to bake CIS Level 1/2 hardening into cloud images, then imports them directly into Harvester.

## Supported Distros

| Distro | Cloud Image (qcow2) | CIS Profile | Status |
|--------|---------------------|-------------|--------|
| Rocky Linux 9 | [`Rocky-9-GenericCloud-Base.latest.x86_64.qcow2`](https://dl.rockylinux.org/pub/rocky/9/images/x86_64/) | CIS L1/L2 Server/Workstation | Tested |
| Debian 12 (Bookworm) | [`debian-12-generic-amd64.qcow2`](https://cloud.debian.org/images/cloud/bookworm/latest/) | CIS L1/L2 Server/Workstation | Tested |
| Ubuntu 24.04 (Noble) | [`ubuntu-24.04-server-cloudimg-amd64.img`](https://cloud-images.ubuntu.com/releases/noble/release/) | CIS L1/L2 Server/Workstation | Experimental |
| Fedora 42 | [`Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2`](https://dl.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/) | CIS L1/L2 Server/Workstation | Draft profiles |

## Versions

| Component | Version |
|-----------|---------|
| Terraform | `>= 1.5.0` (tested with `1.14.5`) |
| Provider: `harvester/harvester` | `~> 0.6` (locked to `0.6.7`) |
| Provider: `hashicorp/kubernetes` | `~> 2.0` (locked to `2.36.0`) |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  build.sh (orchestrator)                                │
│                                                         │
│  1. terraform apply    → Creates builder VM (Rocky 9)   │
│  2. Wait for HTTP /ready                                │
│  3. Download CIS report                                 │
│  4. kubectl apply VMImage → Import qcow2 into Harvester │
│  5. Wait for import complete                            │
│  6. terraform destroy  → Clean up builder VM            │
└─────────────────────────────────────────────────────────┘

Builder VM (Rocky 9) internals:
  ┌──────────────────────────────────────────┐
  │  1. Install libguestfs-tools             │
  │  2. Download target distro cloud image   │
  │  3. virt-customize:                      │
  │     - Inject private CA (optional)       │
  │     - Configure repos (proxy-cache)      │
  │     - Install packages (SSG, oscap, etc) │
  │     - Run CIS remediation via oscap      │
  │     - Configure firewall (iptables)      │
  │     - Rebuild initramfs (RHEL only)      │
  │  4. Extract CIS compliance report        │
  │  5. Serve golden.qcow2 via HTTP :8080    │
  └──────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- `terraform` >= 1.5.0
- `kubectl` with access to a Harvester cluster
- `jq`
- Harvester kubeconfig saved as `kubeconfig-harvester.yaml`

### Build

```bash
# Clone and configure
git clone https://github.com/example-user/harvester-golden-image.git
cd harvester-golden-image
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Harvester details

# Build Rocky 9 golden image (default)
./build.sh build

# Build other distros
./build.sh build -f distros/debian12.tfvars
./build.sh build -f distros/ubuntu2404.tfvars
./build.sh build -f distros/fedora42.tfvars
```

### Manage Images

```bash
# List existing golden images in Harvester
./build.sh list

# Delete an old image
./build.sh delete rocky9-cis-golden-20260308

# Manual cleanup if a build fails mid-way
./build.sh destroy
```

## Configuration

Copy the appropriate `.tfvars.example` file and fill in your values:

| File | Purpose |
|------|---------|
| `terraform.tfvars.example` | Main config (defaults to Rocky 9) |
| `distros/rocky9.tfvars.example` | Rocky Linux 9 specific |
| `distros/debian12.tfvars.example` | Debian 12 specific |
| `distros/ubuntu2404.tfvars.example` | Ubuntu 24.04 specific |
| `distros/fedora42.tfvars.example` | Fedora 42 specific |

### Key Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `distro` | Target distro (`rocky9`, `debian12`, `ubuntu2404`, `fedora42`) | `rocky9` |
| `cis_level` | CIS hardening level (`l1`, `l2`) | `l1` |
| `cis_type` | CIS target type (`server`, `workstation`) | `server` |
| `cloud_image_url` | Override cloud image URL (empty = upstream default) | `""` |
| `repo_mirror_url` | Package repo proxy-cache URL (empty = upstream) | `""` |
| `private_ca_pem` | PEM CA cert for private mirror TLS trust | `""` |
| `builder_cpu` | Builder VM vCPUs | `4` |
| `builder_memory` | Builder VM memory | `4Gi` |
| `builder_disk_size` | Builder VM disk (needs 2x qcow2 + tools) | `30Gi` |

## CIS Hardening Details

The builder applies CIS hardening using OpenSCAP's `oscap xccdf generate fix` approach:

1. Installs SCAP Security Guide (SSG) and OpenSCAP into the target image
2. Generates a shell remediation script from the CIS profile
3. Executes the remediation script inside the image via `virt-customize`
4. Generates an HTML compliance report (downloaded to `reports/`)

### Known Limitations

- **libguestfs on Rocky 9 misdetects Debian guests as RHEL** — workaround: uses explicit `apt-get` commands instead of `--install`/`--update` for Debian-family images
- **libguestfs appliance cannot resolve private DNS** — workaround: uses upstream repos during build, then bakes proxy-cache sources into the final image
- **Debian `/bin/sh` is dash (no pipefail)** — workaround: uses `bash` explicitly for scripts
- **SSG package names differ by distro** — handled in `locals.tf` distro catalog

## Project Structure

```
.
├── build.sh                      # Build orchestrator (6-step lifecycle)
├── locals.tf                     # Distro catalog (packages, paths, profiles)
├── main.tf                       # Harvester resources (image, VM, cloud-init)
├── variables.tf                  # Input variables with validation
├── outputs.tf                    # Terraform outputs
├── providers.tf                  # Provider configuration
├── versions.tf                   # Terraform + provider version constraints
├── terraform.tfvars.example      # Example configuration
├── templates/
│   └── cloud-init.yaml.tpl       # Builder VM cloud-init template
├── distros/
│   ├── rocky9.tfvars.example     # Rocky 9 example config
│   ├── debian12.tfvars.example   # Debian 12 example config
│   ├── ubuntu2404.tfvars.example # Ubuntu 24.04 example config
│   └── fedora42.tfvars.example   # Fedora 42 example config
├── docs/
│   └── option-b-packer-kickstart.md  # Future: Packer + Kickstart approach
├── reports/                      # CIS compliance reports (gitignored)
└── .github/workflows/
    ├── ci.yml                    # Lint, validate, security scan
    └── release.yml               # GitHub Release on tag
```

## Graduation Path

See [docs/option-b-packer-kickstart.md](docs/option-b-packer-kickstart.md) for the future migration path from virt-customize (Option A) to Packer + Kickstart with `oscap-anaconda-addon` (Option B), which provides install-time CIS hardening and CIS-compliant partitioning.

## License

MIT
