# Portworx Disaster Recovery

## Overview

Portworx provides the storage layer and cross-cluster disaster recovery that makes the demo's hop-by-hop failover possible. After the initial VMware-to-OpenShift migration via MTV, Portworx async DR replicates VM disks between OpenShift clusters, enabling the workload to "wander" from on-prem to ARO to ROSA to GCP and back.

## How Portworx async DR works

All async DR data flows through a shared S3 bucket -- source to S3 to destination. There is no direct spoke-to-spoke communication.

The S3 bucket is the trust boundary: whoever holds the S3 keys can participate in DR. This is why the same S3 credentials are configured on every spoke.

### The control plane hierarchy

- **ACM Hub** (ROSA): Hosts the Portworx Multi-Cluster operator and the DR custom resources (DisasterRecoveryPairs, ProtectionGroups, DisasterRecoveryActions). Does NOT run Portworx storage.
- **Spokes** (on-prem, ARO, ROSA, GCP): Run Portworx Enterprise with storage. The multicluster agent on each spoke watches the hub for DR instructions and creates local resources (BackupLocations, ClusterPairs, MigrationSchedules).

## DR pair ring topology

The pairs form a ring matching the demo chain:

```
on-prem --[on-prem-aro]--> ARO --[aro-rosa]--> ROSA --[rosa-gcp]--> GCP
    ^                                                                 |
    +-------------------[gcp-on-prem]---------------------------------+
```

All pairs are bidirectional and async, backed by the shared S3 bucket.

## DisasterRecoveryPairs (DRPs)

Created on the ACM hub cluster. Each pair specifies:

- Source and destination cluster names (matching ACM ManagedCluster names)
- S3 backup location and credentials
- ASYNC DR type, BI-DIRECTIONAL pair type

When a DRP is created, the Portworx multicluster agent on each spoke automatically creates BackupLocations, ClusterPairs, and credential Secrets.

## ProtectionGroups (PGs)

Created on the ACM hub cluster. Each PG defines:

- Which namespace to replicate (`wandering-workload`)
- The replication interval (15 minutes)
- `startApplications: false` -- VMs are replicated but not started at the destination (failover is a manual decision)
- `purgeDeletedResourcesAtSource: false` -- deleting a VM on source does not delete it on destination
- `skipServiceUpdate: true` -- prevents Stork from overwriting Service selectors during restore (which would break routing)

PGs are sequentially numbered to show demo progression:

1. `01-on-prem-to-aro`
2. `02-aro-to-rosa`
3. `03-rosa-to-gcp`
4. `04-gcp-to-on-prem`

Before creating a PG, the script waits (up to 180 seconds) for the DR pair to be fully ready on both spokes, checking Ready, BackupLocationCreated, and per-spoke Ready conditions.

## The failover flow

1. Create a ProtectionGroup for one hop
2. Wait for the initial sync to complete (data flows: source to S3 to destination)
3. Trigger failover manually in the Portworx UI (or via DisasterRecoveryAction CR)
4. VMs appear at the destination with their disks intact
5. Start the VMs, switch the load balancer to the new cluster
6. Plant a pin on the map -- the route URL proves it came from the new infrastructure

Failover itself is fast (seconds) because the data was already transferred during periodic sync. RPO is bounded by the 15-minute interval.

## The round-trip problem (gcp to on-prem)

The fourth hop completes the ring, sending the workload back to on-prem where it started. Portworx preserves volume names end-to-end through the DR chain. When the workload returns to on-prem, the PVCs it tries to restore collide with the originals that are still there.

The destination must be pre-cleaned before creating the PG: delete all VMs, VMIs, DataVolumes, pods, and PVCs in the `wandering-workload` namespace on on-prem, then wait for PVCs to fully clear so Portworx releases the underlying volumes.

## Stork admin-namespace

On ROSA and OSD, the managed-namespace SRE webhook blocks Stork from writing MigrationSchedules into `kube-system`. Every spoke must set `stork.args.admin-namespace=portworx` so Stork uses the `portworx` namespace instead. All spokes must use the SAME admin-namespace or cross-cluster restores fail with "backuplocation not found" -- the destination looks for the BackupLocation in the source's admin-namespace.

## Cleanup

### Simple cleanup

Dependency-ordered deletion from the hub: DR Actions, then Protection Groups, then DR Pairs. Trusts the Portworx multicluster agent to clean spoke-side resources. Quick but can leave orphans.

### Deep cleanup

Capture resource UIDs before deletion, delete hub objects, wait for agent processing, then scrub both spokes of every artifact the agent missed. Use UID-based matching (not name-based) because the agent truncates resource name prefixes but always preserves the full UID. Strip finalizers on resources that refuse to delete.

Why deep cleanup is needed: the Portworx multicluster agent reliably fails to clean destination-side MigrationSchedules and source-side BackupLocations in kube-system (whose credential Secrets get deleted first, creating broken pointers that poison future operations).

### Orphan audit

Read-only audit across hub and all spokes. Check for: orphaned DR Actions with dead PG references, BackupLocations and ClusterPairs not matching any live DRP UID, BackupLocations with missing credential Secrets, orphaned MigrationSchedules and Secrets. Classify each resource as OK, ORPHAN, or BROKEN.
