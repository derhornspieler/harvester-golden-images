# CIS-Hardened Golden Images

Pre-baked, CIS-hardened cloud images for [Harvester HCI](https://harvesterhci.io/). Uses a temporary Rocky 9 builder VM running `virt-customize` + OpenSCAP to apply CIS Level 1 or Level 2 hardening to multi-distro cloud images, then imports them directly into Harvester.

## Supported Distros

| Distro | Cloud Image | CIS Profile | Status |
|--------|-------------|-------------|--------|
| Rocky Linux 9 | [`Rocky-9-GenericCloud-Base.latest.x86_64.qcow2`](https://dl.rockylinux.org/pub/rocky/9/images/x86_64/) | CIS L1/L2 Server/Workstation | Tested |
| Debian 12 (Bookworm) | [`debian-12-generic-amd64.qcow2`](https://cloud.debian.org/images/cloud/bookworm/latest/) | CIS L1/L2 Server/Workstation | Tested |
| Ubuntu 24.04 (Noble) | [`ubuntu-24.04-server-cloudimg-amd64.img`](https://cloud-images.ubuntu.com/releases/noble/release/) | CIS L1/L2 Server/Workstation | **Experimental** |
| Fedora 42 | [`Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2`](https://dl.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/) | CIS L1/L2 Server/Workstation | **Experimental** -- draft CIS profiles |

## Architecture

The builder uses a two-VM approach: a Rocky 9 utility VM runs `virt-customize` (from `libguestfs-tools`) to modify the target distro's cloud image offline, without booting it. This avoids cross-distro package manager issues and keeps the build environment consistent regardless of the target distro.

```
build.sh (orchestrator)

  1. terraform apply    --> Creates builder VM (Rocky 9)
  2. Wait for HTTP /ready
  3. Download CIS report
  4. kubectl apply VMImage --> Import qcow2 into Harvester
  5. Wait for import complete
  6. terraform destroy  --> Clean up builder VM

Builder VM (Rocky 9) internals:
  1. Install libguestfs-tools
  2. Download target distro cloud image
  3. virt-customize:
     - Inject private CA certificate (optional)
     - Configure package repos (proxy-cache or upstream)
     - Install packages (SSG, OpenSCAP, distro extras)
     - Generate CIS remediation script via oscap
     - Execute CIS remediation inside the image
     - Configure firewall (iptables)
     - Rebuild initramfs (RHEL-family only)
  4. Generate CIS compliance report (HTML)
  5. Serve golden.qcow2 via HTTP :8080
```

The builder VM is always Rocky 9, even when building Debian or Ubuntu images. The `virt-customize` tool operates on the target image's filesystem directly, so the builder's own OS does not need to match the target.

## Quick Start

```bash
cd harvester-golden-images/cis

# Copy the example config
cp terraform.tfvars.example terraform.tfvars
# Edit with your Harvester connection details and optional proxy-cache URLs
vi terraform.tfvars

# Build Rocky 9 golden image (default)
./build.sh build

# Build other distros using per-distro tfvars
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
| `cis_tailoring_file` | Optional XCCDF tailoring file for CIS exceptions | `""` |
| `cloud_image_url` | Override cloud image URL (empty = upstream default) | `""` |
| `repo_mirror_url` | Package repo proxy-cache URL (empty = upstream) | `""` |
| `private_ca_pem` | PEM CA cert for private mirror TLS trust | `""` |
| `builder_image_url` | Override builder VM image URL (must be Rocky 9) | `""` |
| `builder_cpu` | Builder VM vCPUs | `4` |
| `builder_memory` | Builder VM memory | `4Gi` |
| `builder_disk_size` | Builder VM disk (needs 2x qcow2 + tools) | `30Gi` |
| `image_name_prefix` | Prefix for golden image name (auto: `<distro>-cis-golden`) | `""` |
| `ssh_authorized_keys` | SSH keys for builder VM debug (NOT baked into golden image) | `[]` |

## CIS Hardening Details

The builder applies CIS hardening using OpenSCAP's `oscap xccdf generate fix` approach:

1. Installs the SCAP Security Guide (SSG) and OpenSCAP scanner into the target image via `virt-customize`
2. Generates a shell remediation script from the selected CIS profile (level + type)
3. Executes the remediation script inside the image
4. Generates an HTML compliance report (downloaded to `../reports/`)

### SSG Package Names by Distro

The SSG package name varies across distributions. This is handled automatically in `locals.tf`:

| Distro | SSG Package | Datastream |
|--------|-------------|------------|
| Rocky 9 | `scap-security-guide` | `ssg-rl9-ds.xml` |
| Debian 12 | `ssg-debian` | `ssg-debian12-ds.xml` (falls back to `ssg-debian11-ds.xml`) |
| Ubuntu 24.04 | `ssg-debderived` | `ssg-ubuntu2404-ds.xml` (falls back to `ssg-ubuntu2204-ds.xml`) |
| Fedora 42 | `scap-security-guide` | `ssg-fedora-ds.xml` |

### CIS Profile ID Format

Profile IDs differ between RHEL-family and Debian-family distros:

- RHEL-family: `xccdf_org.ssgproject.content_profile_cis_server_l1`
- Debian-family: `xccdf_org.ssgproject.content_profile_cis_level1_server`

This is handled automatically based on the `distro` variable.

## Known Limitations

### libguestfs on Rocky 9 misdetects Debian guests as RHEL

When processing Debian or Ubuntu images, `virt-customize --update` and `--install` invoke `dnf` instead of `apt-get`. Workaround: the builder uses explicit `--run-command '/usr/bin/apt-get ...'` for Debian-family images instead of the `--install` and `--update` convenience flags. RHEL-family guests work correctly with the built-in flags.

### libguestfs appliance cannot resolve private DNS

The libguestfs appliance (a minimal kernel that runs `virt-customize` operations) cannot resolve private DNS names (e.g., your proxy-cache hostname). Workaround: the builder uses upstream distribution repos (e.g., `deb.debian.org`) during the `virt-customize` phase, then bakes proxy-cache sources into the final image for runtime use.

### Debian /bin/sh is dash (no pipefail)

On Debian-family images, `/bin/sh` is `dash`, which does not support `set -o pipefail`. Workaround: the builder uses `--run-command 'bash /script.sh'` instead of `--run /script.sh` to ensure bash features are available.

### terraform.tfvars auto-loads and overrides distro tfvars

Terraform automatically loads `terraform.tfvars` when present. If `cloud_image_url` is set in `terraform.tfvars` (e.g., for Rocky 9), it overrides the value from distro-specific tfvars files. Workaround: per-distro tfvars files must explicitly set `cloud_image_url = ""` to fall through to their distro default in `locals.tf`.

## Project Structure

```
cis/
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
└── docs/
    └── option-b-packer-kickstart.md  # Future: Packer + Kickstart approach
```

## Graduation Path

The current approach (Option A: virt-customize + oscap) applies CIS hardening post-install. This works well but cannot achieve CIS-compliant disk partitioning since the filesystem layout is already set in the cloud image.

See [docs/option-b-packer-kickstart.md](docs/option-b-packer-kickstart.md) for the planned migration to Packer + Kickstart with `oscap-anaconda-addon` (Option B), which provides install-time CIS hardening including compliant partitioning.

## License

MIT
