# Part 0 — From old laptop to server

*Ubuntu Server, SSH-only access, and the BIOS switch nobody tells you about*

[Index](../../README.md) · [Part 1: three VMs →](../part-1-vms/README.md)

Everything in this series runs on one old HP laptop that was gathering dust. Before it can host a Kubernetes cluster, it has to stop being a laptop: no desktop, no Windows, managed only over SSH, and awake 24/7 with the lid closed.

| | |
|---|---|
| CPU | AMD Ryzen 7 3700U, 4 cores / 8 threads |
| RAM | 8 GB physical, **5.7 GB usable** |
| Disk | 512 GB NVMe |
| Network | WiFi only (`wlo1`), no Ethernet port |

> **Where did 2.3 GB of RAM go?** The integrated Radeon Vega GPU reserves ~2 GB as video memory, and this HP's BIOS doesn't let you change it. Every decision in the series is sized to fit **one control plane + two workers in 5.7 GB**.

The plan:

1. Install Ubuntu Server
2. Log in over SSH with a key
3. Harden it and make it behave like a server
4. Give it a fixed IP
5. Turn on hardware virtualization

---

## 1. Install Ubuntu Server

**Ubuntu Server 24.04 LTS**, because it's the most documented distro for kubeadm, it's close to the CKA exam environment, it's supported until 2029, and it has **no desktop**: a GUI alone would eat 1.5-2 GB of RAM we don't have.

1. Download `ubuntu-24.04.x-live-server-amd64.iso` (`amd64` = x86-64 CPUs like the Ryzen).
2. Flash a USB stick with **Rufus**: partition scheme **GPT**, target **UEFI (non CSM)**, **ISO image mode**.
3. Boot from USB (**F9** on HP opens the boot menu).

The installer screens that matter:

| Screen | Choice | Why |
|---|---|---|
| Network | WiFi on `wlo1` | no Ethernet port |
| Storage | **Use an entire disk** | it's a dedicated server now; Windows goes |
| Storage summary | edit `ubuntu-lv` → **max size** | by default Ubuntu only gives `/` ~100 GB of the volume |
| Profile | server `homelab`, user `joel` | |
| SSH | **Install OpenSSH server** + **Import SSH key from GitHub** | log in with the key you already have, no password |
| Featured snaps | **none** | no microk8s/docker snaps: everything gets installed by hand, with pinned versions |

> **How did it get my keys from just a username?** Public keys are public: GitHub serves them at `https://github.com/<user>.keys`. The installer (`ssh-import-id`) downloads them into `~/.ssh/authorized_keys`. The private key never leaves your own machine.

## 2. Log in over SSH

From the workstation (WSL, in my case):

```bash
ssh joel@192.168.1.25
```

No password asked. It works because both machines are on the same home LAN, `sshd` listens on port 22, and the workstation's private key matches one of the imported public keys.

The server is **not** reachable from the Internet: `192.168.x.x` is a private range, hidden behind the router's NAT.

To stop typing the IP, add an alias to `~/.ssh/config` on the workstation:

```
Host homelab
  HostName 192.168.1.25
  User joel
```

Now it's just `ssh homelab`. Part 1 builds on this alias to reach the VMs.

## 3. Make it behave like a server

```bash
sudo apt update && sudo apt upgrade -y
```

**SSH with keys only, no root.**

```bash
echo -e "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no" \
  | sudo tee /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t && sudo systemctl reload ssh
```

- A file in `sshd_config.d/` overrides the main config without editing it.
- `sshd -t` tests the config first: a typo here could lock you out of a headless machine.

> **Tip:** keep one SSH session open while changing `sshd`, and test from a second terminal before closing it.

**Don't sleep when the lid closes.**

```bash
sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/; s/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sudo systemctl restart systemd-logind
```

`systemd-logind` decides what the lid does. By default it suspends the machine, which for a server means "goes offline".

**Save power, turn the screen off.**

```bash
sudo apt install -y tlp && sudo systemctl enable --now tlp
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&consoleblank=60 /' /etc/default/grub && sudo update-grub
```

- `tlp` tunes CPU and battery power management for a machine that's on all the time.
- `consoleblank=60` is a kernel parameter: the text console goes dark after 60 s.

## 4. A fixed IP

In the home router, add a **DHCP reservation**: the laptop's WiFi MAC address always gets `192.168.1.25`.

The laptop still asks for an IP over DHCP; the router just always gives the same answer. Part 1 uses exactly the same trick for the VMs.

## 5. Turn on hardware virtualization

VMs need the CPU's virtualization extension (AMD-V, called **SVM** on AMD). On this HP it came **disabled from the factory**:

```bash
grep -c svm /proc/cpuinfo          # > 0: the CPU supports it
sudo apt install -y cpu-checker
sudo kvm-ok
# INFO: Your CPU does not support KVM extensions   ← disabled in the BIOS
```

Fix: reboot → **Esc** → **F10** (BIOS Setup) → *Configuration* → **Virtualization Technology: Enabled** → save with F10. Then:

```
INFO: /dev/kvm exists
KVM acceleration can be used
```

> **Two separate switches.** The BIOS turns on the **hardware** feature. The Linux kernel then loads the **software** that uses it, the `kvm` and `kvm_amd` modules, on its own at boot. Check with `lsmod | grep kvm`.

## Done when

- [x] `ssh homelab` logs in with a key, no password
- [x] password and root login over SSH are refused
- [x] closing the lid doesn't suspend the machine
- [x] the laptop always gets `192.168.1.25`
- [x] `kvm-ok` says `KVM acceleration can be used`

## Next: [Part 1](../part-1-vms/README.md)

A headless server with virtualization turned on. Part 1 turns it into three virtual machines.
