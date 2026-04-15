#cloud-config
# =============================================================================
# Multi-Distro CIS-Hardened Golden Image Builder — Utility VM Cloud-Init
# =============================================================================
# Target distro: ${distro}
# CIS profile:   ${cis_profile_id}
#
# This runs on the UTILITY VM (Rocky 9). It:
#   1. Installs libguestfs-tools on the utility VM
#   2. Downloads the target distro's cloud image
#   3. Runs virt-customize to bake CIS hardening + base config
#   4. Generates a CIS compliance report
#   5. Serves the result via HTTP on port 8080
# =============================================================================

%{ if length(ssh_authorized_keys) > 0 ~}
ssh_authorized_keys:
%{ for key in ssh_authorized_keys ~}
  - ${key}
%{ endfor ~}
%{ endif ~}

write_files:
%{ if has_private_ca ~}
# -------------------------------------------------------------------------
# Private CA trust (for proxy-cache / private mirror TLS)
# -------------------------------------------------------------------------
- path: /tmp/bake/private-ca.pem
  permissions: '0644'
  content: |
    ${indent(4, private_ca_pem)}
%{ endif ~}

%{ if distro_config.family == "rhel" && repo_mirror_url != "" ~}
# -------------------------------------------------------------------------
# RHEL-family repo files (proxy-cache)
# -------------------------------------------------------------------------
- path: /tmp/bake/baseos-private.repo
  permissions: '0644'
  content: |
%{ if distro == "rocky9" ~}
    [baseos-private]
    name=Rocky Linux 9 - BaseOS
    baseurl=${repo_mirror_url}/rocky/9/BaseOS/x86_64/os
    enabled=1
    gpgcheck=0

- path: /tmp/bake/appstream-private.repo
  permissions: '0644'
  content: |
    [appstream-private]
    name=Rocky Linux 9 - AppStream
    baseurl=${repo_mirror_url}/rocky/9/AppStream/x86_64/os
    enabled=1
    gpgcheck=0

- path: /tmp/bake/epel.repo
  permissions: '0644'
  content: |
    [epel]
    name=Extra Packages for Enterprise Linux 9
    baseurl=${epel_repo_url}
    enabled=1
    gpgcheck=0
%{ endif ~}
%{ if distro == "fedora42" ~}
    [fedora-private]
    name=Fedora 42
    baseurl=${repo_mirror_url}/fedora/linux/releases/42/Everything/x86_64/os
    enabled=1
    gpgcheck=0

- path: /tmp/bake/fedora-updates-private.repo
  permissions: '0644'
  content: |
    [fedora-updates-private]
    name=Fedora 42 - Updates
    baseurl=${repo_mirror_url}/fedora/linux/updates/42/Everything/x86_64
    enabled=1
    gpgcheck=0
%{ endif ~}
%{ endif ~}

%{ if distro_config.family == "debian" && repo_mirror_url != "" ~}
# -------------------------------------------------------------------------
# Debian-family mirror config
# -------------------------------------------------------------------------
- path: /tmp/bake/sources.list
  permissions: '0644'
  content: |
%{ if distro == "debian12" ~}
    deb ${repo_mirror_url}/debian bookworm main contrib
    deb ${repo_mirror_url}/debian bookworm-updates main contrib
    deb ${repo_mirror_url}/debian-security bookworm-security main contrib
%{ endif ~}
%{ if distro == "ubuntu2404" ~}
    deb ${repo_mirror_url}/ubuntu noble main restricted universe
    deb ${repo_mirror_url}/ubuntu noble-updates main restricted universe
    deb ${repo_mirror_url}/ubuntu noble-security main restricted universe
%{ endif ~}
%{ endif ~}

# -------------------------------------------------------------------------
# Config files to bake into the golden image
# -------------------------------------------------------------------------
%{ if length(ntp_servers) > 0 ~}
- path: /tmp/bake/chrony.conf
  permissions: '0644'
  content: |
%{ for s in ntp_servers ~}
    server ${s} iburst
%{ endfor ~}
    driftfile /var/lib/chrony/drift
    makestep 1.0 3
    rtcsync
    logdir /var/log/chrony
%{ endif ~}

- path: /tmp/bake/virtio.conf
  permissions: '0644'
  content: |
    hostonly=no
    hostonly_cmdline=no
    force_drivers+=" virtio_blk virtio_net virtio_scsi virtio_pci virtio_console "

- path: /tmp/bake/iptables
  permissions: '0644'
  content: |
    *filter
    :INPUT DROP [0:0]
    :FORWARD DROP [0:0]
    :OUTPUT DROP [0:0]
    # --- INPUT rules (general-purpose server) ---
    -A INPUT -i lo -j ACCEPT
    -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    -A INPUT -p icmp -j ACCEPT
    -A INPUT -p tcp --dport 22 -j ACCEPT
    -A INPUT -p tcp --dport 53 -j ACCEPT
    -A INPUT -p udp --dport 53 -j ACCEPT
    -A INPUT -p tcp --dport 80 -j ACCEPT
    -A INPUT -p tcp --dport 443 -j ACCEPT
    -A INPUT -p tcp --dport 88 -j ACCEPT
    -A INPUT -p udp --dport 88 -j ACCEPT
    -A INPUT -p tcp --dport 464 -j ACCEPT
    -A INPUT -p udp --dport 464 -j ACCEPT
    -A INPUT -p tcp --dport 389 -j ACCEPT
    -A INPUT -p tcp --dport 636 -j ACCEPT
    -A INPUT -p udp --dport 123 -j ACCEPT
    # --- OUTPUT rules (airgap enforcement — RFC1918 safety net) ---
    -A OUTPUT -o lo -j ACCEPT
    -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
    -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
    -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
    -A OUTPUT -p udp --dport 53 -j ACCEPT
    -A OUTPUT -p tcp --dport 53 -j ACCEPT
    -A OUTPUT -p udp --dport 123 -j ACCEPT
    -A OUTPUT -p icmp -j ACCEPT
    COMMIT

%{ if distro_config.family == "rhel" ~}
- path: /tmp/bake/fix-grub.sh
  permissions: '0755'
  content: |
    #!/bin/bash
    set -euo pipefail
    ROOT_UUID=$(blkid -s UUID -o value "$(findmnt -n -o SOURCE /)" 2>/dev/null) || \
    ROOT_UUID=$(blkid -l -t PARTLABEL="p.lxroot" -s UUID -o value 2>/dev/null) || \
    ROOT_UUID=$(blkid -l -t LABEL="rocky" -s UUID -o value 2>/dev/null) || \
    { echo "ERROR: Could not determine root filesystem UUID"; exit 1; }
    echo "Fixing GRUB entries with correct root UUID: $ROOT_UUID"
    for f in /boot/loader/entries/*.conf; do
      echo "  Processing: $f"
      sed -i "s|root=UUID=[^ ]*|root=UUID=$${ROOT_UUID}|g" "$f"
      if grep -q guestfs_network "$f"; then
        echo "    -> Cleaning libguestfs contamination"
        sed -i 's| guestfs_network=[^ ]*||g' "$f"
        sed -i 's| TERM=vt220||g' "$f"
        sed -i 's| selinux=0||g' "$f"
        sed -i 's| cgroup_disable=[^ ]*||g' "$f"
        sed -i 's| usbcore\.nousb||g' "$f"
        sed -i 's| cryptomgr\.notests||g' "$f"
        sed -i 's| tsc=[^ ]*||g' "$f"
        sed -i 's| 8250\.nr_uarts=[^ ]*||g' "$f"
        sed -i 's| edd=off||g' "$f"
        sed -i 's| udevtimeout=[^ ]*||g' "$f"
        sed -i 's| udev\.event-timeout=[^ ]*||g' "$f"
        sed -i 's| printk\.time=[^ ]*||g' "$f"
        sed -i 's| panic=[^ ]*||g' "$f"
        sed -i 's| quiet||g' "$f"
      fi
      if ! grep -q 'net.ifnames=0' "$f"; then
        sed -i '/^options /s/$/ net.ifnames=0/' "$f"
      fi
    done
    echo "GRUB fix complete."
%{ endif ~}

# -------------------------------------------------------------------------
# CIS remediation script (runs inside the golden image via virt-customize)
# -------------------------------------------------------------------------
- path: /tmp/bake/cis-remediate.sh
  permissions: '0755'
  content: |
    #!/bin/bash
    set -euo pipefail
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    PROFILE="${cis_profile_id}"
    DATASTREAM="${distro_config.datastream}"

    echo "=== CIS Remediation: profile=$PROFILE datastream=$DATASTREAM ==="

    if [[ ! -f "$DATASTREAM" ]]; then
      echo "WARNING: Primary datastream not found at $DATASTREAM"
%{ for alt in distro_config.alt_datastreams ~}
      alt_path="/usr/share/xml/scap/ssg/content/${alt}"
      if [[ -f "$alt_path" ]]; then
        DATASTREAM="$alt_path"
        echo "Found alternative: $DATASTREAM"
      fi
%{ endfor ~}
    fi

    if [[ ! -f "$DATASTREAM" ]]; then
      echo "ERROR: No SCAP datastream found. Listing available:"
      ls -la /usr/share/xml/scap/ssg/content/ 2>/dev/null || echo "  (directory does not exist)"
      exit 1
    fi

%{ if cis_tailoring_file != "" ~}
    TAILORING="--tailoring-file /tmp/bake/${cis_tailoring_file}"
%{ else ~}
    TAILORING=""
%{ endif ~}

    # Generate fix script (more reliable than --remediate in chroot/guestfs)
    oscap xccdf generate fix \
      --template urn:xccdf:fix:script:sh \
      --profile "$PROFILE" \
      $TAILORING \
      --output /tmp/cis-fix.sh \
      "$DATASTREAM" || true

    if [[ -s /tmp/cis-fix.sh ]]; then
      echo "=== Applying $(wc -l < /tmp/cis-fix.sh) lines of CIS fixes ==="
      bash /tmp/cis-fix.sh 2>&1 | tail -50 || true
      echo "=== CIS fix script complete ==="
    else
      echo "WARNING: CIS fix script is empty"
    fi

    # Generate compliance report
    oscap xccdf eval \
      --profile "$PROFILE" \
      $TAILORING \
      --report /tmp/cis-report.html \
      --results /tmp/cis-results.xml \
      "$DATASTREAM" 2>&1 | tail -20 || true

    echo "=== CIS report generated ==="

# -------------------------------------------------------------------------
# Build script (runs on the utility VM — always Rocky 9)
# -------------------------------------------------------------------------
- path: /tmp/build-golden.sh
  permissions: '0755'
  content: |
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/build-golden.log) 2>&1

    echo "=== Multi-Distro CIS Golden Image Builder ==="
    echo "=== Distro: ${distro} | Profile: ${cis_profile_id} ==="
    echo "=== Started: $(date -u) ==="

    mkdir -p /output

    # --- Step 1: Install libguestfs-tools on utility VM (Rocky 9) ---
    echo "=== Step 1: Installing libguestfs-tools ==="
%{ if has_private_ca ~}
    cp /tmp/bake/private-ca.pem /etc/pki/ca-trust/source/anchors/
    update-ca-trust
%{ endif ~}
%{ if distro_config.family == "rhel" && repo_mirror_url != "" ~}
    sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/rocky*.repo
    cp /tmp/bake/baseos-private.repo /etc/yum.repos.d/ 2>/dev/null || true
    cp /tmp/bake/appstream-private.repo /etc/yum.repos.d/ 2>/dev/null || true
%{ endif ~}
    dnf install -y libguestfs-tools-c

    # --- Step 2: Download target distro cloud image ---
    echo "=== Step 2: Downloading ${distro} cloud image ==="
    curl -fSL --retry 3 --retry-delay 5 -o /output/golden.qcow2 "${cloud_image_url}"
    echo "=== Download complete: $(ls -lh /output/golden.qcow2) ==="

    # --- Step 3: Run virt-customize ---
    echo "=== Step 3: Running virt-customize for ${distro} ==="
    export LIBGUESTFS_BACKEND=direct

    # Build the virt-customize command dynamically
    VCMD=(virt-customize -a /output/golden.qcow2 --memsize 2048)

    # --- Private CA injection ---
%{ if has_private_ca ~}
%{ if distro_config.family == "rhel" ~}
    # RHEL: update-ca-trust is available in the base image
    VCMD+=(
      --mkdir "${distro_config.ca_trust_dir}"
      --copy-in /tmp/bake/private-ca.pem:${distro_config.ca_trust_dir}/
      --run-command '${distro_config.ca_trust_cmd}'
    )
%{ else ~}
    # Debian: copy cert now, update-ca-certificates runs after package install
    mkdir -p /tmp/bake-ca
    cp /tmp/bake/private-ca.pem /tmp/bake-ca/private-ca.pem
    VCMD_CA_COPY=(--copy-in /tmp/bake-ca:"/tmp/")
    VCMD+=(
      --mkdir "${distro_config.ca_trust_dir}"
      --run-command 'cp /tmp/bake-ca/private-ca.pem ${distro_config.ca_trust_dir}/private-ca.crt'
    )
%{ endif ~}
%{ endif ~}

    # --- Repo configuration ---
%{ if distro_config.family == "rhel" && repo_mirror_url != "" ~}
    VCMD+=(
%{ if distro == "rocky9" ~}
      --run-command 'sed -i "s/enabled=1/enabled=0/g" /etc/yum.repos.d/rocky*.repo'
      --copy-in /tmp/bake/baseos-private.repo:/etc/yum.repos.d/
      --copy-in /tmp/bake/appstream-private.repo:/etc/yum.repos.d/
      --copy-in /tmp/bake/epel.repo:/etc/yum.repos.d/
%{ endif ~}
%{ if distro == "fedora42" ~}
      --run-command 'sed -i "s/enabled=1/enabled=0/g" /etc/yum.repos.d/fedora*.repo'
      --copy-in /tmp/bake/baseos-private.repo:/etc/yum.repos.d/
      --copy-in /tmp/bake/fedora-updates-private.repo:/etc/yum.repos.d/
%{ endif ~}
    )
%{ endif ~}
%{ if distro_config.family == "debian" ~}
    # Remove DEB822-format sources and ensure classic sources.list exists
    # Use upstream repos during virt-customize (libguestfs appliance can't resolve private DNS)
    VCMD+=(
      --run-command 'rm -f /etc/apt/sources.list.d/debian.sources; true'
%{ if distro == "debian12" ~}
      --run-command 'echo "deb http://deb.debian.org/debian bookworm main contrib" > /etc/apt/sources.list && echo "deb http://deb.debian.org/debian bookworm-updates main contrib" >> /etc/apt/sources.list && echo "deb http://deb.debian.org/debian-security bookworm-security main contrib" >> /etc/apt/sources.list'
%{ endif ~}
%{ if distro == "ubuntu2404" ~}
      --run-command 'echo "deb http://archive.ubuntu.com/ubuntu noble main restricted universe" > /etc/apt/sources.list && echo "deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe" >> /etc/apt/sources.list && echo "deb http://security.ubuntu.com/ubuntu noble-security main restricted universe" >> /etc/apt/sources.list'
%{ endif ~}
    )
%{ endif ~}

    # --- Dracut (RHEL-family only — ensures virtio drivers) ---
%{ if distro_config.family == "rhel" ~}
    VCMD+=(
      --mkdir /etc/dracut.conf.d
      --copy-in /tmp/bake/virtio.conf:/etc/dracut.conf.d/
    )
%{ endif ~}

    # --- Package updates + install ---
%{ if distro_config.family == "rhel" ~}
    VCMD+=(--update)
    VCMD+=(--run /tmp/bake/fix-grub.sh)
    VCMD+=(
      --install "qemu-guest-agent,chrony,${distro_config.firewall_pkg},${distro_config.extra_packages}"
      --install "${distro_config.ssg_package},${distro_config.oscap_package}"
    )
%{ else ~}
    # NOTE: libguestfs on Rocky 9 misdetects Debian guests and uses dnf.
    # Use --run-command with absolute paths to apt-get instead of --update/--install.
    VCMD+=(
      --run-command '/usr/bin/apt-get update'
      --run-command 'DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -y dist-upgrade'
      --run-command 'DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get install -y qemu-guest-agent chrony ${distro_config.firewall_pkg} ${replace(distro_config.extra_packages, ",", " ")} ${distro_config.ssg_package} ${distro_config.oscap_package}'
    )
%{ if has_private_ca ~}
    # Now that ca-certificates is installed, update the trust store
    VCMD+=(--run-command '${distro_config.ca_trust_cmd}')
%{ endif ~}
%{ endif ~}

    # --- CIS Remediation ---
    VCMD+=(
      --copy-in /tmp/bake/cis-remediate.sh:/tmp/
      --run-command 'bash /tmp/cis-remediate.sh'
      --run-command 'cp /tmp/cis-report.html /var/log/cis-report.html 2>/dev/null || true'
      --run-command 'cp /tmp/cis-results.xml /var/log/cis-results.xml 2>/dev/null || true'
    )

    # --- Firewall ---
%{ if distro_config.family == "rhel" ~}
    VCMD+=(
      --mkdir /etc/sysconfig
      --copy-in /tmp/bake/iptables:/etc/sysconfig/
    )
%{ else ~}
    VCMD+=(
      --mkdir /etc/iptables
      --copy-in /tmp/bake/iptables:/etc/iptables/
      --run-command 'mv /etc/iptables/iptables /etc/iptables/rules.v4'
    )
%{ endif ~}

    # --- Service enablement ---
    VCMD+=(
      --run-command 'systemctl enable qemu-guest-agent.service'
      --run-command '${distro_config.disable_firewall}'
      --run-command '${distro_config.enable_firewall}'
      --run-command 'systemctl enable auditd || true'
    )

    # --- NTP / chrony ---
%{ if distro_config.family == "rhel" ~}
    VCMD+=(--run-command 'systemctl enable chronyd.service')
%{ if length(ntp_servers) > 0 ~}
    VCMD+=(--copy-in /tmp/bake/chrony.conf:/etc/)
%{ endif ~}
%{ else ~}
    VCMD+=(--run-command 'systemctl enable chrony.service || systemctl enable chronyd.service || true')
%{ if length(ntp_servers) > 0 ~}
    VCMD+=(
      --mkdir /etc/chrony
      --copy-in /tmp/bake/chrony.conf:/etc/chrony/
    )
%{ endif ~}
%{ endif ~}

    # --- Dracut rebuild (RHEL-family only) ---
%{ if distro_config.family == "rhel" ~}
    VCMD+=(
      --run-command 'for kver in $(ls /lib/modules/); do dracut --force --no-hostonly --kver "$kver" --force-drivers "virtio_blk virtio_net virtio_scsi virtio_pci virtio_console"; done'
    )
%{ endif ~}

%{ if distro_config.family == "debian" && repo_mirror_url != "" ~}
    # --- Bake proxy-cache sources into the final image ---
    # (upstream repos were used for package install above; now switch to proxy-cache)
    VCMD+=(
      --copy-in /tmp/bake/sources.list:/etc/apt/
    )
%{ endif ~}

    # --- Cleanup ---
%{ if distro_config.family == "rhel" ~}
    VCMD+=(
      --run-command 'dnf clean all'
      --run-command 'rm -rf /var/cache/dnf/*'
    )
%{ else ~}
    VCMD+=(
      --run-command '/usr/bin/apt-get clean || true'
      --run-command 'rm -rf /var/lib/apt/lists/*'
    )
%{ endif ~}

    VCMD+=(
      --run-command 'cloud-init clean --logs 2>/dev/null || true'
      --run-command 'truncate -s 0 /etc/machine-id'
      --run-command 'rm -f /etc/ssh/ssh_host_*'
%{ if distro_config.selinux ~}
      --selinux-relabel
%{ endif ~}
    )

    # --- Execute ---
%{ if has_private_ca && distro_config.family == "debian" ~}
    # Inject CA files first for Debian-family
    virt-customize -a /output/golden.qcow2 --memsize 2048 "$${VCMD_CA_COPY[@]}" 2>/dev/null || true
%{ endif ~}
    "$${VCMD[@]}"

    echo "=== virt-customize complete: $(ls -lh /output/golden.qcow2) ==="

    # --- Step 4: Extract CIS report ---
    echo "=== Step 4: Extracting CIS compliance report ==="
    export LIBGUESTFS_BACKEND=direct
    virt-copy-out -a /output/golden.qcow2 /var/log/cis-report.html /output/ 2>/dev/null || \
      echo "WARNING: Could not extract CIS report"

    # --- Step 5: Serve via HTTP ---
    echo "=== Build complete, serving on :8080 ==="
    touch /output/ready
    cd /output && python3 -m http.server 8080

runcmd:
  - /tmp/build-golden.sh
