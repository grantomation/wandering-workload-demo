# Live Demo Scripts (Portworx DR)

The `scripts/` directory contains shell automation for every phase of the demo:
cluster setup, MTV migration, Portworx DR failover, and cleanup. Each script is
self-contained, loads credentials from `credentials.env`, and logs into the
correct cluster automatically.

## How the scripts contribute to the demo

During the live demo, the presenter runs scripts to:

1. Pre-seed the target cluster with Services, Routes, and an MTV migration plan
2. Create Portworx DisasterRecoveryPair resources on the ACM hub
3. Create ProtectionGroups for each hop in the chain
4. Trigger failovers (currently manual in the Portworx UI)
5. Clean up after the demo

Each hop in the chain requires one command
(`./scripts/dr/03-create-protection-group.sh <pair-name>`) plus a manual
failover click in the Portworx UI. The scripts handle the waiting, readiness
checks, and pre-cleaning that would otherwise be tedious and error-prone on
stage.

## Credential management

All cluster credentials live in `credentials.env` (gitignored). Copy
`credentials.env.example` and fill in the values:

```bash
cp credentials.env.example credentials.env
# Edit credentials.env with your cluster passwords, S3 keys, etc.
```

The `_lib.sh` helper loads this file and provides two functions used by every
script:

| Function | Usage |
|----------|-------|
| `login_cluster <name>` | Log in via `oc` to a named cluster (hub, aro, rosa, gcp, on-prem) |
| `creds_for <name>` | Returns `user\|pass\|api` for a cluster (for scripts that need raw values) |

## Script reference

### Shared library

| Script | Purpose |
|--------|---------|
| `_lib.sh` | Loads `credentials.env`, provides `login_cluster` and `creds_for` helpers. Sourced by every other script. |

### Cluster setup (one-time, before the demo)

These scripts prepare the OpenShift clusters. Run them once when setting up the
demo environment, not during the live presentation.

| Script | Run on | Purpose |
|--------|--------|---------|
| `cluster-setup/01-install-portworx.sh` | All spokes (loops automatically) | Patch Portworx operator to 26.3.0-ea, configure StorageCluster plugin images, set LoadBalancer annotation, grant stork cluster-admin, activate SaaS license |
| `cluster-setup/02-configure-spoke-rbac.sh` | All spokes (loops automatically) | Grant cluster-reader, create kubevirt-admin ClusterRole, configure Portworx/Stork RBAC, disable common boot image import, clean up golden OS images |
| `cluster-setup/03-set-stork-admin-namespace.sh` | One spoke or ALL | Set Stork `admin-namespace=portworx` on the StorageCluster. **Required on every spoke** before DR migrations work. On ROSA/OSD, the managed-namespace webhook blocks Stork from writing to `kube-system`, so all spokes must use the same admin-namespace. |
| `cluster-setup/04-prep-migration-2tier.sh` | The MTV target cluster | Pre-seed for the 2-tier migration: creates the `wandering-workload` project, grants forklift permissions, creates backend Service + frontend Service + Routes (one per cluster hostname), creates NetworkMap + StorageMap + MTV Plan. Validates source VM names against the vSphere inventory before creating the Plan. |
| `cluster-setup/05-prep-migration-aio.sh` | The MTV target cluster | Same as above but for the single-VM (all-in-one) variant. No backend Service (DB is local). |

### Migration (MTV phase of the demo)

| Script | Run on | Purpose |
|--------|--------|---------|
| `migration/01-switch-cluster.sh` | Local machine | Quick `oc login` to a named cluster. Usage: `./scripts/migration/01-switch-cluster.sh ARO` |
| `migration/02-refresh-mtv-inventory.sh` | The MTV cluster | Force MTV to re-scan vCenter by deleting and restarting the forklift-controller and forklift-inventory pods. Use when the vSphere inventory view is stale. |

### Disaster recovery (Portworx DR phase of the demo)

| Script | Run on | Purpose |
|--------|--------|---------|
| `dr/02-create-dr-pairs.sh` | Hub | Create all 4 bi-directional DisasterRecoveryPair resources on the ACM hub. Each pair defines a source cluster, destination cluster, and S3 backup location. Skips pairs that already exist. Can also create a single pair: `./scripts/dr/02-create-dr-pairs.sh rosa-gcp` |
| `dr/03-create-protection-group.sh` | Hub | Create a single numbered ProtectionGroup for one hop. Waits for the DR pair to be ready on both spokes before applying. The `gcp-on-prem` hop auto-deletes VMs/PVCs on on-prem first (round-trip needs the Portworx volume names free). Use `--yes` to skip the cleanup prompt. |

### Cleanup (after the demo)

| Script | Run on | Purpose |
|--------|--------|---------|
| `cleanup/01-teardown-mtv-workload.sh` | One cluster or `all` | Full MTV/KubeVirt workload teardown. Kills forklift Plans/Migrations first (so nothing respawns), then loops deleting VMs/VMIs/pods/jobs/DVs/PVCs until the project is empty, then deletes the project. Preserves the namespace on ONPREM (clears resources only). |
| `cleanup/02-delete-dr-pairs.sh` | Hub | Delete all DR actions, protection groups, and DR pairs from the hub. The Portworx multicluster agent cleans up spoke-side resources automatically. |
| `cleanup/03-deep-clean-drp.sh` | Hub + spokes | Full teardown of individual or all DR pairs. Goes beyond `02-delete-dr-pairs.sh` by scrubbing both spokes of every artifact (backuplocations, clusterpairs, migrationschedules, secrets) matched by the DRP/PG UIDs. Handles finalizer-stuck resources. Supports `--dry-run` and `--all`. |
| `cleanup/04-audit-orphans.sh` | Hub + all spokes | Read-only audit. Walks the hub and every spoke looking for orphaned stork DR artifacts that don't map back to a live DR pair, and BackupLocations with missing credential secrets. Prints exact `oc delete` commands for each orphan. Nothing is deleted. |

## The DR pairs

The demo uses four bi-directional DisasterRecoveryPair resources that form a
ring:

```
on-prem ──── aro
  │            │
  │            │
gcp ──────── rosa
```

| Pair name | Source | Destination |
|-----------|--------|-------------|
| `on-prem-aro` | on-prem | aro |
| `aro-rosa` | aro | rosa |
| `rosa-gcp` | rosa | gcp |
| `gcp-on-prem` | gcp | on-prem |

Each pair is bi-directional and uses the same S3 bucket for backup storage.

## The protection groups

Each hop creates a numbered ProtectionGroup:

| PG name | DR pair | Direction |
|---------|---------|-----------|
| `01-on-prem-to-aro` | `on-prem-aro` | on-prem → aro |
| `02-aro-to-rosa` | `aro-rosa` | aro → rosa |
| `03-rosa-to-gcp` | `rosa-gcp` | rosa → gcp |
| `04-gcp-to-on-prem` | `gcp-on-prem` | gcp → on-prem |

Each PG:
- Protects the `wandering-workload` namespace
- Replicates every 15 minutes (async DR)
- Sets `startApplications: false` (VMs won't auto-start on the destination)
- Sets `purgeDeletedResourcesAtSource: false`

## Demo-day execution

See the [Runbook](RUNBOOK.md) for the step-by-step demo flow. In summary:

```bash
# Pre-flight (once, before the audience)
./scripts/cluster-setup/03-set-stork-admin-namespace.sh ALL
./scripts/cleanup/04-audit-orphans.sh              # optional, confirm clean slate

# Phase 1: MTV (VMware → on-prem)
./scripts/migration/01-switch-cluster.sh ONPREM
./scripts/cluster-setup/04-prep-migration-2tier.sh
# → Start migration in MTV UI

# Phase 2: Create DR pairs
./scripts/dr/02-create-dr-pairs.sh

# Phase 3: Hop-by-hop failover
./scripts/dr/03-create-protection-group.sh on-prem-aro
# → wait for sync → MANUAL FAILOVER in Portworx UI
# → repeat for aro-rosa, rosa-gcp, gcp-on-prem

# Cleanup
./scripts/cleanup/03-deep-clean-drp.sh --all
./scripts/cleanup/01-teardown-mtv-workload.sh all
./scripts/cleanup/04-audit-orphans.sh
```
