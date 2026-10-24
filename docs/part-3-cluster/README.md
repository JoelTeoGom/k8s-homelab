# Part 3 — Bootstrapping the cluster

*`kubeadm init`, the control plane as static pods, the pod network and the workers joining*

[← Part 2: preparing the nodes](../part-2-nodes/README.md) · [Index](../../README.md)

> **Status: in progress.** Written while building it: every output below is from my lab.

[Part 2](../part-2-nodes/README.md) left three identical nodes: OS prepared, containerd running, Kubernetes packages installed, and a kubelet crash-looping because nothing has configured it yet. In this part they become a cluster.

![Starting point: the right-hand column is what this part creates](../part-2-nodes/diagrams/01-node-stack.png)

The plan:

1. What `kubeadm init` and `join` actually do
2. Bootstrap the control plane on `cp-1`
3. Install the pod network (Flannel) *(next)*
4. Join the workers *(next)*
5. Smoke test *(next)*

---

## 1. What `kubeadm init` and `join` actually do

The kubelet already knows **where** its config will be: the package installed a kubeadm drop-in for its service.

```bash
systemctl cat kubelet
```

```ini
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
```

(The `-` in `EnvironmentFile=-` means "fine if it doesn't exist", which is why the journal only warns about `KUBELET_KUBEADM_ARGS`. The empty `ExecStart=` clears the base unit's command before setting the new one.)

Right now both folders are empty:

```bash
tree /etc/kubernetes /var/lib/kubelet
# /etc/kubernetes
# └── manifests
# /var/lib/kubelet
```

`kubeadm init` (on `cp-1`) and `kubeadm join` (on the workers) fill them:

| File | Tells the kubelet |
|---|---|
| `/var/lib/kubelet/config.yaml` | how to behave: systemd cgroups, cluster DNS, where static pods live |
| `/var/lib/kubelet/kubeadm-flags.env` | node-specific flags: the containerd socket, the pause image |
| `/etc/kubernetes/kubelet.conf` | who to talk to and who it is: the API server address and its client certificate |

The difference between the two commands is how the node gets that certificate:

- **`init` on `cp-1`** creates the cluster CA, signs the kubelet's certificate itself, and writes the **static pod manifests** for etcd, the API server, the controller-manager and the scheduler into `/etc/kubernetes/manifests`. The kubelet on `cp-1` sees them and starts them: the control plane is just pods.
- **`join` on a worker** has no CA. It hands the kubelet a **bootstrap token**; the kubelet uses it to ask the API server for a certificate (**TLS bootstrap**), saves it, and registers itself as a node.

### The control plane is just pods

`init` doesn't install the control plane as services. It writes four YAML files into `/etc/kubernetes/manifests`, and the kubelet on `cp-1` starts them through containerd. These are **static pods**: pods the kubelet starts from files on disk, without asking the API server (it can't: the API server is one of them).

![The control plane is just pods](diagrams/01-static-pods.png)

Each of those manifests also says `hostNetwork: true`. Two different ideas, both used by the control plane:

| | Means |
|---|---|
| **static pod** | **who starts it**: the kubelet, from a file, not the API server |
| **`hostNetwork: true`** | **which network it uses**: no pod IP from `10.244.0.0/16`; it shares the node's own network, so it listens on `192.168.122.10` |

So they do have an IP, the node's, and each one listens on its own port: the API server on `:6443`, etcd on `:2379-2380`, the controller-manager on `:10257`, the scheduler on `:10259`.

**Why it has to be this way: a chicken-and-egg problem.** Regular pods get their IP from the CNI plugin (Flannel), and Flannel is installed *through the API server*. If the API server needed a pod IP, it could never start. Running the whole control plane on the node's network breaks the loop: it works before the pod network exists.

That's also why `advertiseAddress` must be the node's real IP, and why the three ranges must not overlap:

| Range | What |
|---|---|
| `192.168.122.0/24` | the VMs (Part 1): where the API server really listens |
| `10.244.0.0/16` | pod IPs, handed out by Flannel |
| `10.96.0.0/12` | Service IPs (virtual, implemented by kube-proxy) |

If the pod or Service range overlapped the VM network, a node would have two routes for the same addresses, and traffic to `192.168.122.10` could end up inside the pod network: the API server would become unreachable.

### Who talks to whom

If nobody has a pod IP in the control plane, how do you talk to the scheduler or the controller-manager? You don't. **Everything talks to the API server, and only to the API server:**

![Everyone talks to the API server](diagrams/02-hub-and-spoke.png)

- The **scheduler** watches pods with no node assigned, picks one, and writes its decision back (`spec.nodeName`).
- The **controller-manager** watches objects (Deployments, ReplicaSets, Nodes...) and creates or updates others so reality matches the desired state.
- Every **kubelet** watches the pods assigned to its node and starts them.
- **Only the API server talks to etcd.**

The ports `:10257` and `:10259` exist only for health checks and metrics. The components never call each other: they coordinate by reading and writing objects in the API server.

---

## 2. Bootstrap the cluster

> **Run on:** `cp-1` only. The workers come later, with `kubeadm join`.

### 2.1 The config file

All the settings go in a file instead of a long line of flags: easier to read, and it can live in the repo.

```bash
cat <<EOF > kubeadm-init.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///run/containerd/containerd.sock"
  kubeletExtraArgs:
    - name: node-ip
      value: "192.168.122.10"
localAPIEndpoint:
  advertiseAddress: "192.168.122.10"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "1.34.12"
apiServer:
  certSANs:
    - "127.0.0.1"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
EOF
```

Two documents in one file:

- **`InitConfiguration`**: about **this node**.
- **`ClusterConfiguration`**: about **the whole cluster**.

| Field | Value | Why |
|---|---|---|
| `criSocket` | containerd's socket | the runtime from [Part 2](../part-2-nodes/README.md) |
| `node-ip` | `192.168.122.10` | the IP the kubelet registers for this node. Matters on machines with several interfaces; here it's explicit to avoid surprises |
| `advertiseAddress` | `192.168.122.10` | the IP the API server announces and gets baked into its certificate and the join command: that's why `cp-1` has a fixed IP since Part 1 |
| `kubernetesVersion` | `1.34.12` | must match the installed kubeadm and kubelet |
| `certSANs` | `127.0.0.1` | extra name on the API server certificate, so `kubectl` can reach it later through an SSH tunnel from the workstation |
| `podSubnet` | `10.244.0.0/16` | Flannel's default range |
| `serviceSubnet` | `10.96.0.0/12` | Kubernetes' default |

`v1beta4` is the version of kubeadm's config format. In it, `kubeletExtraArgs` is a list of `name`/`value`; older guides use `v1beta3`, where it was a map.

> **No bootstrap token in the file.** Some guides hard-code one (`token: "123456.1234567890123456"`, `ttl: "0s"`): convenient, but a token that never expires lets anyone who sees it add nodes to your cluster forever. Without it, kubeadm generates a random one valid for 24 h (regenerate it with `kubeadm token create --print-join-command`), and the file has no secrets, so it can go in the repo.

### 2.2 Validate and pre-pull the images

```bash
sudo kubeadm config validate --config kubeadm-init.yaml
sudo kubeadm config images list --config kubeadm-init.yaml
sudo kubeadm config images pull --config kubeadm-init.yaml
sudo crictl images
```

- `validate` checks the YAML without touching anything: a wrong indent shows up now, not halfway through `init`.
- `images list` / `pull` fetch the control plane images. kubeadm doesn't download them itself: it asks containerd, through the CRI.
- `crictl images` shows them stored in containerd.

<!-- TODO: real output -->

> **RAM:** kubeadm's preflight wants ~1700 MB on a control plane and `cp-1` has 1792 MiB. If it complains, add `--ignore-preflight-errors=Mem` (acceptable in a lab).

> **Never commit** the `kubeadm join ...` line printed at the end of `init` (it carries the token) or `/etc/kubernetes/admin.conf` (cluster-admin credentials).

*Coming next: `kubeadm init --config kubeadm-init.yaml` with real output, the CNI, the workers joining, and a smoke test.*

---

## Done when

- [ ] `kubeadm init` on `cp-1`
- [ ] CNI installed, nodes `Ready`
- [ ] workers joined: `kubectl get nodes` → 3 nodes `Ready`
- [ ] a test deployment spread across nodes, reachable through a Service by name
