#!/usr/bin/env bash
set -euo pipefail

IMG_DIR=/var/lib/libvirt/images
BASE=$IMG_DIR/noble-server-cloudimg-amd64.img
CI_DIR=$HOME/homelab/cloud-init
mkdir -p "$CI_DIR"

create_vm() {
  local name=$1 mem=$2 cpus=$3 mac=$4

  # 1. Overlay disk: 30G virtual, only stores changes vs the base image
  sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$IMG_DIR/$name.qcow2" 30G

  # 2. cloud-init config: hostname, user, SSH keys from GitHub, no snaps
  cat > "$CI_DIR/$name-user-data.yaml" <<EOF
#cloud-config
hostname: $name
users:
  - name: joel
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_import_id: [gh:JoelTeoGom]
package_update: true
runcmd:
  - [snap, remove, --purge, lxd]
  - [apt-get, purge, -y, snapd]   # ~50-100 MB of RAM back
EOF

  # 3. Define + boot the VM (fixed MAC -> DHCP reservation gives fixed IP)
  virt-install --name "$name" --memory "$mem" --vcpus "$cpus" \
    --import --disk path="$IMG_DIR/$name.qcow2",format=qcow2,bus=virtio \
    --os-variant ubuntu22.04 \
    --network network=default,model=virtio,mac="$mac" \
    --cloud-init user-data="$CI_DIR/$name-user-data.yaml" \
    --graphics none --noautoconsole

  # 4. Start with the host
  virsh autostart "$name"
}

#         name      RAM(MB) vCPU  MAC
create_vm cp-1      1792    2     52:54:00:00:00:10
create_vm worker-1  1280    2     52:54:00:00:00:11
create_vm worker-2  1280    2     52:54:00:00:00:12
