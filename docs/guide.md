# Guide — on-premise Kubernetes platform

A production-style Kubernetes platform running 24/7 on an old laptop at home, built by hand to learn every layer: hypervisor, virtual machines, networking, kubeadm, GitOps and CI/CD.

This is both the **spec** and the **guide**: what I built, how, and *why* each piece works the way it does. If you want to reproduce it, follow the phases in order.

> Living document. Status: **Phase 1 done** (3 VMs up). Next: Phase 2 (kubeadm).

---

## Contents

- [Phase 0 — The host](#phase-0--the-host)
- [Phase 1 — Virtual machines](#phase-1--virtual-machines)
- [Next phases](#next-phases)

---

## Phase 0 — The host

### Hardware & constraints

| Item | Value |
|---|---|
| Machine | Old HP laptop, **AMD Ryzen 7 3700U** (4 cores / 8 threads) |
| RAM | 8 GB physical, **5.7 GB usable** |
| Disk | 512 GB NVMe |
| Network | Wi-Fi only (`wlo1`), no Ethernet port |

**RAM is the hard constraint.** The laptop has 8 GB soldered, but `free -h` shows 5.7 GB: the integrated Radeon Vega GPU reserves ~2 GB as video memory, and this HP BIOS doesn't let you change it. Every decision below is sized to fit **1 control plane + 2 workers** in 5.7 GB.

### 0.1 Install Ubuntu Server

Why **Ubuntu Server 24.04 LTS**: the most documented distro for kubeadm, close to the CKA exam environment, supported until 2029, and **no desktop** — a GUI alone would eat 1.5–2 GB of RAM. The server is managed only over SSH, like a real one.

1. Download `ubuntu-24.04.5-live-server-amd64.iso` (`amd64` = x86_64 CPUs like the Ryzen).
2. Flash a USB stick with **Rufus** (Windows): partition scheme **GPT**, target **UEFI (non CSM)**, write in **ISO image mode**.
3. Boot the laptop from USB (**F9** on HP for the boot menu).
4. Installer choices:

| Screen | Choice | Why |
|---|---|---|
| Network | Configure Wi-Fi on `wlo1` | No Ethernet port |
| Storage | **Use an entire disk** (wipes Windows) | Dedicated server |
| Storage summary | Edit `ubuntu-lv` → **max size** | By default Ubuntu only gives `/` ~100 GB of the LVM volume |
| Profile | Server name `homelab`, user `joel` | |
| SSH | **Install OpenSSH server** + **Import SSH key from GitHub** | Log in with your existing key, no password |
| Featured snaps | **None** | No microk8s/docker snaps: everything is installed manually with `apt` and pinned versions |

> **How did it import my keys with just a username?** Public keys are public: GitHub serves them at `https://github.com/<user>.keys`. The installer (`ssh-import-id`) downloads them into `~/.ssh/authorized_keys`. The private key never leaves your machine.

### 0.2 Remote access over SSH

```bash
ssh joel@192.168.1.25      # from the workstation
```

This works because: (1) both machines are on the same home LAN, (2) `sshd` listens on port 22, (3) the workstation's private key matches one of the imported public keys. The host is **not** reachable from the internet: `192.168.x.x` is a private range behind the router's NAT.

`~/.ssh/config` on the workstation:

```
Host homelab
  HostName 192.168.1.25
  User joel
```

### 0.3 Harden and tune the host

```bash
sudo apt update && sudo apt upgrade -y

# SSH: key-only, no root login
echo -e "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no" \
  | sudo tee /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t && sudo systemctl reload ssh

# Laptop as a server: don't suspend when the lid closes
sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/; s/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sudo systemctl restart systemd-logind

# Power saving + turn the screen off after 60 s
sudo apt install -y tlp && sudo systemctl enable --now tlp
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&consoleblank=60 /' /etc/default/grub && sudo update-grub
```

Keep one SSH session open while changing `sshd` settings, and test from a second terminal before closing it.

### 0.4 Fixed IP

In the home router: **DHCP reservation** for the laptop's Wi-Fi MAC → `192.168.1.25`. The host always gets the same IP.

### 0.5 Enable hardware virtualization (BIOS)

VMs need the CPU's virtualization extension. On this HP it was **disabled from factory**:

```bash
egrep -c 'svm' /proc/cpuinfo    # > 0 → the CPU supports it
sudo apt install -y cpu-checker && sudo kvm-ok
# "Your CPU does not support KVM extensions" → disabled in BIOS
```

Fix: reboot → **Esc** → **F10** (BIOS Setup) → *Configuration* → **Virtualization Technology: Enabled** → F10 save. Now:

```
INFO: /dev/kvm exists
KVM acceleration can be used
```

> **Two separate switches.** The BIOS enables the *hardware* feature (AMD-V / SVM). The Linux kernel then loads the *software* that uses it: the `kvm` and `kvm_amd` modules, automatically at boot. Check with `lsmod | grep kvm`.

---

## Phase 1 — Virtual machines

### Goal

| VM | Role | vCPU | RAM | Disk | IP | MAC |
|---|---|---|---|---|---|---|
| `cp-1` | Control plane | 2 | 1.75 GB | 30 GB | `192.168.122.10` | `52:54:00:00:00:10` |
| `worker-1` | Worker | 2 | 1.25 GB | 30 GB | `192.168.122.11` | `52:54:00:00:00:11` |
| `worker-2` | Worker | 2 | 1.25 GB | 30 GB | `192.168.122.12` | `52:54:00:00:00:12` |
| *host* | Ubuntu + hypervisor | — | ~1.4 GB left | — | `192.168.1.25` | — |

6 vCPUs on 8 hardware threads is fine: CPU time is shared (*overcommit*). RAM can't be shared that way, so RAM is what we budget.

### Background: how virtualization works

#### What a hypervisor is

The software that **splits the real hardware (CPU, RAM, devices) between virtual machines and isolates them**. Each guest OS believes it has a whole computer to itself.

| | Type 1 (bare-metal) | Type 2 (hosted) |
|---|---|---|
| Runs | On the hardware, or inside the kernel | As an app on top of a desktop OS |
| Used for | Servers, datacenters, clouds | Local testing on a laptop |
| Examples | VMware ESXi, Hyper-V, **KVM**, Xen | VirtualBox, VMware Workstation, Parallels |

#### The trick: the CPU helps (AMD-V / Intel VT-x)

Modern CPUs have a **guest mode**. Guest code runs **directly on the real CPU** at native speed; only *sensitive* operations (disk, network, some privileged instructions) make the CPU stop and hand control to the hypervisor:

```
VM entry →  CPU runs the guest's code directly (≈99% of the time, native speed)
                    │
                    │ sensitive operation (write to disk, send a packet…)
                    ▼
            VM exit → hypervisor does it on the guest's behalf
                    │
                    └──→ VM entry: the guest continues
```

Memory is translated in hardware too (*nested page tables*): guest address → real RAM address, no software in the way. The guest never touches the real hardware directly.

#### The stack: KVM + QEMU + libvirt

| Piece | Where | What it does |
|---|---|---|
| **KVM** | Kernel module (`kvm`, `kvm_amd`), exposed as `/dev/kvm` | Turns the Linux kernel into a hypervisor: puts the CPU in guest mode, handles VM exits and memory. The kernel loses nothing; it gains this ability. |
| **QEMU** | Normal user-space program, **one process per VM** | A **fake computer**: virtual motherboard, disk controller, network card, BIOS (*virtio* devices). Asks KVM to run the guest's CPU. |
| **libvirt** | Daemon `libvirtd` | Manages VMs, networks and storage. Think of it as the "API server". |
| **virsh / virt-install** | CLI clients | Talk to libvirt, like `kubectl` talks to the Kubernetes API server. `virt-install` creates VMs; `virsh` manages them. |

One-liner: **KVM provides the CPU, QEMU provides the rest of the computer, libvirt manages it, virsh/virt-install are the clients.** This is the standard Linux virtualization stack — the same one under Proxmox, OpenStack and Google Cloud.

How they work together when `cp-1` boots:

1. QEMU opens `/dev/kvm` and asks for a new VM.
2. QEMU allocates **1.75 GB of its own memory**: that becomes the VM's RAM.
3. QEMU creates **one thread per vCPU**; each thread tells KVM "run", and the CPU enters guest mode.
4. When the guest writes to disk → VM exit → QEMU writes to `cp-1.qcow2` → the guest continues.

So **each VM is a process, each vCPU is a thread, and the VM's RAM is process memory.** The normal Linux scheduler spreads vCPU threads over the 8 hardware threads, time-shared with everything else. (Dedicated cores are possible with CPU pinning, `virsh vcpupin` — not needed here.)

#### QEMU without KVM?

QEMU can also **emulate the CPU in software** (TCG mode): it translates each guest instruction into host instructions, caching translated blocks like a JIT. That's how you run an ARM system on an x86 machine, but it's 10–50× slower. **With KVM there is no translation**: the real CPU runs the guest code once, directly. KVM is the accelerator.

#### VM vs container

| | Container (a Kubernetes pod) | VM |
|---|---|---|
| What it is | An isolated process (namespaces + cgroups) | A process emulating a **whole computer** |
| Kernel | **Shares the host kernel** | **Boots its own full kernel** |
| Isolation from | The shared kernel | The CPU (hardware guest mode) |

Inside `cp-1` there is a complete Linux kernel with its own scheduler and memory management. At runtime the laptop runs **four kernels at once**: the host's and one per VM. The host kernel stays in charge: it decides when each vCPU runs and how much real RAM each VM gets.

### Background: images, disks and network

#### Cloud images (no installer per VM)

QEMU gives you an **empty computer**: CPU, RAM, a blank disk, a BIOS. Something has to be on that disk. Two options:

1. Install from an ISO, screen by screen — three times.
2. Use a **disk that already contains the OS**: a **cloud image**.

`noble-server-cloudimg-amd64.img`:

| Part | Meaning |
|---|---|
| `noble` | Codename of **Ubuntu 24.04** (Noble Numbat) |
| `server` | Server edition, no desktop |
| `cloudimg` | Already installed, no user, no network config, ships with **cloud-init** |
| `amd64` | x86_64 CPUs |
| `.img` | Inside it's a **qcow2** disk, QEMU's native format |

It's a complete, normal Ubuntu Server — the same thing AWS boots when you launch an EC2 instance (an AMI is exactly this).

**cloud-init** runs on the **first boot**, reads a config we provide (user, SSH keys, hostname, packages) and applies it. A VM goes from nothing to ready in about a minute.

#### Disks: base image + copy-on-write overlays

The base image is downloaded **once** and never modified. Each VM gets its own **qcow2 overlay** that uses it as a *backing file*:

```
noble-server-cloudimg-amd64.img   (base, read-only, ~600 MB)
        ▲              ▲              ▲
   cp-1.qcow2    worker-1.qcow2   worker-2.qcow2   (only store what changes)
```

- **Copy-on-write**: each overlay only stores the blocks its VM writes.
- **Thin provisioning**: "30 GB" is the maximum; on disk it only takes what's written.

#### Network: libvirt's `default` network (our "VPC")

Installing libvirt creates a private network inside the host. See it with `virsh net-dumpxml default`:

```xml
<ip address='192.168.122.1' netmask='255.255.255.0'>
  <dhcp>
    <range start='192.168.122.2' end='192.168.122.254'/>
  </dhcp>
</ip>
```

- **`192.168.122.0/24` is libvirt's default range**, not something we chose. It's private (like the home `192.168.1.x`) and different so they don't clash.
- **Bridge `virbr0`** = a virtual switch in the host, IP `192.168.122.1`: the VMs' gateway.
- **NAT**: VMs reach the internet through the host's IP. Nothing on the home Wi-Fi can reach the VMs — isolation for free.
- **dnsmasq** runs DHCP and DNS for this network. VMs can resolve each other by name (`ping cp-1` from `worker-1`).

```
workstation ──Wi-Fi──► router 192.168.1.1 ──► homelab 192.168.1.25
                                         │ virbr0 192.168.122.1 (NAT)
                         ┌───────────────┼───────────────┐
                    cp-1 .10        worker-1 .11     worker-2 .12
```

> **Why not a bridge to the home network**, so VMs get IPs from the router? Many guides do that, but it only works over **Ethernet**. Wi-Fi (802.11) in client mode only allows the card's own MAC towards the access point, so VMs with their own MACs can't be bridged over `wlo1`. NAT is the right choice here.

#### Fixed IPs: MAC → IP reservations

kubeadm needs **stable node IPs**. The DHCP server recognizes each VM **by its MAC address**, so we pick a MAC per VM and reserve an IP for it.

- **IPs `.10`, `.11`, `.12`**: our choice. Anything in the range except `.1` works; low, consecutive numbers are easy to remember.
- **MACs `52:54:00:xx:xx:xx`**: `52:54:00` is the prefix QEMU/KVM conventionally uses for virtual NICs. The first byte `0x52` has the *locally administered* bit set ("assigned by me, not a real vendor"). The last byte matches the IP for readability. The only rule: unique in the network.
- **`name`**: a label for libvirt's DHCP/DNS. The real hostname inside the VM is set by cloud-init.

libvirt describes everything — networks, VMs, disks — as **XML**, its equivalent of Kubernetes YAML. `virsh net-update` edits that definition:

- `--live` → applied now to the running dnsmasq
- `--config` → saved to the persistent definition (survives reboots)

#### Access: SSH ProxyJump (bastion)

The workstation can't see `192.168.122.0/24`. SSH first jumps into `homelab` and from there into the VM — the **bastion host** pattern used to reach private subnets in the cloud.

### Steps

All on the host (`ssh homelab`) unless stated otherwise.

#### 1.1 Install QEMU, libvirt and the clients

```bash
sudo apt install -y qemu-kvm libvirt-daemon-system virtinst cloud-image-utils
sudo usermod -aG libvirt,kvm joel
exit   # log in again so the new groups apply
```

| Package | Provides |
|---|---|
| `qemu-kvm` | QEMU with KVM acceleration |
| `libvirt-daemon-system` | `libvirtd`, `virsh`, the `default` network |
| `virtinst` | `virt-install` |
| `cloud-image-utils` | Helpers for cloud-init configs |

`usermod` doesn't enable anything: it gives your user **permission** to use `/dev/kvm` and talk to `libvirtd` without `sudo`.

Check:

```bash
lsmod | grep kvm                   # kvm_amd + kvm
systemctl is-active libvirtd.socket   # active
virsh net-list --all               # 'default': active, autostart yes
```

> `systemctl is-active libvirtd` may say **inactive** — that's fine. Ubuntu 24.04 uses **socket activation**: systemd listens on `libvirtd.socket` and starts the daemon when a client (like `virsh`) connects, then stops it after a while idle.

#### 1.2 Enable KSM (memory deduplication)

The 3 VMs run the same OS, so many memory pages are identical. **KSM** (Kernel Samepage Merging) merges them and gives RAM back.

```bash
echo 1 | sudo tee /sys/kernel/mm/ksm/run
```

> TODO: make it persistent across reboots.

#### 1.3 Download the base image

```bash
cd /var/lib/libvirt/images
sudo wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qemu-img info noble-server-cloudimg-amd64.img   # file format: qcow2
```

#### 1.4 Reserve the VM IPs

Must happen **before** creating the VMs: each VM asks DHCP for an IP on its first boot.

```bash
for vm in "cp-1 10" "worker-1 11" "worker-2 12"; do
  set -- $vm
  virsh net-update default add ip-dhcp-host \
    "<host mac='52:54:00:00:00:$2' name='$1' ip='192.168.122.$2'/>" --live --config
done
virsh net-dumpxml default   # three <host .../> entries inside <dhcp>
```

#### 1.5 Create the VMs

Project layout on the host (this folder becomes the repo):

```
~/homelab/
├── scripts/create-vms.sh
└── cloud-init/          # generated user-data, one file per VM
```

`~/homelab/scripts/create-vms.sh` (runs from any directory: every path is absolute):

```bash
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
```

What each part does:

- **`set -euo pipefail`**: stop at the first error instead of carrying on blindly.
- **`qemu-img create -b BASE`**: the copy-on-write overlay described above.
- **`#cloud-config`**: creates user `joel` with passwordless sudo, imports the SSH keys from GitHub (same as the host installer), sets the hostname, removes `snapd` to save RAM.
- **`virt-install --import`**: doesn't install anything; boots from the existing disk with the given RAM/vCPUs, attaches it to the `default` network **with the reserved MAC**, and hands the cloud-init config over. `--graphics none`: it's a server, no virtual screen.
- **`virsh autostart`**: the VM starts when the host boots.
- **Nobody sets an IP here.** The VM boots, sends a DHCP request with its MAC, and dnsmasq answers with the reservation from 1.4.

```bash
mkdir -p ~/homelab/{scripts,cloud-init}
# write the script above to ~/homelab/scripts/create-vms.sh
chmod +x ~/homelab/scripts/create-vms.sh
~/homelab/scripts/create-vms.sh
```

What the output means:

- `WARNING Requested memory 1792 MiB is less than the recommended 2048 MiB`: osinfo's recommendation. Ignored on purpose (5.7 GB host).
- `Allocating 'virtinst-...-cloudinit.iso'`: virt-install packs the user-data into a **tiny ISO** and attaches it as a **CD-ROM**. On first boot cloud-init looks for that CD (datasource *NoCloud*) and applies it. On AWS/GCP the same user-data comes from an HTTP metadata server (`169.254.169.254`) instead.
- If the script fails half-way, don't just re-run it: `qemu-img` refuses to overwrite an existing disk. Clean up first (`virsh destroy` + `virsh undefine <vm>` + delete its qcow2).

```bash
virsh list --all                       # 3 VMs, running
virsh net-dhcp-leases default          # .10 .11 .12 (give it 30-60 s)
sudo ls -lh /var/lib/libvirt/images/   # root-only dir: needs sudo
```

#### 1.6 SSH from the workstation (ProxyJump)

The workstation (here: WSL Ubuntu on a Windows PC) has no route to `192.168.122.0/24`; that network only exists inside the host. Add to `~/.ssh/config` **on the workstation**, below the `homelab` block:

```
Host cp-1
  HostName 192.168.122.10
Host worker-1
  HostName 192.168.122.11
Host worker-2
  HostName 192.168.122.12

Host cp-1 worker-1 worker-2
  User joel
  ProxyJump homelab
```

```bash
ssh -G cp-1 | grep -E '^(hostname|user|proxyjump) '   # check SSH really reads it
ssh cp-1     'cloud-init status --wait; hostname'      # status: done / cp-1
ssh worker-1 'cloud-init status --wait; hostname'
ssh worker-2 'cloud-init status --wait; hostname'
```

How `ssh cp-1` works (a tunnel inside a tunnel):

1. SSH #1 from the workstation to `homelab` (authenticated with the workstation's key).
2. Over it, the HP is asked to open a plain TCP connection to `192.168.122.10:22` (`direct-tcpip` channel).
3. SSH #2 runs through that pipe, end-to-end encrypted, from the workstation straight to `cp-1` (the workstation's key again).

The HP only forwards encrypted bytes: it can't read SSH #2 and never holds the private key. `<no hostip for proxy command>` in the first-connection prompt is SSH saying exactly that: it didn't connect to the IP itself, it went through the proxy.

**Gotchas hit while doing this:**

- **`ssh joel@192.168.122.10` from the host → `Permission denied (publickey)`.** The VMs trust the keys published on GitHub = the workstation's keys. The host presents its own key (or none). Not a bug: that's why ProxyJump from the workstation is the way in.
- **Commands pasted under a failing `ssh` line run on the machine you're on.** The `exit` at the end then closed the session on the host. Use `ssh host 'cmd1; cmd2'`.
- **`Could not resolve hostname cp-1`**: the `Host cp-1` block wasn't in `~/.ssh/config`. `ssh -G <host>` shows the effective config.

Optional, recommended with 5.7 GB: enable KSM so identical memory pages of the 3 VMs (same kernel, same base image) are shared:

```bash
echo 1 | sudo tee /sys/kernel/mm/ksm/run   # not persistent yet: TODO systemd unit / tmpfiles
```

### Done when

- [x] `virsh list --all` shows `cp-1`, `worker-1`, `worker-2` running
- [x] `virsh net-dhcp-leases default` shows .10/.11/.12 for the right MACs
- [x] `ssh cp-1`, `ssh worker-1`, `ssh worker-2` work from the workstation
- [x] Inside each VM: `cloud-init status --wait` → `done`, and `hostname` is correct
- [ ] VMs reach each other and the internet (`ping worker-1`, `ping 1.1.1.1`)
- [ ] After rebooting the host, the 3 VMs come back on their own
- [ ] `free -h` on the host still shows free memory

### Look under the hood

```bash
ps aux | grep qemu                                   # each VM is a process
ip a show virbr0                                     # the virtual bridge
virsh dumpxml cp-1                                   # full VM definition (XML)
qemu-img info /var/lib/libvirt/images/cp-1.qcow2     # backing file + real size on disk
cat /sys/kernel/mm/ksm/pages_sharing                 # pages KSM is deduplicating
```

### References

- `man virt-install`, `man virsh`
- Arch Wiki: *KVM*, *QEMU*, *libvirt*
- cloud-init docs: cloudinit.readthedocs.io
- Ubuntu cloud images: cloud-images.ubuntu.com
- libvirt network XML: libvirt.org/formatnetwork.html

---

## Next phases

- **Phase 2 — Kubernetes cluster (kubeadm):** node prep (swap, kernel modules, sysctl, containerd), `kubeadm init` on `cp-1`, CNI (Flannel), `kubeadm join` of the workers, `kubectl` from the workstation via SSH tunnel.
- **Phase 3 — Traffic in:** ingress controller (Traefik, Gateway API) as a DaemonSet on the workers; DNAT on the host for LAN access; Cloudflare Tunnel for internet access.
- **Phase 4 — GitOps & CI/CD:** repos `lab-manifests`, `api-gateway`, `email-service`; GitHub Actions → GHCR → manifest repo; Argo CD (later, a self-written Go operator).
- **Phase 5 — Secrets:** GitHub Actions Secrets for CI; Sealed Secrets in the cluster (later: External Secrets Operator + GCP Secret Manager).
- **Phase 6 — Services:** `api-gateway` (Go, CRUD) and `email-service` (Go + CronJob), distroless images, resource requests/limits.
