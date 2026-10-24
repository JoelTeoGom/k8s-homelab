# k8s-homelab

Kubernetes on an old laptop, built by hand: KVM virtual machines, kubeadm, ingress, GitOps and CI/CD, with no managed services and no one-click installers.

The goal is to understand every layer, from the CPU's virtualization extensions up to a `git push` that deploys an app, and to document each step so anyone can follow along.

![What Part 1 builds](docs/part-1-vms/diagrams/00-big-picture.png)

## Hardware

One old HP laptop: AMD Ryzen 7 3700U (4 cores / 8 threads), 5.7 GB of usable RAM, Ubuntu Server 24.04, running headless 24/7 on WiFi.

## The guide

Read it in order. Each part is one page: what we do, why, the commands, and a "see it yourself" after each step.

| Part | What | Status |
|---|---|---|
| **[0 — From old laptop to server](docs/part-0-host/README.md)** | Ubuntu Server, SSH-only access, hardening, BIOS virtualization | Done |
| **[1 — Three VMs on an old laptop](docs/part-1-vms/README.md)** | KVM + QEMU + libvirt, the VM network, fixed IPs, cloud-init, SSH ProxyJump | Done |
| **[2 — Preparing the nodes](docs/part-2-nodes/README.md)** | OS prerequisites, containerd, kubeadm/kubelet/kubectl, crictl | Done |
| **[3 — Bootstrapping the cluster](docs/part-3-cluster/README.md)** | `kubeadm init`, the control plane as static pods, Flannel, `join` | In progress |
| 4 — Traffic in | Traefik + Gateway API, DNAT on the host, Cloudflare Tunnel | Planned |
| 5 — GitOps & CI/CD | GitHub Actions → GHCR → manifest repo → Argo CD | Planned |
| 6 — Secrets | Sealed Secrets, then External Secrets + GCP Secret Manager | Planned |
| 7 — Workloads | Go services, then my own GitOps operator in Go | Planned |

The same pages are published as posts on [runtimerants.dev](https://runtimerants.dev).

## Layout

```
.
├── README.md                  # you are here
├── scripts/
│   └── create-vms.sh          # Part 1: creates cp-1, worker-1, worker-2
└── docs/
    ├── part-0-host/README.md
    ├── part-1-vms/
    │   ├── README.md
    │   └── diagrams/          # .png + .excalidraw sources
    ├── part-2-nodes/
    │   ├── README.md
    │   └── diagrams/
    └── part-3-cluster/
        ├── README.md
        └── diagrams/
```

## Current setup

| VM | Role | IP | RAM | vCPU |
|---|---|---|---|---|
| `cp-1` | control plane | 192.168.122.10 | 1.75 GB | 2 |
| `worker-1` | worker | 192.168.122.11 | 1.25 GB | 2 |
| `worker-2` | worker | 192.168.122.12 | 1.25 GB | 2 |

All IPs are private (RFC 1918) and only reachable from inside the host.
