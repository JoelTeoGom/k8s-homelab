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

<!-- in progress -->

---

## Questions I had along the way

## Things that bit me

## Done when

- [ ] Flannel running, `cp-1` `Ready`, CoreDNS `Running` with a `10.244.x.x` IP
- [ ] workers joined: `kubectl get nodes` → 3 nodes `Ready`
- [ ] a test deployment spread across nodes, reachable through a Service by name
