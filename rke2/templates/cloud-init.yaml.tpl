#cloud-config
# =============================================================================
# Golden Image Builder — Utility VM Cloud-Init
# =============================================================================
# This runs on the UTILITY VM (not the golden image). It:
#   1. Installs libguestfs-tools (from private/proxy-cache repos)
#   2. Downloads base Rocky 9 qcow2
#   3. Runs virt-customize to bake all static config into the image
#   4. Serves the result via HTTP on port 8080
# =============================================================================

%{ if length(ssh_authorized_keys) > 0 ~}
ssh_authorized_keys:
%{ for key in ssh_authorized_keys ~}
  - ${key}
%{ endfor ~}
%{ endif ~}

write_files:
# -------------------------------------------------------------------------
# Private CA trust (for proxy-cache / private mirror TLS)
# -------------------------------------------------------------------------
- path: /tmp/bake/private-ca.pem
  permissions: '0644'
  content: |
    ${indent(4, private_ca_pem)}

# -------------------------------------------------------------------------
# Repo files to bake into the golden image
# -------------------------------------------------------------------------
- path: /tmp/bake/rancher-rke2-common.repo
  permissions: '0644'
  content: |
    [rancher-rke2-common]
    name=Rancher RKE2 Common
    baseurl=${rke2_repo_url}/common/centos/9/noarch
    enabled=1
    gpgcheck=0

- path: /tmp/bake/rancher-rke2-1-34.repo
  permissions: '0644'
  content: |
    [rancher-rke2-1-34]
    name=Rancher RKE2 1.34
    baseurl=${rke2_repo_url}/1.34/centos/9/x86_64
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

- path: /tmp/bake/baseos-private.repo
  permissions: '0644'
  content: |
    [baseos-private]
    name=Rocky Linux 9 - BaseOS
    baseurl=${rocky_repo_url}/rocky/9/BaseOS/x86_64/os
    enabled=1
    gpgcheck=0

- path: /tmp/bake/appstream-private.repo
  permissions: '0644'
  content: |
    [appstream-private]
    name=Rocky Linux 9 - AppStream
    baseurl=${rocky_repo_url}/rocky/9/AppStream/x86_64/os
    enabled=1
    gpgcheck=0

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
    # Disable hostonly mode so dracut builds a generic initramfs with all
    # drivers. Required because virt-customize runs dracut inside the
    # libguestfs appliance where no virtio hardware is detected — hostonly
    # mode omits virtio drivers, breaking boot on KubeVirt/Harvester VMs.
    hostonly=no
    hostonly_cmdline=no
    force_drivers+=" virtio_blk virtio_net virtio_scsi virtio_pci virtio_console "

- path: /tmp/bake/iptables
  permissions: '0644'
  content: |
    *filter
    :INPUT DROP [0:0]
    :FORWARD ACCEPT [0:0]
    :OUTPUT DROP [0:0]
    # --- INPUT rules ---
    -A INPUT -i lo -j ACCEPT
    -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    -A INPUT -p icmp -j ACCEPT
    -A INPUT -p tcp --dport 22 -j ACCEPT
    -A INPUT -p tcp --dport 6443 -j ACCEPT
    -A INPUT -p tcp --dport 9345 -j ACCEPT
    -A INPUT -p tcp --dport 2379:2381 -j ACCEPT
    -A INPUT -p tcp --dport 10250 -j ACCEPT
    -A INPUT -p tcp --dport 10257 -j ACCEPT
    -A INPUT -p tcp --dport 10259 -j ACCEPT
    -A INPUT -p tcp --dport 30000:32767 -j ACCEPT
    -A INPUT -p udp --dport 30000:32767 -j ACCEPT
    -A INPUT -p tcp --dport 4240 -j ACCEPT
    -A INPUT -p udp --dport 8472 -j ACCEPT
    -A INPUT -p tcp --dport 4244 -j ACCEPT
    -A INPUT -p tcp --dport 4245 -j ACCEPT
    -A INPUT -p tcp --dport 9962 -j ACCEPT
    -A INPUT -p tcp --dport 9100 -j ACCEPT
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

- path: /tmp/bake/90-arp.conf
  permissions: '0644'
  content: |
    net.ipv4.conf.all.arp_ignore=1
    net.ipv4.conf.all.arp_announce=2

- path: /tmp/bake/10-ingress-routing
  permissions: '0755'
  content: |
    #!/bin/bash
    # Policy routing for ingress NIC (eth1)
    # Ensures traffic from eth1's IP replies via eth1
    IFACE=$1
    ACTION=$2
    if [ "$IFACE" = "eth1" ] && [ "$ACTION" = "up" ]; then
      IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
      SUBNET=$(ip -4 route show dev eth1 scope link | awk '{print $1}' | head -1)
      GW=$(ip -4 route show dev eth1 | grep default | awk '{print $3}')
      [ -z "$GW" ] && GW=$(ip -4 route show default | awk '{print $3}' | head -1)
      grep -q "^200 ingress" /etc/iproute2/rt_tables || echo "200 ingress" >> /etc/iproute2/rt_tables
      ip rule add from $IP table ingress priority 100 2>/dev/null || true
      ip route replace default via $GW dev eth1 table ingress 2>/dev/null || true
      [ -n "$SUBNET" ] && ip route replace $SUBNET dev eth1 table ingress 2>/dev/null || true
    fi

- path: /tmp/bake/fix-grub.sh
  permissions: '0755'
  content: |
    #!/bin/bash
    # Fix GRUB boot loader entries contaminated by libguestfs.
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
    echo "GRUB fix complete. Entries:"
    cat /boot/loader/entries/*.conf

# -------------------------------------------------------------------------
# Build script (runs on the utility VM)
# -------------------------------------------------------------------------
- path: /tmp/build-golden.sh
  permissions: '0755'
  content: |
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/build-golden.log) 2>&1

    echo "=== Golden Image Builder Started: $(date -u) ==="

    mkdir -p /output

    # --- Step 1: Install libguestfs-tools on utility VM ---
    echo "=== Installing libguestfs-tools ==="
    cp /tmp/bake/private-ca.pem /etc/pki/ca-trust/source/anchors/
    update-ca-trust
    sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/rocky*.repo
    cp /tmp/bake/baseos-private.repo /etc/yum.repos.d/
    cp /tmp/bake/appstream-private.repo /etc/yum.repos.d/
    dnf install -y libguestfs-tools-c

    # --- Step 2: Download base Rocky 9 qcow2 ---
    echo "=== Downloading base Rocky 9 image ==="
    curl -fSL --retry 3 --retry-delay 5 -o /output/golden.qcow2 "${rocky_image_url}"
    echo "=== Download complete: $(ls -lh /output/golden.qcow2) ==="

    # --- Step 3: Run virt-customize ---
    echo "=== Running virt-customize ==="
    export LIBGUESTFS_BACKEND=direct

    virt-customize -a /output/golden.qcow2 --memsize 2048 \
      --copy-in /tmp/bake/private-ca.pem:/etc/pki/ca-trust/source/anchors/ \
      --run-command 'update-ca-trust' \
      --copy-in /tmp/bake/rancher-rke2-common.repo:/etc/yum.repos.d/ \
      --copy-in /tmp/bake/rancher-rke2-1-34.repo:/etc/yum.repos.d/ \
      --copy-in /tmp/bake/epel.repo:/etc/yum.repos.d/ \
      --copy-in /tmp/bake/baseos-private.repo:/etc/yum.repos.d/ \
      --copy-in /tmp/bake/appstream-private.repo:/etc/yum.repos.d/ \
      --run-command 'sed -i "s/enabled=1/enabled=0/g" /etc/yum.repos.d/rocky*.repo' \
      --mkdir /etc/dracut.conf.d \
      --copy-in /tmp/bake/virtio.conf:/etc/dracut.conf.d/ \
      --update \
      --run /tmp/bake/fix-grub.sh \
      --install qemu-guest-agent,chrony,iptables,iptables-services,container-selinux,policycoreutils-python-utils,audit \
      --run-command 'dnf install -y rke2-selinux' \
      --copy-in /tmp/bake/iptables:/etc/sysconfig/ \
      --run-command 'chmod 0600 /etc/sysconfig/iptables' \
      --copy-in /tmp/bake/90-arp.conf:/etc/sysctl.d/ \
      --mkdir /etc/NetworkManager/dispatcher.d \
      --copy-in /tmp/bake/10-ingress-routing:/etc/NetworkManager/dispatcher.d/ \
      --run-command 'chmod 0755 /etc/NetworkManager/dispatcher.d/10-ingress-routing' \
      --run-command 'mkdir -p /var/lib/rancher/rke2/server/manifests' \
      --run-command 'systemctl enable qemu-guest-agent.service' \
      --run-command 'systemctl enable chronyd.service' \
%{ if length(ntp_servers) > 0 ~}
      --copy-in /tmp/bake/chrony.conf:/etc/ \
%{ endif ~}
      --run-command 'systemctl disable firewalld || true' \
      --run-command 'systemctl enable iptables' \
      --run-command 'restorecon -R /etc/NetworkManager/dispatcher.d/ || true' \
      --run-command 'for kver in $(ls /lib/modules/); do dracut --force --no-hostonly --kver "$kver" --force-drivers "virtio_blk virtio_net virtio_scsi virtio_pci virtio_console"; done' \
      --run-command 'dnf clean all' \
      --run-command 'rm -rf /var/cache/dnf/*' \
      --run-command 'truncate -s 0 /etc/machine-id' \
      --run-command 'rm -f /etc/ssh/ssh_host_*' \
      --selinux-relabel

    echo "=== virt-customize complete: $(ls -lh /output/golden.qcow2) ==="

    # --- Step 4: Signal ready and serve via HTTP ---
    echo "=== Build complete, serving on :8080 ==="
    touch /output/ready
    cd /output && python3 -m http.server 8080

runcmd:
  - /tmp/build-golden.sh
