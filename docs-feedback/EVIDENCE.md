# Docs feedback: on-prem sizing requirements

Captured 18 Aug 2026 on a single-node lab (Ubuntu 26.04, k3s v1.36.3,
Helm 3.16.4, chart `26.224.260812114052`, 12 vCPU / 19 GB RAM).

---

## Claim 1 — the chart keeps 4 DAST scanners warm, and this is not documented

**Command**
```bash
grep -n "minReplicaCount" onpremises/charts/headless-dast/values.yaml
```

**Output**
```
30:      minReplicaCount: 4
```

**Context in that file**
```yaml
    scaledJob:
      pollingInterval: 90
      minReplicaCount: 4
      maxReplicaCount: 2500
```

Not mentioned in Prerequisites, Kubernetes requirements, or Installation.
You only find it by pulling the chart and reading the subchart values.

---

## Claim 2 — a scanner reserves 3 CPU / 7 Gi, not the documented 2 CPU / 4 GB

**Command**
```bash
kubectl get pod -n invicti <dast-scanner-pod> \
  -o jsonpath='{.spec.containers[*].resources}'
```

**Output**
```json
{"limits":{"cpu":"2","memory":"6Gi"},"requests":{"cpu":"2","memory":"6Gi"}}
{"limits":{"cpu":"1","memory":"1Gi"},"requests":{"cpu":"1","memory":"1Gi"}}
{}
```

Three containers: 2 CPU + 6Gi, plus a 1 CPU + 1Gi sidecar = **3 CPU / 7 Gi each**.

Docs (Prerequisites) say: *"Each DAST scanner pod needs about 2 CPU cores and
4 GB RAM for a single scan."* That understates memory by 75%.

**Arithmetic:** 4 warm scanners x 7 Gi = **28 Gi reserved before any scan runs**,
against a documented node minimum of 12 GB.

---

## Claim 3 — requests vs actual usage, which is what makes 12 GB look sufficient

**Commands**
```bash
kubectl describe node | grep -A6 "Allocated resources"
kubectl top node
```

**Output**
```
Allocated resources:
  Resource           Requests       Limits
  cpu                6550m (54%)    9250m (77%)
  memory             16568Mi (85%)  20322Mi (104%)

NAME      CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
invicti   242m         2%       1028Mi          5%
```

Later, fully started and idle:
```
invicti   338m         2%       5409Mi          27%
```

Kubernetes schedules on **requests** (85%), not usage (27%). Anyone sizing from
`kubectl top` or `htop` concludes the box is half empty, then hits Pending pods.

---

## Claim 4 — the consequence on a documented-minimum-ish node

**Command**
```bash
kubectl get pod -n invicti <pending-pod> \
  -o jsonpath='{range .status.conditions[*]}{.reason} {.message}{"\n"}{end}'
```

**Output**
```
Unschedulable 0/1 nodes are available: 1 Insufficient memory.
no new claims to deallocate, preemption: 0/1 nodes are available:
1 No preemption victims found for incoming pod.
```

Two of the four warm scanners never scheduled. Reducing
`keda.scanners.scaledJob.minReplicaCount` to 1 resolved it and the install then
converged with zero Pending pods.

---

## Claim 5 — storage guidance is inconsistent across adjacent pages

| Page | Figure |
|---|---|
| Prerequisites | "Storage: 50 GB available disk space" per node |
| Prerequisites | SeaweedFS "one volume with a maximum capacity of 250 GB" |
| Kubernetes requirements | SeaweedFS 1000Gi + 100Gi filer, "Minimum recommended total storage: 1.2 to 1.5 TB for production" |

Three different answers.

---

## Suggested doc changes

1. State that the chart holds `minReplicaCount: 4` warm scanners by default, and
   name the value to lower for single-node or POC installs.
2. Correct the per-scanner figure to include the sidecar: 3 CPU / 7 Gi.
3. Separate "platform services" sizing from "platform + default warm scanners",
   or raise the stated minimum. As written, 6 CPU / 12 GB cannot run the chart
   as shipped.
4. Add a line explaining that scheduling is on requests, not observed usage.
5. Reconcile the three storage figures.

## Suggested realistic sizing

| Use case | Practical minimum |
|---|---|
| POC / demo, 1 concurrent scan | 8 CPU / 32 GB / 200 GB |
| Small production, 2-3 scans | 16 CPU / 64 GB / 500 GB+ |
