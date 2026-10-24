# Phase 2 — A Kubernetes cluster with kubeadm

[← Home](../../README.md) · [← Phases 0-1: host and VMs](../phase-0-1-host-and-vms/README.md) · [Part A: prepare the nodes →](01-prepare-nodes.md)

> Status: **in progress**. Part A (node preparation) done on `cp-1`, workers being finished; Part B (cluster bootstrap) next. Written while building it; every result is from my lab.

Phase 1 left three empty Ubuntu VMs on a private network. This phase turns them into a Kubernetes cluster, **one control plane and two workers**, built by hand with `kubeadm`.

The nodes run Ubuntu 24.04, so everything here uses `apt`, `systemd-timesyncd`, `ufw` and AppArmor. Many kubeadm guides are written for RHEL-family distros (`dnf`, `chronyc`, `firewalld`, SELinux); where that matters, the step says so.

| Node | IP | Role |
|---|---|---|
| `cp-1` | 192.168.122.10 | control plane |
| `worker-1` | 192.168.122.11 | worker |
| `worker-2` | 192.168.122.12 | worker |

## Parts

| Part | What | Status |
|---|---|---|
| **[A — Prepare the nodes](01-prepare-nodes.md)** | Steps 1-7: OS prerequisites, containerd, kubeadm/kubelet/kubectl, crictl. Ends with a troubleshooting table: *if this is missing, this is the symptom* | Done on `cp-1`; workers being finished |
| **[B — Bootstrap the cluster](02-bootstrap-cluster.md)** | Steps 8-11: `kubeadm init`, CNI, `kubeadm join`, smoke test | Next |

![Where Part A leaves every node](diagrams/01-node-stack.png)

## Progress

- [x] SSH access to all nodes through ProxyJump
- [x] Step 1 — time sync, all nodes
- [x] Step 2 — SELinux N/A, AppArmor loaded, all nodes
- [ ] Step 2 — `sudo ufw status` recorded on all nodes (`cp-1`: inactive)
- [x] Step 3 — swap off and persistent, all nodes
- [x] Step 4 — kernel modules + sysctl, all nodes
- [ ] Step 5 — `/etc/hosts` entries on all nodes (cp-1 checked: no `127.0.1.1` line)
- [ ] Step 6 — containerd with `SystemdCgroup = true` (`cp-1` done and verified; workers pending)
- [x] Step 7 — kubeadm, kubelet, kubectl v1.34.12 from `pkgs.k8s.io`, held, all nodes
- [ ] Step 7.7 — crictl on all nodes (`cp-1`: `RuntimeReady: true`, `NetworkReady: false` as expected)
- [ ] Step 8 — `kubeadm init` on `cp-1`
- [ ] Step 9 — CNI plugin
- [ ] Step 10 — `kubeadm join` on the workers
- [ ] Step 11 — verify the cluster with a test pod

---

## Background: what kubeadm actually does

**All three nodes get the same software**: containerd, kubelet and kubeadm. The control plane is not a different install; the difference is the command you run on each node.

- **`kubeadm init` on `cp-1`:**
  1. generates a cluster CA and every certificate under `/etc/kubernetes/pki`;
  2. writes **static pod manifests** for etcd, kube-apiserver, kube-controller-manager and kube-scheduler into `/etc/kubernetes/manifests`;
  3. the **kubelet on `cp-1`** watches that folder and starts those pods.

  The control plane is just pods, run by a kubelet that doesn't need an API server to do it.
- **`kubeadm join` on a worker:** the kubelet authenticates with a bootstrap token, gets its own client certificate signed by the cluster CA (**TLS bootstrap**), and registers itself as a Node.

## Diagrams

| | |
|---|---|
| [01-node-stack](diagrams/01-node-stack.png) | what every node has after Part A, and what's still missing |
| [02-runtime-path](diagrams/02-runtime-path.png) | kubectl → API server → kubelet → containerd → shim → runc; where crictl and ctr plug in |
| [03-kubelet-crashloop](diagrams/03-kubelet-crashloop.png) | why the kubelet restarts every 10 s until `init`/`join` |
| [04-cgroup-drivers](diagrams/04-cgroup-drivers.png) | why `SystemdCgroup = true` |

Sources (`.excalidraw`) live next to the PNGs.
