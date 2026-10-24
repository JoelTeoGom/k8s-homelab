# Phase 2 · Part B — Bootstrap the cluster

[← Part A: prepare the nodes](01-prepare-nodes.md) · [Phase 2 index](README.md)

Part A left every node with the OS prepared, containerd and the Kubernetes packages, and a kubelet crash-looping because nothing has configured it yet. This part creates the cluster: the control plane on `cp-1`, the pod network, and the workers joining.

![Starting point: the right-hand column is what this part creates](diagrams/01-node-stack.png)

## Step 8 — `kubeadm init` on cp-1

### What init/join give the kubelet

Before `init`, both places kubeadm will fill are empty:

```bash
tree /etc/kubernetes /var/lib/kubelet
```

```
/etc/kubernetes
└── manifests          # created by the package, empty: static pod manifests go here
/var/lib/kubelet       # empty: config.yaml and kubeadm-flags.env go here
```

The kubelet already knows **where** its files will be. Its service is two files:

```bash
cat /usr/lib/systemd/system/kubelet.service
cat /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
```

**The base unit** (`kubelet.service`):

```ini
[Service]
ExecStart=/usr/bin/kubelet       # the bare binary, no flags
Restart=always                   # if it dies, start it again
StartLimitInterval=0             # ...and never give up
RestartSec=10                    # wait 10 s between attempts
```

`StartLimitInterval=0` is what makes the crash-loop endless: by default systemd stops restarting a unit that fails ~5 times in a short window ("start limit hit"); `0` disables that limit.

**The kubeadm drop-in** (`kubelet.service.d/10-kubeadm.conf`). A drop-in **modifies** a unit without editing it; this one turns the bare kubelet into the one kubeadm expects:

```ini
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
```

| Line | What it does |
|---|---|
| `KUBELET_KUBECONFIG_ARGS` | where its kubeconfig will be: `kubelet.conf` (final) or `bootstrap-kubelet.conf` (temporary, during `join`) |
| `KUBELET_CONFIG_ARGS` | `--config=/var/lib/kubelet/config.yaml`: **the missing file it dies on** |
| `EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env` | node-specific flags written by `init`/`join`. The leading **`-`** means "fine if it doesn't exist", which is why the journal only *warns* that `KUBELET_KUBEADM_ARGS` is empty |
| `EnvironmentFile=-/etc/default/kubelet` | a slot for **your** extra flags (`KUBELET_EXTRA_ARGS`), as a last resort |
| `ExecStart=` (empty) | **clears** the base unit's `ExecStart`; without it systemd would see two and refuse to start |
| `ExecStart=/usr/bin/kubelet $...` | the real command: the binary plus all those variables |

Those files just don't exist yet, which is why it crash-loops. `kubeadm init` / `join` write three of them:

| File | Tells the kubelet |
|---|---|
| `/var/lib/kubelet/config.yaml` | **how to behave**: `cgroupDriver: systemd` (same as containerd), the cluster DNS IP, where static pod manifests live (`/etc/kubernetes/manifests`)... |
| `/etc/kubernetes/kubelet.conf` (a kubeconfig) | **who to talk to and who it is**: the API server address (`https://192.168.122.10:6443`) and its client certificate, identifying it as `system:node:<hostname>` |
| `/var/lib/kubelet/kubeadm-flags.env` | **node-specific flags**, loaded by the drop-in as `$KUBELET_KUBEADM_ARGS`: the containerd socket, the `pause` image... |

How the node gets its certificate is the difference between the two commands:

- **`init` on `cp-1`:** kubeadm has just created the cluster CA, so it signs the kubelet's certificate itself and writes `kubelet.conf` directly.
- **`join` on a worker:** the worker doesn't have the CA. kubeadm writes `bootstrap-kubelet.conf` holding the **bootstrap token** from the `join` command. The kubelet uses it to authenticate to the API server and ask for a certificate (**TLS bootstrap**). Once signed, it saves its own `kubelet.conf` and the token is no longer needed.

As soon as those files exist, the kubelet starts, reads its config, connects and stays `running`: the `NRestarts` counter from 7.6 stops.

### Running init

Flags that matter in this lab:

| Flag | Why |
|---|---|
| `--apiserver-advertise-address=192.168.122.10` | the IP the API server announces; it's baked into certificates and the join command, which is why cp-1 has a fixed IP since Phase 1 |
| `--pod-network-cidr=10.244.0.0/16` | Flannel's default range; doesn't overlap the VM network (`192.168.122.0/24`) or the Service range (`10.96.0.0/12`) |
| `--apiserver-cert-extra-sans=127.0.0.1` | so `kubectl` can later reach the API server from the workstation through an SSH tunnel |

> **RAM:** kubeadm's preflight wants ~1700 MB on a control plane and cp-1 has 1792 MiB. If it fails on memory, `--ignore-preflight-errors=Mem` is acceptable in a lab.

> **Never commit** the `kubeadm join ...` line (it carries a bootstrap token) or `/etc/kubernetes/admin.conf` (cluster-admin credentials).

<!-- TODO: real output (redacted), kubeconfig, kubectl get pods -n kube-system -->

## Step 9 — CNI

Until a CNI is installed, nodes stay `NotReady` and CoreDNS stays `Pending`. Expected, not an error.

<!-- TODO -->

## Step 10 — Join the workers

<!-- TODO -->

## Step 11 — Verify

<!-- TODO: test pods on different nodes + Service + DNS -->

---

