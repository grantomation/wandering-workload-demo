# VM Build Pipeline

## Overview

VM images are built entirely inside OpenShift using Tekton pipelines. No local workstation tools are needed -- no libvirt, no QEMU, no virt-builder. The pipeline produces Alpine Linux VMs with the application baked in, ready for both OpenShift Virtualization (qcow2) and VMware vSphere (vmdk).

This replaces the original approach where Fedora golden images were built locally using Ansible playbooks, uploaded to VMware, cloned, and then configured with more Ansible. The current system builds purpose-specific VMs in a single pass inside a container.

## Why Alpine instead of Fedora

The original golden images used Fedora 44 Cloud Base (~1.7 GB after shrinking). Shrinking a Fedora BTRFS filesystem required a complex two-step dance: pre-shrink BTRFS to 1600M (the measured no-balance floor), then `virt-resize --shrink` into a 1740M disk. Going smaller required a flaky `btrfs balance` that could fail.

Alpine produces ~640 MB images. ext4 shrink is straightforward (`resize2fs -M`). The application is pure JavaScript with no native modules -- fully portable between glibc (Fedora) and musl (Alpine). Alpine uses OpenRC instead of systemd and busybox instead of GNU coreutils, but the build scripts handle these differences.

The smaller disk means MTV copies ~640 MB instead of ~1.7 GB per VM. With two VMs (frontend + backend), the initial VMware-to-OpenShift migration takes under a minute on stage instead of several minutes.

## The builder image

Pipeline 1 builds a container image called `golden-builder` from `01_installation_dashboard/pipelines/builder/Containerfile`. This image contains:

- Fedora 44 base (not UBI, because guestfs-tools are not available in free UBI repos -- Fedora avoids RHEL entitlement issues entirely)
- `guestfs-tools` (virt-builder, virt-customize, virt-resize, virt-sparsify, guestfish)
- `qemu-img` (disk format conversion)

All subsequent VM-building pipelines run inside this builder image because those tools are needed to create qcow2/vmdk disk images from scratch.

The image is built by the pipeline and pushed to the internal OpenShift registry. It uses `LIBGUESTFS_BACKEND=direct` (TCG mode, no `/dev/kvm`) because pipeline pods don't have access to /dev/kvm.

## Pipeline sequence

7 numbered pipelines, plus 3 dashboard-triggered:

### Pipeline 1: Build VM Builder Image

Clones the repo, builds the `golden-builder` container from `01_installation_dashboard/pipelines/builder/Containerfile`, pushes to the internal registry. This only needs to be re-run if the Containerfile changes.

### Pipeline 2: Build Backend VM

Runs inside the builder image. Builds an Alpine VM with PostgreSQL and Avahi. Produces `wandering_backend.qcow2` and `wandering_backend.vmdk` on the shared workspace PVC (in the `artifacts/` subfolder). Fails fast if the builder image from pipeline 1 does not exist.

### Pipeline 3: Build Frontend VM

Same process for the frontend. Builds an Alpine VM with Node.js, the wandering workload app, and Avahi. Produces `wandering_frontend.qcow2` and `wandering_frontend.vmdk`. Also fails fast if the builder image is missing.

### Pipeline 4: VM Smoke Tests

Packages the qcow2 images as containerDisk images, deploys test VMs on OpenShift Virtualization, runs:

- Service DNS resolution tests (can the frontend reach the backend via Kubernetes Service name?)
- App API tests end-to-end (POST stops, GET to verify)
- VMware-readiness tests on both VMs (Avahi broadcasting, hostname correct, services enabled, DB seeded)
- If the artifact server is already deployed, refreshes it with the newly built images

Cleans up test resources on success (via a `finally` block that only runs when all tasks succeed, so failed runs leave VMs in place for debugging).

**Why ARO is the best build cluster for this**: This pipeline requires OpenShift Virtualization to run test VMs. OpenShift Virt needs hardware virtualization support. On AWS, this means expensive `.metal` instances. On GCP, it means C3 bare-metal. On Azure (ARO), Dsv5/Dsv6 instances with 8+ cores support nested virtualization at a fraction of the cost. Since the build cluster only runs CI smoke tests (not production workloads), ARO is the most cost-effective choice.

### Pipeline 5: Deploy Artifact Server

Checks that pipelines 2+3 deposited VM images, creates a dedicated `wandering-artifacts` PVC for serving them, copies the 4 disk images (with SHA256 dedup so unchanged images are not re-copied), optionally fetches the vCenter CA cert, builds and deploys the artifact server container with OAuth proxy. See [Artifact Server](artifact-server.md).

### Pipeline 6: Build VDDK Image

Builds the VDDK (Virtual Disk Development Kit) container image from a VMware tarball stored on the artifacts PVC. The tarball must be manually uploaded to the artifact server first (it is proprietary, from Broadcom's support portal). The VDDK image is required by MTV for warm migrations (incremental sync with changed-block tracking). Cold migrations work without it but are slower. After building, the pipeline grants image pull access to all authenticated users so any namespace (including `openshift-mtv`) can reference it.

### Pipeline 7: Create OCP Providers

Creates MTV OpenShift Provider CRs for each cluster with the Virt role. This includes logging into each remote cluster, creating a service account with cluster-admin, generating a long-lived token, and creating the Provider secret and CR in the `openshift-mtv` namespace. The pipeline is idempotent -- it cleans up stale providers before creating new ones.

### Dashboard-triggered pipelines

These are triggered by buttons in the installation dashboard rather than by GitHub webhooks:

- **dash-build-deploy-lb**: Reads cluster data from the dashboard's Secret, discovers each cluster's apps domain, generates load balancer config, builds and deploys the faux load balancer container.
- **dash-onboard-acm-clusters**: Reads cluster data from the dashboard's Secret, identifies the ACM hub, and imports all other OpenShift clusters as ManagedClusters via auto-import.
- **dash-px-license-activate**: Reads the Portworx license key from dashboard config, logs into each cluster with the PX role, and activates the license by exec'ing `pxctl license activate` inside a Portworx pod.

## How a VM is built (build-vm.sh)

The `build-vm.sh` script in `01_installation_dashboard/pipelines/scripts/` handles the entire VM build for a given role. It takes the Alpine Cloud image and produces a finished, role-specific VM in a single run. The `VM_ROLE` environment variable (`frontend` or `backend`) controls which variant is built.

### Step 1: Download and verify

Downloads the Alpine Cloud image (currently Alpine 3.21.2, configurable via `ALPINE_REL`). Verifies the SHA-512 checksum against the official Alpine checksum file. Caches the download so repeated builds skip this step.

### Step 2: Expand into a working disk

The Alpine Cloud image ships with a tiny root partition (a few hundred MB). The script finds the root partition dynamically using `virt-filesystems`, creates a 3 GB working disk with `qemu-img create`, and expands the root into it with `virt-resize --expand`.

**Why 3 GB**: The cloud image's default root partition would overflow during `apk install` (package installs for PostgreSQL, Node.js, etc.). Since cloud-init's `growpart` never runs in an offline build, the script must pre-expand the disk. 3 GB provides enough room for all packages and app files. The disk is shrunk back down to minimum size after customization.

### Step 3: Common customization

Applies to both frontend and backend VMs:

- Enables the Alpine `community` repository (needed for packages like `avahi-tools`)
- Installs `qemu-guest-agent` (required for OpenShift Virtualization VM management), `avahi` + `avahi-tools` + `dbus` (mDNS service discovery), and `virt-what` (platform detection at boot)
- Enables all services via OpenRC (`qemu-guest-agent`, `dbus`, `avahi-daemon`)
- Sets the root password and enables SSH root login (demo environment, not production)
- Embeds the `platform_network.sh` script as an OpenRC boot service that runs *before* the `networking` service

### Step 4: Role-specific customization

**Backend VM**:

- Sets hostname to `wandering-backend-svc` (the Kubernetes Service name, so DNS works on both platforms)
- Installs PostgreSQL 17, initializes the data directory
- Configures `listen_addresses='*'` and `pg_hba.conf` with `scram-sha-256` for the `todo` user from all hosts
- Embeds `02_wandering_db_seed.sh` -- a boot-time script that creates the `todo` role, `todo` database, and `stops` table, then verifies TCP connectivity as the `todo` user
- Installs a self-disabling OpenRC service (`wandering-db-seed`) that runs the seed script once after PostgreSQL starts, then removes itself from the boot sequence with `rc-update del`

**Frontend VM**:

- Sets hostname to `wandering-frontend`
- Installs Node.js and npm, copies the app to `/opt/wandering-workload`, runs `npm install --omit=dev`
- Writes `/etc/wandering-workload.env` with `DB_HOST=wandering-backend-svc` and database credentials
- Creates an OpenRC service (`wandering-workload`) that uses `supervise-daemon` for automatic restarts. At startup, on VMware, the service resolves `wandering-backend-svc.local` via `avahi-resolve` and substitutes the resolved IP as `DB_HOST`
- Embeds `vmware_network.sh` as an OpenRC service that runs after networking but before the app (see Network Configuration below)

### Step 5: Seal and shrink

After role-specific customization:

1. **Disable cloud-init** -- prevents it from overwriting network config on first boot. All cloud-init services are explicitly removed from OpenRC runlevels.
2. **Clean caches** -- removes `/var/cache/apk/*` to reclaim space.
3. **Seal** (`virt-sysprep`) -- removes SSH host keys, machine-id, logs, and other instance-specific state so each VM boots as a fresh machine.
4. **Sparsify** (`virt-sparsify --in-place`) -- reclaims zero-filled blocks in the qcow2 image.
5. **Pre-shrink ext4** -- uses `guestfish` to run `e2fsck -f` then `resize2fs -M`, shrinking the filesystem to its minimum size.
6. **Calculate target disk size** -- reads the minimized block count and block size from `tune2fs -l`, computes minimum filesystem bytes, adds 20% headroom, and rounds up to the nearest MB.
7. **Shrink-copy** -- creates a new qcow2 at the calculated target size and uses `virt-resize --shrink` to copy the filesystem into it. This is the final qcow2.
8. **Final sparsify** on the target image.

### Step 6: Format conversion

Converts the final qcow2 to VMDK using `qemu-img convert`. The VMDK subformat is `streamOptimized`, which is suitable for VMware import and OVA packaging.

Each VM produces two files:
- `wandering_<role>.qcow2` -- for OpenShift Virtualization (containerDisk or DataVolume import)
- `wandering_<role>.vmdk` -- for VMware vSphere import

## Network configuration

### The problem

On VMware, VMs get IP addresses from DHCP. The demo runs on the Red Hat Demo Platform, which assigns IPs from its own DHCP pool. The frontend VM needs a predictable IP so that the platform's DNS can resolve the demo's vanity URL to it.

### The solution: DHCP-to-static switch

Two boot-time scripts handle platform detection and network configuration:

**platform_network.sh** (runs at boot via OpenRC, before the `networking` service):

- Detects the hypervisor using `virt-what`
- On KVM (OpenShift/KubeVirt): writes a DHCP config to `/etc/network/interfaces`. KubeVirt's masquerade networking provides addressing via 10.0.2.x, and DHCP is the correct mode.
- On VMware: makes no changes to the network config. DHCP is the default, and the `vmware-network` service handles the static switch later.
- On unknown platforms: makes no changes.

**vmware_network.sh** (frontend only, runs after networking but before the app):

- Uses `virt-what` to detect VMware. On non-VMware platforms, it is a no-op.
- Waits up to 60 seconds for a DHCP lease to arrive on `eth0`.
- Reads the assigned address and CIDR mask from the lease.
- Derives the target address by replacing the host octet with `.202` (e.g., if DHCP gives `10.0.0.50/24`, the frontend becomes `10.0.0.202/24`).
- Preserves the gateway and DNS from the DHCP lease.
- Writes a static config to `/etc/network/interfaces` and applies it directly using `ip addr`/`ip route` commands (not `rc-service networking restart`, which deadlocks when called from inside an OpenRC service that depends on networking).
- Runs connectivity tests: verifies the new address is applied, pings the gateway, checks internet reachability, and tests DNS resolution.

**Why .202**: The Red Hat Demo Platform's DNS is pre-configured to resolve the demo's frontend hostname to the `.202` address on the demo network's subnet. The script derives this from the DHCP lease rather than hardcoding a full IP, making it adaptable to different subnets.

### Service discovery

The old codebase used `/etc/hosts` entries (managed by a `wandering-env-detect` systemd service) to map `wandering-backend-svc` to a hardcoded IP. The current codebase uses Avahi/mDNS:

- **On VMware**: Both VMs run `avahi-daemon`. The backend publishes its hostname via mDNS. The frontend resolves `wandering-backend-svc.local` via `avahi-resolve` at startup (in the `start_pre()` hook of its OpenRC service), and substitutes the resolved IP as `DB_HOST`.
- **On OpenShift**: The pod network handles it -- `wandering-backend-svc` resolves via CoreDNS as a Kubernetes Service name. The `avahi-resolve` step is skipped because `virt-what` does not report `vmware`.

This eliminated the hardcoded backend IP and made the system work on any network.

## Workspace and triggers

All pipelines share a single 10 GiB PVC (`wandering-build-workspace`) with `subPath` isolation per pipeline. VM disk images are written to the `artifacts/` subfolder. The artifact server has its own dedicated PVC (`wandering-artifacts`) that receives copies of the finished images.

Three EventListeners with Routes handle automated triggering:

1. **wandering-build-listener** -- GitHub webhook. Fires on push to the repo and triggers the full numbered pipeline sequence via `wandering-build-template`.
2. **lb-build-listener** -- Dashboard's "Build Loadbalancer" button. Triggers `dash-build-deploy-lb` with hardcoded repo coordinates.
3. **acm-onboard-listener** -- Dashboard's "Onboard to ACM" button. Triggers `dash-onboard-acm-clusters`.

Each EventListener gets its own OpenShift Route with TLS edge termination, providing stable HTTPS webhook URLs.
