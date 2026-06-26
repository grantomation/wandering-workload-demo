# Portworx on OpenShift: Install and DR Sync via S3

How Portworx is installed across the OpenShift spoke clusters, how the
clusters are paired for disaster recovery, and how data is replicated
through an S3 bucket using DisasterRecoveryPairs and ProtectionGroups.

---

## Architecture overview

```
                       ┌──────────────┐
                       │   ACM Hub    │
                       │  (control)   │
                       └──────┬───────┘
                              │ manages DR pairs + PGs
              ┌───────────────┼───────────────┐
              │               │               │
        ┌─────┴─────┐  ┌─────┴─────┐  ┌──────┴─────┐  ┌──────────┐
        │  on-prem   │──│    ARO    │──│    ROSA    │──│   GCP    │
        │  (spoke)   │  │  (spoke)  │  │   (spoke)  │  │  (spoke) │
        └─────┬──────┘  └───────────┘  └────────────┘  └────┬─────┘
              │                                              │
              └──────────────────────────────────────────────┘
                          ring topology (bi-directional)
```

Every spoke runs Portworx Enterprise with Stork. The ACM hub does **not**
run Portworx — it only hosts the multicluster DR custom resources
(`DisasterRecoveryPair`, `ProtectionGroup`).

All async DR data flows through a **single shared S3 bucket**. Portworx
uses this bucket as the backup location for every cluster pair — it writes
incremental snapshots from the source and restores them on the destination.

---

## 1. Installing Portworx on an OpenShift spoke

### Prerequisites

- OpenShift cluster with admin access (ARO, ROSA, OSD, or bare metal)
- For ARO: an Azure service principal (`AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET`)
- A Portworx Enterprise license key
- User workload monitoring enabled

### Step-by-step

#### a) Create the namespace and cloud secret

```bash
oc create namespace portworx

# ARO only — Azure credentials for cloud drives
oc create secret generic -n portworx px-azure \
    --from-literal=AZURE_TENANT_ID="$TENANT_ID" \
    --from-literal=AZURE_CLIENT_ID="$AZURE_CLIENT_ID" \
    --from-literal=AZURE_CLIENT_SECRET="$AZURE_CLIENT_SECRET"
```

#### b) Enable user workload monitoring

```bash
cat << EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

#### c) Install the Portworx operator via OLM

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: portworx-operatorgroup
  namespace: portworx
spec:
  targetNamespaces:
  - portworx
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: portworx-certified
  namespace: portworx
spec:
  channel: stable
  installPlanApproval: Automatic
  name: portworx-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  startingCSV: portworx-operator.v26.2.1
EOF
```

#### d) Apply the StorageCluster spec

Each cluster has a Portworx-generated `StorageCluster` YAML that defines
the storage topology (cloud drives, internal KVDB, etc.):

```bash
oc apply -f APP_REG_portworx_enterprise.yaml
```

#### e) Activate the license

```bash
oc exec -n portworx $(oc get pods -n portworx -l name=portworx \
    -o jsonpath='{.items[0].metadata.name}') -c portworx -- \
    /opt/pwx/bin/pxctl license activate saas --key "$PX_LICENSE_KEY"
```

#### f) Upgrade to EA builds (if needed)

The demo uses EA (early-access) builds for multicluster DR support.
`scripts/cluster-setup/01-install-portworx.sh` automates this across all
spokes. It patches the operator image, the OCP dynamic plugin images, adds
the LoadBalancer annotation, and grants Stork cluster-admin:

```bash
./scripts/cluster-setup/01-install-portworx.sh
```

### Post-install RBAC

`scripts/cluster-setup/02-configure-spoke-rbac.sh` grants the additional
roles every spoke needs: cluster-reader, KubeVirt admin, portworx wildcard,
and stork cluster-admin. It also cleans up golden OS images that waste
storage.

### Stork admin-namespace (critical for DR)

Every spoke **must** set `admin-namespace=portworx` on its StorageCluster.
Without this, DR migrations fail:

- On ROSA/OSD the managed-namespace webhook blocks Stork from writing
  `MigrationSchedule` resources into `kube-system`
- On the destination, the restore looks for the `BackupLocation` in the
  source's admin-namespace — if they differ, the restore fails with
  `backuplocation ... not found`

```bash
./scripts/cluster-setup/03-set-stork-admin-namespace.sh ALL
```

---

## 2. How DR sync works — the trust model

### The S3 bucket as shared state

All cluster pairs share a single S3 bucket, configured in
`credentials.env`:

```
S3_BUCKET=<bucket-name>
S3_REGION=<region>
S3_ENDPOINT=<endpoint>
S3_ACCESS_KEY=<iam-access-key>
S3_SECRET_KEY=<iam-secret-key>
```

The S3 IAM credentials need read/write access to this bucket. Every
`DisasterRecoveryPair` embeds the same S3 config, so any spoke in the ring
can read what any other spoke wrote. This is the trust boundary — whoever
holds the S3 keys can participate in DR.

### What flows through S3

Portworx async DR works by:

1. **Source spoke:** Stork takes a CloudSnap (incremental volume snapshot)
   of every PV in the protected namespace and uploads it to S3
2. **S3 bucket:** Stores the snapshot data plus metadata (resource
   definitions, volume mappings, namespace state)
3. **Destination spoke:** Stork on the destination reads the snapshot from
   S3, restores the volumes, and recreates all Kubernetes resources
   (VMs, PVCs, Services, etc.)

The sync is **asynchronous** — there is an RPO defined by the replication
interval (15 minutes in this demo). The data path is always
`source → S3 → destination`, never direct spoke-to-spoke.

---

## 3. DisasterRecoveryPairs (DRPs)

A `DisasterRecoveryPair` is a hub-level custom resource that establishes
the trust between two spoke clusters via the shared S3 backup location.

### What the DRP does

When you create a DRP on the hub:

1. The Portworx multicluster agent creates a `ClusterPair` on both spokes
2. It creates a `BackupLocation` on both spokes pointing to the S3 bucket
3. Both spokes validate connectivity to each other and to S3
4. The DRP reports readiness via status conditions:
   - `Ready` — overall pair health
   - `<cluster>-Ready` — individual spoke readiness
   - `<cluster>-BackupLocationCreated` — S3 config propagated

### The ring topology

The demo creates four bi-directional pairs forming a ring:

| Pair name      | Source  | Destination |
|----------------|---------|-------------|
| `on-prem-aro`  | on-prem | aro         |
| `aro-rosa`     | aro     | rosa        |
| `rosa-gcp`     | rosa    | gcp         |
| `gcp-on-prem`  | gcp     | on-prem     |

Each pair is `BI-DIRECTIONAL` and `ASYNC`:

```yaml
apiVersion: multicluster.portworx.com/v1alpha1
kind: DisasterRecoveryPair
metadata:
  name: on-prem-aro
  namespace: portworx
spec:
  backupLocation:
    s3Config:
      accessKeyID: <key>
      bucketName: <bucket>
      endpoint: <endpoint>
      region: <region>
      secretAccessKey: <secret>
      disableSSL: false
      useIam: false
    type: s3
  destinationCluster: aro
  disasterRecoveryType: ASYNC
  pairType: BI-DIRECTIONAL
  sourceCluster: on-prem
```

### Creating DRPs

```bash
./scripts/dr/02-create-dr-pairs.sh            # all 4 pairs
./scripts/dr/02-create-dr-pairs.sh rosa-gcp   # just one pair
```

The script runs on the ACM hub and skips pairs that already exist.

---

## 4. ProtectionGroups (PGs)

A `ProtectionGroup` tells Portworx **what** to replicate and **how often**.
It references a DRP and selects namespaces to protect.

### What the PG does

When you create a PG:

1. Stork on the source spoke starts a `MigrationSchedule` at the
   configured interval
2. Each interval, Stork snapshots all PVs in the selected namespace(s),
   uploads to S3, and captures all Kubernetes resource definitions
3. The destination spoke sees the new data in S3 and stages a restore
   (volumes are pre-created but VMs are not started)

### PG configuration

```yaml
apiVersion: multicluster.portworx.com/v1alpha1
kind: ProtectionGroup
metadata:
  name: 01-on-prem-to-aro
  namespace: portworx
spec:
  disasterRecoveryPairRef: on-prem-aro
  namespaceSelection:
    namespaces:
    - wandering-workload
  replicationSchedulePolicy:
    interval:
      intervalMinutes: 15
  resourceConfiguration:
    customSelection:
      includeApplicationVolumes: true
      includeCIDRBasedNetworkPolicies: true
    includeAllResources: true
  migrationConfiguration:
    startApplications: false
  advanceConfiguration:
    purgeDeletedResourcesAtSource: false
    ignoreDeletedNamespacesAtSource: true
    skipServiceUpdate: true
```

Key settings:

| Field | Value | Why |
|-------|-------|-----|
| `intervalMinutes` | `15` | Async RPO — data is at most 15 minutes stale |
| `startApplications` | `false` | VMs are restored but not booted — failover is a manual decision |
| `purgeDeletedResourcesAtSource` | `false` | Deleting a VM on source doesn't delete it on destination |
| `skipServiceUpdate` | `true` | Prevents Stork from overwriting Service selectors during restore |
| `includeAllResources` | `true` | Captures VMs, PVCs, Services, Routes, ConfigMaps — everything in the namespace |

### Creating PGs

```bash
./scripts/dr/03-create-protection-group.sh on-prem-aro   # PG 01
./scripts/dr/03-create-protection-group.sh aro-rosa       # PG 02
./scripts/dr/03-create-protection-group.sh rosa-gcp       # PG 03
./scripts/dr/03-create-protection-group.sh gcp-on-prem    # PG 04
```

The script waits for the referenced DRP to be fully ready on both spokes
before creating the PG, preventing a race where the first sync interval
fires before the destination has its `BackupLocation`.

### The round-trip problem (gcp-on-prem)

Portworx preserves volume names end-to-end through the DR chain. When the
workload loops back to on-prem (where it started), the restore collides
with the original PV names. The `gcp-on-prem` PG script handles this by
**pre-cleaning the destination** — deleting all VMs, PVCs, and DataVolumes
in the `wandering-workload` namespace on on-prem before creating the PG.

---

## 5. The sync and failover flow

```
  Source Spoke                    S3 Bucket               Destination Spoke
  ────────────                    ─────────               ──────────────────
  1. Stork takes CloudSnap    ──►
     of all PVs in namespace      2. Snapshot data
                                     + resource YAML     ──►
                                     stored in bucket        3. Stork restores
                                                                volumes + resources
                                                                (VMs stay off)

                         ── every 15 minutes ──

  4. Presenter triggers          (no S3 traffic          5. Stork starts VMs
     FAILOVER in PX UI           for failover)              on destination
```

**During normal sync:** Data flows source → S3 → destination every
15 minutes. The destination has pre-staged volumes and resource
definitions, but VMs are not running (`startApplications: false`).

**During failover:** The presenter clicks "Failover" in the Portworx UI
(or triggers it via the API). Stork on the destination starts the VMs.
No additional data needs to transfer — the last sync is already on disk.
The load balancer is then switched to the new cluster's route.

**Key point:** The failover itself is fast (seconds to start VMs) because
the heavy lifting (data transfer) already happened during the periodic
sync. The RPO is bounded by the 15-minute interval.

---

## 6. End-to-end sequence for the demo

```
1. Install Portworx on all spokes
   └── scripts/cluster-setup/01-install-portworx.sh

2. Configure RBAC + Stork admin-namespace
   ├── scripts/cluster-setup/02-configure-spoke-rbac.sh
   └── scripts/cluster-setup/03-set-stork-admin-namespace.sh ALL

3. MTV: migrate VMs from VMware → on-prem OpenShift
   └── (VMs now running on on-prem with Portworx PVs)

4. Create all DR pairs on the hub
   └── scripts/dr/02-create-dr-pairs.sh
       (establishes cluster pairs + S3 backup locations on every spoke)

5. Hop-by-hop failover:
   a. Create PG for on-prem → ARO
      └── scripts/dr/03-create-protection-group.sh on-prem-aro
      └── wait for first sync → failover in PX UI → switch LB

   b. Create PG for ARO → ROSA
      └── scripts/dr/03-create-protection-group.sh aro-rosa
      └── wait for first sync → failover in PX UI → switch LB

   c. Create PG for ROSA → GCP
      └── scripts/dr/03-create-protection-group.sh rosa-gcp
      └── wait for first sync → failover in PX UI → switch LB

   d. Create PG for GCP → on-prem (round-trip, pre-cleans destination)
      └── scripts/dr/03-create-protection-group.sh gcp-on-prem
      └── wait for first sync → failover in PX UI → switch LB

6. Cleanup
   └── scripts/cleanup/03-deep-clean-drp.sh --all
```

---

## 7. Troubleshooting

### DRP not becoming ready

Check conditions on the hub:

```bash
oc get disasterrecoverypairs.multicluster.portworx.com <pair> \
    -n portworx -o yaml
```

Common causes:
- Stork `admin-namespace` mismatch between spokes
- S3 credentials invalid or bucket doesn't exist
- Portworx API service not exposed (missing LoadBalancer annotation)

### Sync failing with "backuplocation not found"

The destination spoke can't find the `BackupLocation` that the source
created. Usually caused by mismatched `admin-namespace` values — re-run:

```bash
./scripts/cluster-setup/03-set-stork-admin-namespace.sh ALL
```

### Round-trip restore collisions

If the `gcp-on-prem` PG restore fails with volume name conflicts, the
destination wasn't pre-cleaned. Delete all VMs/PVCs on on-prem in the
`wandering-workload` namespace and recreate the PG.
