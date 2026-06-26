# Wandering Workload

A live demo that migrates a real, stateful application across five different
infrastructure platforms — VMware, on-premise OpenShift, ARO, ROSA, and OSD on
GCP — without downtime and without changing a single line inside the guest VMs.

The application is a topographic map where each "stop" plants a pin. As the
workload hops between clouds, the pins record which infrastructure route served
them, so the audience watches a trail grow across the terrain in real time.

The demo chain: **VMware → on-prem → ARO → ROSA → GCP → on-prem**

---

## How to approach this repo

This repo combines **Ansible playbooks** (build VMs, configure roles, deploy
the load balancer) and **shell scripts** (cluster prep, migration, DR
lifecycle). Neither replaces the other — they cover different phases:

| Phase | Tool | Where | When |
|-------|------|-------|------|
| **Build golden VM images** | Ansible | `ansible/golden-images/` | Once, on a Linux KVM/libvirt host |
| **Configure VMs** (assign frontend/backend role) | Ansible | `ansible/vm-configure/` | Once per clone, run locally inside the VM |
| **Deploy the load balancer** | Ansible | `ansible/loadbalancer/` | Once, on the machine running podman |
| **Prep OpenShift clusters** (RBAC, Portworx, MTV) | Shell scripts | `scripts/cluster-setup/` | Once per cluster |
| **Run the demo** (DR pairs, protection groups, failover) | Shell scripts | `scripts/dr/` | Each demo run |
| **Clean up** | Shell scripts | `scripts/cleanup/` | After a demo run |

**Start here:**

1. **Read the [Runbook](docs/RUNBOOK.md)** — it walks through the entire demo
   end-to-end with presenter notes and troubleshooting.
2. **Set up credentials** — copy `credentials.env.example` to
   `credentials.env` and fill in your cluster logins and S3 keys.
3. **Build a golden image** — run the Ansible playbook for Fedora (primary) or
   Alpine (experimental, smaller).
4. **Prep your clusters** — run the cluster-setup scripts in order.
5. **Run through the demo** — follow the Runbook.

If you are adapting the demo for your own environment, see
[Demo topology](#demo-topology-five-clusters) below for the map you need to
remap.

---

## The four demo components

| # | Component | Lives in | What it is |
|---|-----------|----------|------------|
| 1 | [Small Virtual Machine](#1-small-virtual-machine) | `ansible/golden-images/` | A shrunk golden image that MTV can migrate quickly |
| 2 | [Load Balancer App](#2-load-balancer-app) | `apps/loadbalancer/` | A visual reverse proxy that points one stable URL at whatever cluster is active |
| 3 | [Wandering Workload App](#3-wandering-workload-app) | `apps/wandering-workload/` | The two-tier Node.js + PostgreSQL map app that lives inside the VMs |
| 4 | [Live Demo Scripts](#4-live-demo-scripts-portworx-dr) | `scripts/` | Shell automation for the Portworx DR hop-by-hop failover chain |

---

### 1. Small Virtual Machine

**Purpose:** Give MTV the smallest possible disk to copy so migrations are fast
enough for a live audience.

**Where:** `ansible/golden-images/`

The golden image playbooks build a VM offline (no boot required) using
`virt-customize`, then shrink the disk geometry to the smallest possible size.
The image ships with the OS, `qemu-guest-agent`, Ansible, and the full
`wandering_workload` repo baked in.

**Two OS options:**

| OS | Playbook | Disk size | Status |
|----|----------|-----------|--------|
| Fedora 44 (BTRFS) | `fedora-small.yml` | ~1.7 GB | **Primary** — proven through the full demo chain |
| Alpine 3.21 (ext4) | `alpine/golden.yml` | ~640 MB | **Experimental** — golden builds and boots; role playbooks need Alpine rewrite |

Additional Fedora variants:

| Playbook | What it does |
|----------|-------------|
| `fedora.yml` | Full-size golden image (5 GB disk) |
| `fedora-min.yml` | Minimal variant (no repo copy) |
| `fedora-ext4.yml` | EXT4 variant (avoids BTRFS shrink complexity) |
| `fedora-small-virtbuilder.yml` | Builds at target size from scratch via `virt-builder` |

**How it contributes to the demo:** The shrunk disk means MTV copies ~1.7 GB
(Fedora) or ~640 MB (Alpine) instead of 5 GB per VM. With two VMs (frontend +
backend), that cuts the initial VMware-to-OpenShift migration from minutes to
under a minute on stage.

**Key detail (Fedora):** The Fedora Cloud root filesystem is BTRFS. Shrinking
requires a two-step dance — pre-shrink the BTRFS with `guestfish`, then
`virt-resize` into a smaller disk. The playbook documents the measured floor
(1600M BTRFS / 1740M disk) and why going smaller requires a flaky
`btrfs balance`.

**Key detail (Alpine):** Alpine uses musl/busybox/OpenRC instead of
glibc/systemd. The app itself is portable (pure JS, no native modules), but
the VM-configure playbooks (`frontend.yml`, `backend.yml`) use systemd units
and `nmcli` — an Alpine rewrite exists under `ansible/vm-configure/alpine/`
but is not yet proven through the full demo chain. See
`ansible/golden-images/alpine/README.md` for the Alpine-specific build guide
and an OpenRC cheat sheet.

The golden image is uploaded to the vSphere datastore, cloned into two VMs
(`wandering-front` and `wandering-db`), and each clone runs its Ansible
playbook locally to become either the Node.js frontend or the PostgreSQL
backend.

---

### 2. Load Balancer App

**Purpose:** Give the audience one stable URL that follows the workload
wherever it goes, and a visual dashboard to show the switch happening.

**Where:** `apps/loadbalancer/`

A containerized stack that runs **Nginx** (data plane) and a **Node.js
dashboard** (control plane) in a single container. Nginx reverse-proxies
traffic to whichever cluster is currently active, keeping the browser address
bar locked to a vanity domain. The dashboard shows every backend as a clickable
node with live health status.

**Architecture:**

```
Browser ─── https://wandering-workload.example.com ──→  Nginx (ports 80/443)
                                                            │
                                                            ↓
                                                    active_backend.conf
                                                            │
            ┌───────────────────────────────────────────────┤
            ↓                   ↓                   ↓       ↓
        Legacy VM         On-Prem OCP           ARO     ROSA / GCP
```

**Dashboard features:**
- Click a node to switch the live backend instantly (Nginx reload, not restart)
- SSE stream pushes every switch to all connected screens in real time
- Health checks ping each backend every 5 seconds; offline nodes glow amber
- REST API (`POST /api/activate`) so Ansible or scripts can trigger switches
- `/go` endpoint iframes the active backend (stable vanity URL in the address bar)

**How it contributes to the demo:** The presenter opens the dashboard on the
big screen. As each Portworx failover completes, the presenter (or a script)
clicks the next node on the dashboard. The audience sees the switchover happen
live — health goes green on the new cluster, the map app loads instantly from
the new backend, and all existing pins + data are preserved.

**Running it:**

```bash
podman build -t localhost/faux-lb:latest .
./hosts.sh add                              # map vanity domain to localhost
ansible-playbook ../../ansible/loadbalancer/deploy_podman.yml  # deploys via podman play kube
```

Edit `configmap.yaml` to add/remove backend nodes. The dashboard live-reloads
on save — no restart needed.

---

### 3. Wandering Workload App

**Purpose:** A visually compelling, stateful application whose data
must survive every migration hop and whose route history tells the
infrastructure story.

**Where:** `apps/wandering-workload/`

A two-tier app deployed natively on VMs (no containers):

- **Frontend VM** — Node.js (Express) serving a topographic map UI on port 80
- **Backend VM** — PostgreSQL storing the `stops` table (pins on the map)

**What the app does:**

1. The user types a node name and clicks the terrain to plant a pin
2. Each pin stores its `(x, y)` coordinates, a cycling color, and the
   **infrastructure route URL** that served the request (captured from the
   `Host` / `X-Forwarded-Host` header)
3. A dashed trail and animated VM marker trace the journey across all stops
4. A sidebar lists every stop with its route, so the audience can see pins
   were created on different clusters

**How it survives migration:**

The frontend resolves the backend by hostname (`wandering-backend-svc`). A
boot-time systemd service (`wandering-env-detect`) checks whether the VM is
running on VMware or KVM (OpenShift Virt):

| Platform | Detection | How the hostname resolves |
|----------|-----------|--------------------------|
| VMware | `systemd-detect-virt` → `vmware` | `/etc/hosts` entry → backend's static IP |
| OpenShift Virt | `systemd-detect-virt` → `kvm` | CoreDNS → K8s Service → backend pod IP |

The same `DB_HOST=wandering-backend-svc` works in both worlds. Migration order
doesn't matter, and there is nothing to rewire at cutover. Postgres data lives
on the VM disk, so it rides along with every migration.

**How it contributes to the demo:** The audience watches pins accumulate on the
map as the workload hops between clouds. Each pin's route label proves which
cluster served it. The data (pins, trails, colors) survives every hop because
PostgreSQL's data directory moves with the VM disk through MTV and Portworx DR.

---

### 4. Live Demo Scripts (Portworx DR)

**Purpose:** Automate the Portworx disaster recovery workflow so each hop in
the demo chain requires one command (plus a manual failover click in the UI).

**Where:** `scripts/`

```
scripts/
├── _lib.sh                                # shared credential loading + oc login helpers
├── cluster-setup/
│   ├── 01-install-portworx.sh             # install Portworx on a spoke cluster
│   ├── 02-configure-spoke-rbac.sh         # RBAC for spoke clusters
│   ├── 03-set-stork-admin-namespace.sh    # stork admin-namespace (REQUIRED before migration)
│   ├── 04-prep-migration-2tier.sh         # pre-seed project, services, routes, MTV plan
│   └── 05-prep-migration-aio.sh           # same for single-VM variant
├── migration/
│   ├── 01-switch-cluster.sh               # switch oc context to a named cluster
│   └── 02-refresh-mtv-inventory.sh        # force MTV to re-scan VMware inventory
├── dr/
│   ├── 02-create-dr-pairs.sh              # create all 4 DisasterRecoveryPair resources on the hub
│   └── 03-create-protection-group.sh      # create a ProtectionGroup for one hop (wait for readiness)
└── cleanup/
    ├── 01-teardown-mtv-workload.sh        # delete VMs/PVCs from a cluster
    ├── 02-delete-dr-pairs.sh              # remove DR pairs
    ├── 03-deep-clean-drp.sh               # deep clean all DR state
    └── 04-audit-orphans.sh                # check for leftover resources
```

**The demo runbook** (`docs/RUNBOOK.md`) walks through the full chain:

```
Pre-flight (once, before the audience)
  → set stork admin-namespace on all spokes
  → audit for clean slate

Phase 1 — MTV (VMware → on-prem)
  → prep-migration script creates project, services, routes, MTV plan
  → start the migration in the MTV UI

Phase 2 — Create DR pairs
  → one script creates all 4 bi-directional DisasterRecoveryPair resources

Phase 3 — Hop-by-hop failover
  → for each hop: create ProtectionGroup → wait for sync → MANUAL FAILOVER in Portworx UI
  → on-prem → ARO → ROSA → GCP → on-prem
```

**How it contributes to the demo:** Each hop is a single command
(`./scripts/dr/03-create-protection-group.sh <pair-name>`) that creates the
ProtectionGroup, waits for both spokes to be ready, and then tells the
presenter to trigger the failover in the Portworx UI. The gcp-on-prem hop
(the round trip) automatically pre-cleans the destination so volume names
don't collide.

**Credential management:** All cluster credentials live in `credentials.env`
(not committed). The `_lib.sh` helper loads them and provides `login_cluster`
/ `creds_for` functions so scripts never hardcode passwords.

---

## Demo topology (five clusters)

This repo assumes a specific five-cluster layout. Every script, DR pair name,
protection group name, and route hostname is wired to this topology. If you are
adapting the demo for your own environment, this is the map you need to remap.

```
                         ┌─────────┐
                         │   Hub   │  (ROSA — runs ACM + Portworx multicluster)
                         └────┬────┘
              ┌───────────────┼───────────────┐
              │               │               │
         ┌────┴────┐    ┌─────┴─────┐    ┌────┴────┐
         │   ARO   │    │   ROSA    │    │   GCP   │  (OSD on GCP)
         └────┬────┘    └─────┬─────┘    └────┬────┘
              │               │               │
              └───────────────┼───────────────┘
                         ┌────┴────┐
                         │ On-Prem │  (bare-metal / vSphere OpenShift)
                         └─────────┘
```

**Demo chain:** VMware → On-Prem → ARO → ROSA → GCP → On-Prem (round trip)

**DR pair ring** (see `docs/demo-scripts.md` for details):

| Pair name | Source | Destination |
|-----------|--------|-------------|
| `on-prem-aro` | on-prem | aro |
| `aro-rosa` | aro | rosa |
| `rosa-gcp` | rosa | gcp |
| `gcp-on-prem` | gcp | on-prem |

**What to change if you have different clusters:**

| What | Where | How |
|------|-------|-----|
| Cluster names / login URLs | `credentials.env` | Copy `credentials.env.example`, fill in your values |
| Spoke list (for scripts that loop) | `scripts/_lib.sh` | Edit the `SPOKES` array |
| DR pair names | `scripts/dr/02-create-dr-pairs.sh` | Edit pair definitions to match your cluster pairs |
| Protection group names | `scripts/dr/03-create-protection-group.sh` | Edit PG names to match your pair names |
| Route hostnames | `scripts/cluster-setup/04-prep-migration-2tier.sh` | Replace `<aro-cluster>`, `<rosa-cluster>`, etc. placeholders |
| Network IPs | `ansible/group_vars/all.yml` + per-role playbooks | See [Network defaults](docs/golden-image.md#network-defaults) |

---

## What this repo does NOT cover

- **Portworx installation and configuration** — the operator install, license
  activation, and storage cluster setup are documented in
  `docs/portworx-virt-install.md` as reference commands, but there are no
  automated playbooks for this. Portworx is assumed to be already running on
  every spoke cluster before the demo.

- **OpenShift cluster deployment** — the demo assumes five pre-existing
  clusters (ROSA hub, ARO spoke, ROSA spoke, OSD on GCP spoke, on-prem spoke)
  are already provisioned and reachable. Cluster creation is out of scope.

---

## What to do next

### Alpine role playbooks

The Alpine golden image builds and boots, but the VM-configure playbooks
(`frontend.yml`, `backend.yml`, `combined.yml`) under `ansible/vm-configure/alpine/`
need further testing through the full demo chain. They use OpenRC instead of
systemd and busybox ifupdown instead of `nmcli`.

### More automation around the demo scripts

The current workflow requires the presenter to run individual scripts and
manually trigger failovers in the Portworx UI between hops. Improvements:

- **Single "hop" command** that creates the ProtectionGroup, waits for sync
  to complete, triggers the failover via the Portworx API (instead of the UI),
  waits for VMs to start on the destination, and then calls the load balancer
  API to switch the active backend — all in one script.
- **Full chain runner** (`./demo.sh run`) that walks through all four hops
  sequentially, with configurable pauses for the presenter to talk.
- **Health gate** — after switching, poll the wandering workload `/health`
  endpoint on the new cluster's route and only proceed when the app reports
  `database: connected`.

### How to present the demo

A suggested flow for the four components:

1. **Open with the map** — show the Wandering Workload app on the big screen.
   Plant a pin or two to prove it's a real, stateful app with a database.
   Explain that it runs on plain VMs (no containers), exactly like a legacy
   workload.

2. **Show the golden image** — briefly explain that the VMs were built from a
   shrunk Fedora image (~1.7 GB disk) so migrations are fast. This is the
   "lift" — zero application changes.

3. **Run the first migration (MTV)** — switch to the on-prem OpenShift
   console and start the MTV plan. While it runs, explain that MTV copies the
   VM disks into KubeVirt VMs on OpenShift. The app self-heals on boot
   (env-detect, CoreDNS). Switch the load balancer dashboard to on-prem. Plant
   another pin — same data, new route.

4. **Hop across clouds (Portworx DR)** — run the DR scripts to create
   protection groups and trigger failovers. After each hop, switch the load
   balancer and plant a pin. The trail on the map grows, each pin tagged with a
   different cluster's route. Repeat for ARO → ROSA → GCP → back home.

5. **Close with the map** — zoom out. The trail shows every cluster the
   workload visited. The data is intact. The VMs are home. No application
   changes were needed at any point.

---

## Repository layout

```
apps/
├── wandering-workload/          # Two-tier Node.js + PostgreSQL map app (runs on VMs)
└── loadbalancer/                # Faux L7 load balancer + visual dashboard (runs in a container)

ansible/
├── golden-images/
│   ├── fedora-small.yml         # Primary golden image (~1.7 GB, Fedora, BTRFS)
│   ├── fedora.yml / fedora-ext4.yml / fedora-min.yml   # Alternate Fedora variants
│   └── alpine/                  # Experimental Alpine golden (~640 MB, ext4)
├── vm-configure/
│   ├── backend.yml / frontend.yml / combined.yml       # Fedora role playbooks
│   ├── *-undo.yml               # Teardown counterparts
│   └── alpine/                  # Alpine role playbooks (experimental)
├── loadbalancer/                # Deploy/teardown the LB container via podman
└── group_vars/all.yml           # Shared Ansible variables (IPs, service names)

scripts/
├── _lib.sh                      # Credential loading + cluster login helpers
├── cluster-setup/               # One-time OpenShift/Portworx cluster prep
├── migration/                   # MTV migration helpers
├── dr/                          # Portworx disaster recovery lifecycle
└── cleanup/                     # Teardown and audit scripts

docs/
├── RUNBOOK.md                   # Step-by-step demo execution guide (start here)
├── golden-image.md              # Detailed guide: golden VM image
├── loadbalancer.md              # Detailed guide: load balancer app
├── wandering-workload-app.md    # Detailed guide: map application
├── demo-scripts.md              # Detailed guide: all demo scripts
├── portworx-dr-sync.md          # How Portworx DR sync works (DRPs, PGs, S3)
├── portworx-virt-install.md     # Portworx / OpenShift Virt / MTV install reference
├── FILE-INVENTORY.md            # Every file in the repo and what it does
├── modernise.md                 # Modernising VMs to containers (the next chapter)
└── future-modernise.md          # Technical plan for container manifests
```

## Documentation

| Guide | What it covers |
|-------|---------------|
| [Runbook](docs/RUNBOOK.md) | **Start here.** Step-by-step demo execution with presenter notes and troubleshooting |
| [Golden Image](docs/golden-image.md) | Building the shrunk Fedora VM, the BTRFS dance, VM configuration playbooks, env-detect |
| [Load Balancer](docs/loadbalancer.md) | Nginx + dashboard architecture, configuration, API reference, deployment, triggering switches |
| [Wandering Workload App](docs/wandering-workload-app.md) | Map app architecture, route capture, database schema, survival mechanism, local development |
| [Demo Scripts](docs/demo-scripts.md) | Every script in `scripts/`, credential management, DR pairs, protection groups |
| [Portworx DR Sync](docs/portworx-dr-sync.md) | How Portworx is installed on OpenShift, how DR sync works via S3, DRPs and PGs |
| [Install Reference](docs/portworx-virt-install.md) | Copy-paste blocks for Portworx, OpenShift Virt, and MTV installation |
| [File Inventory](docs/FILE-INVENTORY.md) | Every file in the repo and how it relates to the demo |
| [Modernise](docs/modernise.md) | Narrative: modernising VMs to containers after the migration demo |

## Quick reference

| Task | Command |
|------|---------|
| Build golden image (Fedora) | `ansible-playbook ansible/golden-images/fedora-small.yml` |
| Build golden image (Alpine) | `cd ansible/golden-images/alpine && ansible-playbook golden.yml` |
| Configure backend VM | `sudo ansible-playbook ansible/vm-configure/backend.yml` |
| Configure frontend VM | `sudo ansible-playbook ansible/vm-configure/frontend.yml` |
| Start load balancer | `ansible-playbook ansible/loadbalancer/deploy_podman.yml` |
| Pre-seed MTV migration | `./scripts/cluster-setup/04-prep-migration-2tier.sh` |
| Create all DR pairs | `./scripts/dr/02-create-dr-pairs.sh` |
| Create protection group | `./scripts/dr/03-create-protection-group.sh <pair-name>` |
| Switch LB to next cluster | `./apps/loadbalancer/trigger.sh <position> http://<lb-host>:8080` |
| Full runbook | See [docs/RUNBOOK.md](docs/RUNBOOK.md) |
