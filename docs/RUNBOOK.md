# Demo Runbook

Step-by-step guide for running the Wandering Workload demo.

**Demo chain:** VMware → on-prem → ARO → ROSA → GCP → on-prem

---

## Pre-flight (before the audience arrives)

These steps prepare the environment. Run them once, well before the demo.

### 1. Verify credentials

```bash
cp credentials.env.example credentials.env
# Fill in all cluster passwords, S3 keys, Azure credentials, PX license key
```

### 2. Set Stork admin-namespace on all spokes

Every spoke must have `admin-namespace=portworx` or DR migrations fail with
either "denied managed namespaces" (ROSA) or "backuplocation not found"
(destination restore).

```bash
./scripts/cluster-setup/03-set-stork-admin-namespace.sh ALL
```

### 3. Confirm clean slate (optional)

```bash
./scripts/cleanup/04-audit-orphans.sh
```

Should report 0 orphans, 0 broken. If not, run the cleanup scripts first.

### 4. Start the load balancer

```bash
cd apps/loadbalancer
./hosts.sh add
ansible-playbook ../../ansible/loadbalancer/deploy_podman.yml
```

Open the dashboard in a browser tab: `https://dashboard.<your-domain>`

### 5. Verify the VMware VMs are running

Open vSphere and confirm `wandering-front` and `wandering-db` are powered on.
Browse to the app's VMware address and plant a test pin.

---

## Phase 1 — MTV: VMware → on-prem OpenShift

**What the audience sees:** The legacy VMs are lifted from VMware into
OpenShift Virtualization, unchanged. The app comes up on a new URL.

### Presenter setup

```bash
./scripts/migration/01-switch-cluster.sh ONPREM
./scripts/cluster-setup/04-prep-migration-2tier.sh
```

This creates the project, Services, Routes, and the MTV Plan on the on-prem
cluster.

### During the demo

1. **Show the app running on VMware.** Plant a pin. Point out it's plain VMs,
   no containers, running on traditional infrastructure.

2. **Start the MTV migration.** In the OpenShift console (on-prem), navigate
   to Virtualization → Migrations → Plans and click **Start** on the plan.

3. **Talk while it runs.** Explain that MTV copies the VM disks into KubeVirt
   VMs on OpenShift. The small golden image (~1.7 GB per disk) means this takes
   under a minute. The guest OS is unchanged — no repackaging, no Dockerfile.

4. **When complete:** the VMs boot on OpenShift. The `wandering-env-detect`
   service detects `kvm`, removes the `/etc/hosts` entries, and CoreDNS takes
   over. The app resolves `wandering-backend-svc` via the Kubernetes Service.

5. **Switch the load balancer** to on-prem (click the node or run the trigger):
   ```bash
   ./apps/loadbalancer/trigger.sh 2
   ```

6. **Plant a pin.** The sidebar shows the on-prem route. The data from VMware
   is still there — same pins, same colours.

---

## Phase 2 — Create DR pairs

**What the audience sees:** Nothing visible yet. This sets up the Portworx DR
infrastructure for the next phase.

```bash
./scripts/dr/02-create-dr-pairs.sh
```

Creates all 4 bi-directional DisasterRecoveryPair resources on the ACM hub.
This takes about 30 seconds. You can explain what's happening while it runs:
Portworx is establishing cluster pairs and backup locations between every spoke
in the chain.

---

## Phase 3 — Hop-by-hop failover

Each hop follows the same pattern:

1. Run the protection group script
2. Wait for the first sync to complete
3. Trigger the failover in the Portworx UI
4. Switch the load balancer
5. Plant a pin

### Hop 1: on-prem → ARO

```bash
./scripts/dr/03-create-protection-group.sh on-prem-aro
```

Wait for the ProtectionGroup to show as synced in the Portworx UI, then trigger
a **Failover** to ARO.

After the VMs start on ARO:
```bash
./apps/loadbalancer/trigger.sh 3     # switch LB to the ARO position
```

Plant a pin. The sidebar shows the ARO route.

### Hop 2: ARO → ROSA

```bash
./scripts/dr/03-create-protection-group.sh aro-rosa
```

Wait for sync → **Failover to ROSA**.

```bash
./apps/loadbalancer/trigger.sh 4     # switch LB to the ROSA position
```

Plant a pin.

### Hop 3: ROSA → GCP

```bash
./scripts/dr/03-create-protection-group.sh rosa-gcp
```

Wait for sync → **Failover to GCP**.

```bash
./apps/loadbalancer/trigger.sh 5     # switch LB to the GCP position
```

Plant a pin.

### Hop 4: GCP → on-prem (home)

```bash
./scripts/dr/03-create-protection-group.sh gcp-on-prem
```

This hop is special: it's a round trip back to on-prem. The script
**automatically pre-cleans** the destination (deletes VMs/PVCs on on-prem)
because Portworx preserves volume names end-to-end and the restore would
collide with the originals. Use `--yes` to skip the confirmation prompt.

Wait for sync → **Failover to on-prem**.

```bash
./apps/loadbalancer/trigger.sh 2     # switch LB back to on-prem
```

Plant a final pin. The workload is home.

---

## Closing

Zoom out on the map. The trail shows every cluster the workload visited. The
data is intact — every pin, every colour, every route label survived every hop.
The VMs are home. No application changes were needed at any point.

---

## Cleanup (after the demo)

```bash
./scripts/cleanup/03-deep-clean-drp.sh --all        # tear down all DR state
./scripts/cleanup/01-teardown-mtv-workload.sh all    # delete VMs/PVCs on all spokes
./scripts/cleanup/04-audit-orphans.sh                # confirm clean slate
```

Tear down the load balancer:
```bash
ansible-playbook ansible/loadbalancer/teardown_podman.yml
cd apps/loadbalancer
./hosts.sh remove
```

## Troubleshooting during the demo

### MTV migration is slow or stuck

If the migration is taking too long, the inventory may be stale:
```bash
./scripts/migration/02-refresh-mtv-inventory.sh
```

To retry a failed migration without recreating the Plan:
```bash
./scripts/migration/01-switch-cluster.sh ONPREM
KEEP_PLAN=true DELETE_PROJECT=false ./scripts/cleanup/01-teardown-mtv-workload.sh wandering-workload
```
Then start the Plan again in the MTV UI.

### App not responding after a hop

The app waits for the DB before opening its port. "App not listening" almost
always means "can't reach the DB."

```bash
# Check the Service has endpoints
oc get endpoints wandering-backend-svc -n wandering-workload

# Check the VM is running
oc get vmi -n wandering-workload

# Check the app logs
oc exec -n wandering-workload <frontend-vmi-pod> -- journalctl -u wandering-workload -e
```

### DR pair not becoming ready

The `03-create-protection-group.sh` script waits up to 180 seconds for the DR
pair to be ready on both spokes. If it times out:

1. Check the DR pair conditions on the hub:
   ```bash
   oc get disasterrecoverypairs.multicluster.portworx.com <pair> -n portworx -o yaml
   ```
2. Check Stork logs on both spokes for errors
3. Re-run `03-set-stork-admin-namespace.sh` on both spokes involved
