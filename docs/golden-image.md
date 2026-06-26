# Golden Image: Small Virtual Machine

The golden image is the foundation of the demo. It produces a Fedora 44 VM disk
that ships with everything the Wandering Workload app needs pre-installed, and
shrinks the disk geometry so MTV can migrate it quickly on stage.

## Why this matters for the demo

MTV copies the VM's virtual disk over the network. A stock Fedora Cloud Base
image has a 5 GB virtual disk. With two VMs (frontend + backend), that is
10 GB of data MTV needs to walk. Shrinking each disk to ~1.7 GB cuts the
initial VMware-to-OpenShift migration to under a minute on a decent network,
which is the difference between a live audience watching progress and a live
audience checking their phones.

## How it works

The golden image is built **offline on a Linux KVM/libvirt build host** — the
image is never booted. The playbook:

1. Downloads the Fedora 44 Cloud Base qcow2
2. Customises the image with `virt-customize` (install packages, copy the repo,
   set passwords)
3. Seals it with `virt-sysprep` (strip machine-id, SSH keys, cloud-init state)
4. Sparsifies to reclaim unused blocks
5. Shrinks the disk geometry (btrfs pre-shrink + virt-resize)
6. Converts to VMDK for vSphere upload

### The BTRFS shrink dance

Fedora Cloud Base uses BTRFS as its root filesystem. `virt-resize` can shrink
partitions but not the BTRFS inside them, so the playbook uses a two-step
approach:

1. **Pre-shrink the BTRFS** using `guestfish btrfs-filesystem-resize` to 1600M
2. **Shrink the partition** into a smaller disk with `virt-resize`, which
   re-expands the BTRFS to fill the new (smaller) partition

The measured floor is **1600M for BTRFS / 1740M for the disk**. Going smaller
requires a `btrfs balance` which is unreliable in the libguestfs appliance
(flips the filesystem read-only). The playbook documents these limits and the
measurement date.

## What gets baked in

| Item | Purpose |
|------|---------|
| `qemu-guest-agent` | Lets OpenShift Virt communicate with the guest (IP reporting, graceful shutdown) |
| `ansible-core` | The VM configures itself by running Ansible playbooks locally |
| `acl` | Required by some Ansible modules |
| `wandering_workload` repo | The entire repo is copied to `/home/fedora/wandering_workload` |
| `fedora` user (sudo) | Non-root user with passwordless sudo |
| Root password (`openshift`) | Console access during demos |

## Playbook variants

| Playbook | Disk | Filesystem | Notes |
|----------|------|------------|-------|
| `fedora-small.yml` | ~1.7 GB | BTRFS | **Primary.** Smallest proven disk with the BTRFS shrink dance |
| `fedora.yml` | 5 GB | BTRFS | Full-size golden. No shrink step |
| `fedora-ext4.yml` | varies | EXT4 | Converts BTRFS to EXT4 (avoids shrink complexity) |
| `fedora-min.yml` | ~1 GB | EXT4 | Kickstart-based minimal. Different guest, needs MTV re-test |
| `fedora-small-virtbuilder.yml` | ~1.7 GB | varies | Builds at target size from scratch via `virt-builder`. Different partition layout, needs MTV re-test |

**Use `fedora-small.yml`** unless you have a reason not to. It is the only
variant that has been fully tested through the MTV skip-guest-conversion
pipeline.

### Alpine experiment (`alpine/`)

An experimental Alpine 3.21 path exists in `ansible/golden-images/alpine/`. It
produces a ~640M disk (Alpine uses ~194 MB) but runs OpenRC instead of systemd,
so the `wandering-env-detect` service and the existing Ansible playbooks need
porting. See `alpine/README.md` for details.

## Building the golden image

```bash
cd wandering-workload/ansible/golden-images
ansible-playbook fedora-small.yml
```

Override shrink targets if probing shows a lower floor:
```bash
ansible-playbook fedora-small.yml -e btrfs_size=1500M -e target_size=1700M
```

### Outputs

| File | Format | Purpose |
|------|--------|---------|
| `wandering_small.qcow2` | qcow2 | Shrunk golden image |
| `wandering_small.vmdk` | VMDK (monolithicSparse) | Upload to vSphere datastore browser |

## After building: VMware setup

1. Upload the VMDK to the vSphere datastore via the datastore browser
2. Create a VM from the uploaded disk
3. Clone the VM twice: `wandering-front` and `wandering-db`
4. Boot each clone and run the appropriate Ansible playbook locally:

```bash
# On the backend clone:
cd wandering_workload/ansible/vm-configure
sudo ansible-playbook backend.yml

# On the frontend clone:
cd wandering_workload/ansible/vm-configure
sudo ansible-playbook frontend.yml
```

## VM configuration playbooks

These live in `ansible/vm-configure/` and run **locally on each VM**
(`connection: local`). No control node or SSH wiring needed.

| Playbook | What it configures |
|----------|--------------------|
| `backend.yml` | Pins static IP (default `198.51.100.41` — see [Network defaults](#network-defaults)), installs `wandering-env-detect`, initialises PostgreSQL, creates the `todo` role/db and `stops` table, allows remote connections, disables firewalld |
| `frontend.yml` | Pins static IP (default `198.51.100.202` — see [Network defaults](#network-defaults)), installs `wandering-env-detect`, installs Node.js, deploys the app to `/opt/wandering-workload`, creates the `wandering-workload` systemd service |
| `combined.yml` | Both tiers on one VM with `DB_HOST=127.0.0.1` (single-VM fallback) |
| `backend-undo.yml` | Tears down PostgreSQL (**wipes all data**) |
| `frontend-undo.yml` | Tears down the app, service, env-detect |
| `combined-undo.yml` | Both teardowns on one VM |

### The env-detect service

`wandering-env-detect.service` is a boot-time oneshot that runs
`systemd-detect-virt` and configures hostname resolution accordingly:

- **VMware** (`vmware`): writes `/etc/hosts` entries mapping
  `wandering-backend-svc` to the backend's static IP
- **OpenShift Virt** (`kvm`): removes those `/etc/hosts` entries so CoreDNS
  resolves the Kubernetes Service instead

This is the mechanism that lets the same `DB_HOST=wandering-backend-svc` work
on both platforms without any application changes.

## Key variables

Defined in `ansible/group_vars/all.yml`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `backend_svc_name` | `wandering-backend-svc` | Hostname the frontend uses to find PostgreSQL |
| `backend_ip` | `198.51.100.41` | The backend's static IP on the VMware network (RFC 5737 — change for your network) |

### Network defaults

The playbooks ship with **RFC 5737 TEST-NET-2** addresses (`198.51.100.0/24`).
These are IANA-reserved documentation/example IPs that will never route on a
real network — they exist solely to signal "replace me with your actual values."

| Role | Default IP | Variable(s) to override |
|------|-----------|------------------------|
| Backend | `198.51.100.41` | `backend_ip` in `group_vars/all.yml` (or `-e backend_ip=...`) |
| Frontend / Combined | `198.51.100.202` | `net_static_ip` in the per-role playbook |
| Gateway / DNS | `198.51.100.1` | `net_gateway`, `net_dns` in the per-role playbook |

Override at runtime: `sudo ansible-playbook backend.yml -e backend_ip=10.0.1.41`
or edit `group_vars/all.yml` and the per-role `vars:` blocks for your network.
