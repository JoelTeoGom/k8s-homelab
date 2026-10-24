# k8s-homelab

Kubernetes on an old laptop, built by hand: KVM virtual machines, kubeadm, ingress, GitOps and CI/CD, with no managed services and no one-click installers.

The goal is to understand every layer, from the CPU's virtualization extensions up to a `git push` that deploys an app, and to document each step so anyone can follow along.

![What Phase 1 builds](docs/phase-0-1-host-and-vms/diagrams/00-big-picture.png)

## Hardware

One old HP laptop: AMD Ryzen 7 3700U (4 cores / 8 threads), 5.7 GB of usable RAM, Ubuntu Server 24.04, running headless 24/7 on WiFi.

## Roadmap

| Phase | What | Status |
|---|---|---|
| 0 | **Host**: Ubuntu Server, SSH-only, hardening, BIOS virtualization | Done |
| 1 | **VMs**: KVM + QEMU + libvirt, cloud images, cloud-init, fixed IPs, ProxyJump | Done |
| 2 | **Cluster**: kubeadm, containerd, 1 control plane + 2 workers, Flannel ([doc](docs/phase-2-kubeadm/README.md)) | In progress: nodes prepared, cluster next |
| 3 | **Traffic in**: Traefik + Gateway API, DNAT on the host, Cloudflare Tunnel | Planned |
| 4 | **GitOps & CI/CD**: GitHub Actions → GHCR → manifest repo → Argo CD | Planned |
| 5 | **Secrets**: Sealed Secrets, then External Secrets + GCP Secret Manager | Planned |
| 6 | **Workloads**: Go services, then my own GitOps operator in Go | Planned |

## Layout

```
.
├── scripts/
│   └── create-vms.sh      # Phase 1: creates cp-1, worker-1, worker-2
├── docs/
│   ├── phase-0-1-host-and-vms/
│   │   ├── README.md      # Phases 0-1: full step-by-step guide, with the "why" of every step
│   │   └── diagrams/      # Excalidraw sources (.excalidraw) + PNG exports
│   ├── phase-2-kubeadm/
│   │   ├── README.md      # Phase 2: index
│   │   ├── 01-prepare-nodes.md       # Part A (nodes)
│   │   ├── 02-bootstrap-cluster.md   # Part B (cluster)
│   │   └── diagrams/
│   └── blog/              # blog posts, one per phase
└── README.md
```

## Read it

The guide, in order:

1. **[Phases 0-1: host and VMs](docs/phase-0-1-host-and-vms/README.md)**: full guide, every command, what it does and why.
2. **[Phase 2: kubeadm](docs/phase-2-kubeadm/README.md)**: in progress, written while building it.
   - [Part A: prepare the nodes](docs/phase-2-kubeadm/01-prepare-nodes.md): OS prerequisites, containerd, kubeadm/kubelet/kubectl, crictl, and a troubleshooting table.
   - [Part B: bootstrap the cluster](docs/phase-2-kubeadm/02-bootstrap-cluster.md): `kubeadm init`, CNI, `join`. Next.

Blog posts (same story, shorter):

- **[Part 1: three VMs on an old laptop](docs/blog/part-1-three-vms-on-an-old-laptop.md)**: KVM vs QEMU vs libvirt, the libvirt network, DHCP reservations, qcow2 overlays, cloud-init and SSH ProxyJump.

Posts are also published on [runtimerants.dev](https://runtimerants.dev).

## Current setup

| VM | Role | IP | RAM | vCPU |
|---|---|---|---|---|
| `cp-1` | control plane | 192.168.122.10 | 1.75 GB | 2 |
| `worker-1` | worker | 192.168.122.11 | 1.25 GB | 2 |
| `worker-2` | worker | 192.168.122.12 | 1.25 GB | 2 |

All IPs are private (RFC 1918) and only reachable from inside the host.
