# invicti-platform.sh

Lifecycle manager for **Invicti Platform on-premises** (Helm / Kubernetes).
Built from the official docs and validated against a real deployment:
https://docs.invicti.com/ip/category/invicti-platform-on-premises

Verified end-to-end on Ubuntu 26.04 with k3s v1.36.3, Helm 3.16.4 and chart
`26.224.260812114052` — 46 pods Running and the platform answering on HTTPS.

## Commands

| Command | What it does |
|---|---|
| `install` | Preflight → k3s + Helm 3 (if needed) → registry login → chart deploy |
| `check` | Every preflight test, changes nothing |
| `status` | Cluster, release, pods, storage, networking, events, reachability |
| `upgrade` | `helm upgrade` with `--reset-then-reuse-values --cleanup-on-fail` |
| `reconfigure` | Re-render `values.yaml` from flags and apply it |
| `backup` | Quiesced backup: values, secrets, PVC data, chart version |
| `restore` | Restore a backup, including into a different cluster |
| `uninstall` | Release only, or `--purge-data` / `--purge` / `--purge-all` |
| `logs` | Redacted support bundle for Invicti Support |
| `version` | Script, Helm, kubectl, k3s and Kubernetes versions |

## Quick start

```bash
sudo ./invicti-platform.sh install \
  --email you@company.com \
  --license XXXX-XXXX-XXXX \
  --host invicti.company.com
```

Production, with mail and a real certificate:

```bash
sudo ./invicti-platform.sh install --yes \
  --email you@company.com --license XXXX --host invicti.company.com \
  --smtp-host smtp.company.com --smtp-port 587 \
  --smtp-user apikey --smtp-pass 'secret' --smtp-from no-reply@company.com \
  --tls-cert /etc/ssl/certs/invicti.pem --tls-key /etc/ssl/private/invicti.key
```

## Uninstall levels

```bash
./invicti-platform.sh uninstall               # release only, data survives
./invicti-platform.sh uninstall --purge-data  # + PVCs and namespace  (DESTROYS DATA)
./invicti-platform.sh uninstall --purge       # + cluster-scoped leftovers  <-- before a clean reinstall
./invicti-platform.sh uninstall --purge-all   # + k3s itself
```

`--purge` matters, and this is the confirmed root cause of failed reinstalls.

The chart ships KEDA's CRDs in `charts/keda/crds/`, and Helm **never deletes
anything from a `crds/` directory**. Worse, those CRDs carry the
`customresourcecleanup.apiextensions.k8s.io` finalizer: once the KEDA operator is
gone, nothing can finish cleaning up the custom resources, so the CRD sticks in
`Terminating` forever. Observed on the test cluster:

```
$ kubectl get crd | grep keda
scaledjobs.keda.sh              2026-08-18T08:59:58Z
triggerauthentications.keda.sh  2026-08-18T08:59:58Z
$ kubectl get crd scaledjobs.keda.sh -o jsonpath='{.metadata.finalizers}'
["customresourcecleanup.apiextensions.k8s.io"]
```

`uninstall --purge` detects these, strips the finalizers and retries the delete,
then re-checks and reports honestly if anything survived rather than claiming
success.

## Backup and restore

```bash
./invicti-platform.sh backup --output /mnt/backups/invicti-$(date +%F).tar.gz
./invicti-platform.sh backup --no-pvc          # config only, stays online
./invicti-platform.sh restore --from /mnt/backups/invicti-2026-08-18.tar.gz
```

Follows the vendor procedure: StatefulSets are scaled to zero before PVCs are
read so the copy is consistent, and the Helm release secret
(`sh.helm.release.v1.*`) is excluded — restoring it breaks a fresh install on a
new cluster. Verified by restoring seeded data into an emptied volume.

The archive is mode `0600` and holds your license key plus any SMTP/database
passwords. Treat it as a secret.

## Problems this script solves (all hit during real testing)

**k3s Traefik steals ports 80/443.** k3s bundles Traefik, which claims the host
ports through its own `svclb` DaemonSet. The chart's `nginx-service` is also a
LoadBalancer on 443, so its svclb pod sits `Pending` forever and the platform
never gets an external address. k3s is installed with `--disable=traefik`, and an
existing Traefik is detected and can be retired.

**Four warm DAST scanners will not fit a small node.** The chart keeps
`minReplicaCount: 4` scanners ready, each requesting 2 CPU + 6 Gi plus a 1 Gi
sidecar — roughly 28 Gi before a single scan runs. On smaller nodes the surplus
sits Pending forever and looks like a broken install. The script sizes this to
the node automatically (`--scanner-min-replicas`, default `auto`) and prunes
stale scanner Jobs that KEDA leaves behind when the count is lowered.

**Single-node rolling updates deadlock.** The default Deployment strategy
(`maxSurge=1, maxUnavailable=0`) needs the new pod Ready before the old one is
removed, so both must fit at once. On a tight node the rollout never converges
and Helm times out. Affected Deployments are switched to stop-then-start.

**`values-resources-recommended.yaml` is multi-node HA sizing.** On one node most
pods stay Pending, so a profile that fits the node is chosen with an automatic
fallback — and the profile that actually worked is recorded in
`~/invicti-onprem/.invicti-state` so `upgrade` and `reconfigure` reuse it instead
of re-deriving a heavier one.

**Helm 4 after 4.1.1 is unsupported.** It applies server-side and fights KEDA for
ownership of ScaledJob resource fields. Helm 3 is pinned, and a snap-installed
Helm 4 is removed because it wins `$PATH`.

**Ubuntu leaves most of the disk unallocated.** The guided LVM installer caps node
ephemeral-storage and makes pods unschedulable while `df` still shows free space.
The script offers to reclaim it — 145 GB recovered on the test host (98 → 243 GB).

**Stuck namespaces, PVC finalizers and released PersistentVolumes** are cleared
during purge so storage can rebind.

## Non-interactive use

```bash
INVICTI_EMAIL=... INVICTI_LICENSE_KEY=... PLATFORM_HOST=... \
  ./invicti-platform.sh install --yes
```

Every flag has a matching environment variable. If you are not root and cannot be
prompted, run the whole script under `sudo`, export `SUDO_ASKPASS`, or grant the
user passwordless sudo.

## Files it creates

| Path | Contents |
|---|---|
| `~/invicti-onprem/values.yaml` | Rendered chart values, mode 0600 |
| `~/invicti-onprem/.invicti-state` | Profile/chart/scanner settings that worked |
| `~/invicti-onprem/onpremises/` | Extracted chart |
| `~/invicti-backups/` | Backup archives |
| `~/invicti-logs/` | Run logs and support bundles |

## Sizing guidance

The documented minimum is 6 CPU / 12 GB / 50 GB **per worker node**, but that
assumes a multi-node cluster. For a usable single-node install budget
**8+ CPU and 32 GB RAM**; 19 GB works but leaves no headroom for concurrent
scans and forces the `none` resource profile. Production storage guidance is
1.2–1.5 TB because SeaweedFS holds scan artefacts.

`--help` lists every flag.
