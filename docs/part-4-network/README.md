# Part 4 — Pod network and workers

*Flannel, `kubeadm join`, and a first app spread across three nodes*

[← Part 3: the control plane](../part-3-cluster/README.md) · [Index](../../README.md)

> **Status: in progress.** Written while building it: every output below is from my lab.

[Part 3](../part-3-cluster/README.md) left a control plane on `cp-1` with nowhere to put pods: the node is `NotReady` and CoreDNS is `Pending`, because there is no pod network yet. In this part the three nodes become one cluster.

The plan:

1. Install the pod network (Flannel)
2. Join the workers
3. Smoke test

---

## 1. Install the pod network (Flannel)

> **Run on:** `cp-1` only. Flannel is installed **through the API server**, and its DaemonSet puts a copy on every node by itself, including the workers that join later.

### Why Flannel

A CNI plugin has one job: give every pod an IP and make that IP reachable from every other pod, on any node. There are many; these are the three you meet everywhere:

| | Flannel | Calico | Cilium |
|---|---|---|---|
| How pods on different nodes talk | VXLAN overlay: pod packets wrapped in UDP between nodes | routing (BGP) or an overlay | eBPF in the kernel, overlay or routing |
| What runs on each node | one small agent (DaemonSet) | an agent, plus an operator | an agent, plus an operator; can replace kube-proxy |
| NetworkPolicy | **no** | yes | yes, also L7 |
| Weight | the lightest | medium | the heaviest |
| Moving parts to learn | few | more (BGP, IPAM pools) | many (eBPF, its own tooling) |

Flannel for this lab, because:

- **RAM.** The whole cluster lives in 5.7 GB and `cp-1` has 1.75 GB. Flannel is one small process per node; Cilium's agent alone would take a noticeable share of a worker.
- **It works on any network.** VXLAN only needs the nodes to reach each other over UDP, which they already do on `192.168.122.0/24`. No BGP, no router to configure.
- **Its default range is our `podSubnet`.** `10.244.0.0/16` is Flannel's default, and the one we put in `kubeadm-init.yaml` in Part 3.
- **Few moving parts.** The goal of this part is to see the pod network working end to end. With Flannel there's little in between: a bridge, a route per node, and a tunnel interface.

> **The trade-off: no NetworkPolicies.** Flannel connects pods but doesn't filter traffic between them. You can create a `NetworkPolicy` object and the API server accepts it, but nothing enforces it. When a later part needs policies, that's the moment for Calico or Cilium.

### 1.1 Before: what Flannel will build on

```bash
kubectl get node cp-1 -o jsonpath='{.spec.podCIDR}{"\n"}'
sudo ls /etc/cni/net.d/
ls /opt/cni/bin/
```

```
10.244.0.0/24

LICENSE  README.md  bandwidth  bridge  dhcp  dummy  firewall  host-device  host-local  ipvlan  loopback  macvlan  portmap  ptp  sbr  static  tap  tuning  vlan  vrf
```

(`/etc/cni/net.d/` needs `sudo`: only root can read it. Without it: `Permission denied`. The empty line is its output: nothing there yet.)

- **`podCIDR`**: because `kubeadm-init.yaml` has a `podSubnet`, the controller-manager runs with `--allocate-node-cidrs` and slices the `/16` into one **`/24` per node**. Flannel doesn't hand out IPs itself: each node reads its own `podCIDR`.
- **`/etc/cni/net.d/` is empty.** This is exactly why the node is `NotReady`: containerd looks here for a network config and finds none (`NetworkReady: false` since Part 2).
- **`/opt/cni/bin/`** has the base plugins, installed with the Kubernetes packages in Part 2. Each one is a small binary that does one job when a pod is created. The ones Flannel will use:

| Plugin | Job |
|---|---|
| `bridge` | creates the `cni0` bridge on the node and plugs each pod into it with a veth pair |
| `host-local` | the IPAM: picks a free IP from the node's `/24` and remembers it on disk |
| `portmap` | `hostPort`: maps a port on the node to a port in the pod |
| `loopback` | brings up `lo` inside every pod |

There's no `flannel` binary yet: Flannel brings its own and copies it here when it starts.

### 1.2 Read the manifest before applying it

`kubectl apply -f <url>` would work straight away, but downloading it first lets you check what you're about to install.

```bash
curl -LO https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
grep -A7 'net-conf.json' kube-flannel.yml
```

```
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "EnableNFTables": false,
      "Backend": {
        "Type": "vxlan"
      }
    }
```

- **`"Network": "10.244.0.0/16"`**: the same as our `podSubnet`. If they differed, Flannel would route one range while the nodes' `podCIDR`s came from another, and pods would get IPs nobody can reach.
- **`"Type": "vxlan"`**: the overlay. A packet from a pod on one node to a pod on another is wrapped in a UDP packet between the two nodes' real IPs.
- **`"EnableNFTables": false`**: Flannel writes its few firewall rules (NAT for pod traffic leaving the cluster) with iptables, the same as kube-proxy does by default.

What the file creates:

```bash
grep '^kind:' kube-flannel.yml
```

```
kind: Namespace
kind: ServiceAccount
kind: ClusterRole
kind: ClusterRoleBinding
kind: ConfigMap
kind: DaemonSet
```

| Object | Why Flannel needs it |
|---|---|
| `Namespace` `kube-flannel` | its own namespace, labelled to allow privileged pods (it needs to create network interfaces on the node) |
| `ServiceAccount` `flannel` | the identity its pods use to call the API server |
| `ClusterRole` + `ClusterRoleBinding` | what that identity may do: read every node (to learn each one's `podCIDR` and real IP) and annotate its own node (so the others know how to reach it) |
| `ConfigMap` `kube-flannel-cfg` | the two configs: `net-conf.json` (above) and `cni-conf.json`, the CNI config each node will get |
| `DaemonSet` `kube-flannel-ds` | one Flannel pod per node, now and on every node that joins later |

Flannel's pods talk to the API server like everyone else (Part 3's hub and spoke): there's no separate Flannel database.

### 1.3 Apply it

```bash
kubectl apply -f kube-flannel.yml
kubectl get pods -n kube-flannel -o wide -w     # -w watches live; Ctrl+C to stop
```

```
namespace/kube-flannel created
serviceaccount/flannel created
clusterrole.rbac.authorization.k8s.io/flannel created
clusterrolebinding.rbac.authorization.k8s.io/flannel created
configmap/kube-flannel-cfg created
daemonset.apps/kube-flannel-ds created

NAME                    READY   STATUS            RESTARTS   AGE   IP               NODE
kube-flannel-ds-6rpx2   0/1     Init:0/2          0          0s    192.168.122.10   cp-1
kube-flannel-ds-6rpx2   0/1     Init:1/2          0          5s    192.168.122.10   cp-1
kube-flannel-ds-6rpx2   0/1     PodInitializing   0          15s   192.168.122.10   cp-1
kube-flannel-ds-6rpx2   1/1     Running           0          16s   192.168.122.10   cp-1
```

- **One line per object** in the file, all created through the API server.
- **One Flannel pod**, because the DaemonSet puts one on every node and there's only one node so far. When the workers join, each gets its own without doing anything.
- **`Init:0/2` → `Init:1/2`**: two **init containers** run first, one after the other, and must finish before the main one starts. The first copies the `flannel` binary into `/opt/cni/bin/`; the second writes `cni-conf.json` as `/etc/cni/net.d/10-flannel.conflist`. Then `PodInitializing` → `Running`: `flanneld` itself, the agent that sets up the tunnel and the routes.
- **Its IP is `192.168.122.10`**: Flannel runs with `hostNetwork`, like the control plane. Same chicken-and-egg: it builds the pod network, so it can't depend on it.

Sixteen seconds later, the pods that were waiting:

```bash
kubectl get pods -n kube-system -o wide
```

```
NAME                           READY   STATUS    RESTARTS   AGE     IP               NODE
coredns-66bc5c9577-gr4bb       1/1     Running   0          6h31m   10.244.0.3       cp-1
coredns-66bc5c9577-pth78       1/1     Running   0          6h31m   10.244.0.2       cp-1
etcd-cp-1                      1/1     Running   0          6h31m   192.168.122.10   cp-1
kube-apiserver-cp-1            1/1     Running   0          6h31m   192.168.122.10   cp-1
kube-controller-manager-cp-1   1/1     Running   0          6h31m   192.168.122.10   cp-1
kube-proxy-z22dj               1/1     Running   0          6h31m   192.168.122.10   cp-1
kube-scheduler-cp-1            1/1     Running   0          6h31m   192.168.122.10   cp-1
```

- **CoreDNS is `Running`, with the first pod IPs of the cluster: `10.244.0.2` and `10.244.0.3`.** Both inside `cp-1`'s `10.244.0.0/24`. Everything else still shows `192.168.122.10`: they're `hostNetwork`.
- **Same names, `AGE 6h31m`**: these are the **same two pods** that were `Pending` since `init`. Nothing recreated them. As soon as the node went `Ready`, the `not-ready` taint was removed, the scheduler placed them on `cp-1` (CoreDNS tolerates the control-plane taint) and the kubelet started them, now with a network.
- **Why `.2` and not `.1`?** `10.244.0.1` belongs to the node itself, on the `cni0` bridge: it's the pods' gateway. `host-local` hands out IPs from `.2` up.

```bash
kubectl get nodes
```

```
NAME   STATUS   ROLES           AGE     VERSION
cp-1   Ready    control-plane   6h33m   v1.34.12
```

**`Ready`.** The kubelet found a network config, containerd reports `NetworkReady: true`, and the `not-ready` taint is gone.

Flannel also leaves its own mark on the node:

```bash
kubectl describe node cp-1 | grep NetworkUnavailable
```

```
NetworkUnavailable   False   Sat, 24 Oct 2026 21:15:26 +0000   Sat, 24 Oct 2026 21:15:26 +0000   FlannelIsUp   Flannel is running on this node
```

A double negative: **`NetworkUnavailable: False`** means the network **is** available. This node condition isn't set by the kubelet: **Flannel writes it** (reason `FlannelIsUp`) when it starts, through the API server. That's one of the things its `ClusterRole` allows. The timestamp is the moment the Flannel pod came up.

### 1.4 What Flannel built on the node

> **Run on:** `cp-1`. Every node that joins later gets the same, with its own `/24`.

![What Flannel builds on a node](diagrams/01-flannel-on-a-node.png)

The two files the init containers left:

```bash
sudo ls /etc/cni/net.d/              # 10-flannel.conflist
ls /opt/cni/bin/ | grep flannel      # flannel
```

**The CNI config**, what containerd reads every time it creates a pod:

```bash
sudo cat /etc/cni/net.d/10-flannel.conflist
```

```json
{
  "name": "cbr0",
  "cniVersion": "1.0.0",
  "plugins": [
    {
      "type": "flannel",
      "delegate": {
        "hairpinMode": true,
        "isDefaultGateway": true
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      }
    }
  ]
}
```

- **`plugins`** is a chain: containerd runs each binary from `/opt/cni/bin/` in order, `flannel` then `portmap`.
- **`"type": "flannel"`** doesn't build anything itself. It reads the node's settings (below) and **delegates** to the `bridge` plugin with `host-local` for IPs: the base plugins from Part 2 do the actual work.
- **`isDefaultGateway`**: every pod's default route points at the bridge, `10.244.0.1`.
- **`hairpinMode`**: a pod can reach **itself through a Service IP**. The packet leaves through its veth, kube-proxy's rules send it back to the same pod, and the bridge has to let it return through the port it came from. Without it, that rare case silently fails.
- **`portmap`** comes second, for pods that ask for a `hostPort`.
- `"name": "cbr0"` is just a historical label; the bridge itself is called `cni0`.

**This node's share**, written by `flanneld` from the node's `podCIDR`:

```bash
cat /run/flannel/subnet.env
```

```
FLANNEL_NETWORK=10.244.0.0/16
FLANNEL_SUBNET=10.244.0.1/24
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
```

| Line | Means |
|---|---|
| `FLANNEL_NETWORK` | the whole pod network, every node |
| `FLANNEL_SUBNET` | **this** node's `/24`, written as the gateway's address: `10.244.0.1` |
| `FLANNEL_MTU=1450` | 1500 (the VM network) minus **50 bytes** of VXLAN wrapping (outer IP, UDP and VXLAN headers plus the inner Ethernet header). Pods use smaller packets so the wrapped ones still fit |
| `FLANNEL_IPMASQ=true` | traffic from a pod to anything **outside** `10.244.0.0/16` (the Internet, the host) leaves with the node's IP. Pod IPs only mean something inside the cluster |

**The interfaces and the route:**

```bash
ip -br addr show | grep -E 'cni0|flannel'
ip route | grep 10.244
```

```
flannel.1        UNKNOWN        10.244.0.0/32 fe80::70a2:32ff:feb8:5374/64
cni0             UP             10.244.0.1/24 fe80::2c89:9eff:fe26:d259/64

10.244.0.0/24 dev cni0 proto kernel scope link src 10.244.0.1
```

- **`cni0`**: a Linux bridge, a virtual switch inside the node. Each pod is plugged into it with a **veth pair**, a virtual cable with one end inside the pod and the other on the bridge. Its `10.244.0.1` is the pods' gateway, which is why CoreDNS got `.2` and `.3`.
- **`flannel.1`**: the **VXLAN tunnel**. Packets for pods on other nodes go in here, get wrapped in UDP, and travel to the other node's `192.168.122.x`. `UNKNOWN` is normal for a virtual device like this one, not an error.
- **One route**, `10.244.0.0/24 dev cni0`: pods on this node, through the bridge. There's no route to any other `/24` yet, because there are no other nodes. When a worker joins, `flanneld` adds `10.244.1.0/24 via flannel.1`, and `flannel.1` starts carrying traffic.


### 1.5 How a pod gets its IP, and when Flannel acts

It's easy to picture Flannel "giving" each pod its IP. It doesn't: **two different things** are at work, on two different timescales.

![How a pod gets its IP](diagrams/02-how-a-pod-gets-its-ip.png)

**Per pod: a short-lived binary.** Every time a pod lands on a node:

| # | Who | What |
|---|---|---|
| 1 | API server | stores the new pod: no node, no IP yet |
| 2 | scheduler | picks a node and writes it in `spec.nodeName` |
| 3 | kubelet on that node | sees a pod assigned to it |
| 4 | containerd | creates the `pause` container and a **new network namespace**: the pod's own, empty network stack |
| 5 | containerd | reads `10-flannel.conflist` and runs `/opt/cni/bin/flannel` with the command `ADD` |
| 6 | `flannel` binary | reads `/run/flannel/subnet.env` (this node's `/24`, MTU) and hands the work to `bridge` |
| 7 | `bridge` | creates a **veth pair**: one end becomes `eth0` inside the pod, the other is plugged into `cni0`. Sets the default route via `10.244.0.1` |
| 8 | `host-local` | picks the next free IP in the node's `/24` and records it as a file in `/var/lib/cni/networks/cbr0/` |
| 9 | kubelet | reports the IP to the API server (`status.podIP`): now `kubectl get pods -o wide` shows it |

The binaries exit as soon as they finish. When the pod is deleted, containerd runs the same chain with `DEL`: the veth disappears and `host-local` frees the IP.

In step 4, the [`pause` container](../deep-dives/pods-and-pause/README.md) is a tiny container that holds the pod's network, so the IP survives when the app container restarts.

**Per node: `flanneld`, always running.** It never hears about pods. It acts:

| When | What it does |
|---|---|
| it starts | reads its node's `podCIDR`, writes `subnet.env`, creates `flannel.1`, marks the node `NetworkUnavailable: False` |
| another node joins | adds a route to that node's `/24` **through `flannel.1`**, plus what the tunnel needs to know that node's real IP |
| a node leaves | removes them |

Once the routes exist, **the kernel forwards every packet** (bridge, routes, VXLAN). `flanneld` isn't in the data path: if it stopped, existing pods would keep talking; only changes (new nodes) would stop being applied.

> In the diagram the example pod lands on `cp-1` to keep everything in one picture. A normal pod wouldn't: the control-plane `NoSchedule` taint sends it to a worker, where the same steps happen with that node's own `/24`.

---

## Questions I had along the way

**Why do both CoreDNS pods end up on `cp-1`?**
It was the only node when they got scheduled. Kubernetes doesn't move running pods to rebalance: they stay on `cp-1` even after the workers join. A `kubectl rollout restart deployment coredns -n kube-system` creates new ones, and the scheduler then spreads them.

**Why does Flannel's pod have the node's IP?**
`hostNetwork`, for the same chicken-and-egg reason as the control plane: it creates the pod network, so it can't live inside it.

**Does Flannel assign each pod its IP? When does it react?**
No. A CNI binary run by containerd does it, once per pod, using `host-local`. `flanneld` reacts to **nodes**: at start and when one joins or leaves. → [1.5](#15-how-a-pod-gets-its-ip-and-when-flannel-acts)

**What is the `pause` container for? Does traffic go through it?**
It's the anchor of the pod's **sandbox**: the network namespace with the pod's IP lives as long as the pod, not as long as one container, so a crashed container comes back with the same IP. No traffic goes through it. → [Deep dive](../deep-dives/pods-and-pause/README.md)

**Do I have to install Flannel again on each worker?**
No. `kubectl apply` runs once, from `cp-1`: it only creates objects in the API server. The DaemonSet then starts one Flannel pod on every node, and on every node that joins later. Each one writes that node's own `subnet.env` (its own `/24`), its own `10-flannel.conflist`, `cni0` and `flannel.1`.

## Things that bit me

- **`ls /etc/cni/net.d/` → `Permission denied`**: the folder is root-only. `sudo ls`.
- **`nodes "k8s-ctr" not found`**: a command copied from another guide still had that guide's node name. Here it's `cp-1`.

## Done when

- [x] Flannel running, `cp-1` `Ready`, CoreDNS `Running` with a `10.244.x.x` IP
- [ ] workers joined: `kubectl get nodes` → 3 nodes `Ready`
- [ ] a test deployment spread across nodes, reachable through a Service by name
