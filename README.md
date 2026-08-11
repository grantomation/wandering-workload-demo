# Wandering Workload

A live demo that migrates a real, stateful application across five infrastructure
platforms — VMware, on-prem OpenShift, ARO, ROSA, and OSD on GCP — without
downtime and without changing a single line inside the guest VMs.

The application is a topographic map where each "stop" plants a pin. As the
workload hops between clouds, each pin records which infrastructure route served
it, so the audience watches a trail grow across the terrain in real time.

**Demo chain:** VMware → on-prem → ARO → ROSA → GCP → on-prem (round trip)

> **Note:** This repo was recently refactored so the entire demo — VM image
> builds, operator installs, storage configuration, and service deployment — can
> be driven from a single OpenShift cluster through a web dashboard and Tekton
> pipelines. No local tooling (libvirt, Ansible, virt-builder) is required.
> The previous approach of building golden images on a workstation and
> configuring VMs with Ansible playbooks has been replaced; that code is
> preserved in `xx_archive/` for reference.

---

## Quick start

### Prerequisites

You need to bring your own infrastructure:

- **Five OpenShift clusters** — a ROSA hub (ACM + Portworx multicluster), and
  four spokes (on-prem OCP, ARO, ROSA, OSD on GCP). See
  `00_build_clusters/README.md` for the expected topology.
- **VMware vSphere** — a vCenter with at least one ESXi host and a datastore.
  This is the starting point for the VM migration.
- **Cloud IAM** — each cloud provider needs appropriate permissions for
  Portworx storage (IAM roles on AWS, service principal on Azure, service
  account on GCP).
- **S3-compatible bucket** — shared storage for Portworx async DR replication.

### Getting started

Everything is controlled from one OpenShift cluster through the
[Installation Dashboard](docs/installation-dashboard.md). The dashboard is a
web UI that bootstraps the entire environment: registers clusters, installs
operators, builds VM images via Tekton pipelines, and configures storage.

1. **Deploy the dashboard** on your chosen Build cluster:
   ```bash
   oc login <build-cluster-api>
   ./01_installation_dashboard/setup.sh
   ```

2. **Register your clusters** in the dashboard UI. Add each OpenShift cluster
   (API URL + credentials) and your VMware vSphere environment.

3. **Assign roles** to each cluster. The dashboard installs the right operators
   for each role:

   | Role | What it installs | Assign to |
   |------|-----------------|-----------|
   | Build | OpenShift Pipelines + Virtualization | Your build/CI cluster |
   | MTV | OpenShift Virtualization + Migration Toolkit | The on-prem spoke |
   | ACM | Advanced Cluster Management + PX Multi-Cluster | The hub (ROSA) |
   | Virt | OpenShift Virtualization | Every spoke that runs VMs |
   | Portworx | Portworx Enterprise | Every spoke |

   **Why ARO is a good candidate for the Build role:** The Build role needs
   OpenShift Virtualization to run VM smoke tests (pipeline 4 deploys test VMs
   to verify golden images work). OpenShift Virt requires hardware
   virtualization support. ARO's Dsv5/Dsv6 instances support nested
   virtualization at a fraction of the cost of the bare-metal instances
   required on AWS (`.metal` types) or GCP (C3 bare-metal). When the only
   virtualization need is CI smoke tests, ARO is the most cost-effective choice.

4. **Run the Tekton pipelines** to build VM images. The dashboard triggers a
   7-stage pipeline that builds Alpine VMs, smoke-tests them on OpenShift
   Virtualization, and deploys an artifact server with the disk images. See
   [VM Build Pipeline](docs/vm-build-pipeline.md).

5. **Run the demo** — follow the [Demo Runbook](docs/demo-runbook.md) for the
   complete walkthrough: MTV migration, DR pair creation, hop-by-hop failover,
   and cleanup.

---

## Documentation

| Guide | What it covers |
|-------|---------------|
| [Architecture](docs/architecture.md) | System overview, five-cluster topology, design philosophy, how components connect |
| [Installation Dashboard](docs/installation-dashboard.md) | Deploying the dashboard, registering clusters, roles, operators, Portworx per-platform config, Tekton pipelines |
| [VM Build Pipeline](docs/vm-build-pipeline.md) | Builder image, Alpine golden builds, network config (DHCP-to-static, Avahi/mDNS), pipeline stages |
| [Workload App](docs/workload-app.md) | Map app architecture, route capture, database schema, migration survival mechanism |
| [Artifact Server](docs/artifact-server.md) | Pipeline-built vs uploaded files, SELinux/PVC handling, VDDK upload |
| [Load Balancer](docs/load-balancer.md) | Visual reverse proxy, dashboard UI, SSE streaming, API reference, deployment |
| [Portworx DR](docs/portworx-dr.md) | Async DR concepts, S3 trust model, DR pair ring, stork admin-namespace, round-trip handling |
| [File Inventory](docs/FILE-INVENTORY.md) | Every file in the repo with a one-liner description |

---

## Repository layout

```
00_build_clusters/               # Cluster prerequisites (provision your own)
01_installation_dashboard/       # Web dashboard — the single pane of glass
├── app/                         #   Express server, config, lib modules, UI
├── deploy/                      #   Kubernetes manifests for the dashboard itself
├── operators/                   #   Per-operator YAML templates (ACM, Virt, MTV, Pipelines, Portworx)
├── pipelines/                   #   Tekton pipelines, builder image, VM build scripts
└── portworx/                    #   Per-platform StorageCluster specs (ARO, ROSA, GCP, OCP)
02_workload/                     # Two-tier Node.js + PostgreSQL map app (runs on VMs)
03_artifact_server/              # HTTP file server for VM disk images + VDDK uploads
04_loadbalancer_app/             # Visual reverse proxy + dashboard (runs in a container)
├── deploy/                      #   Ansible playbooks for podman deployment
└── test/                        #   Smoke test harness + dummy backends
05_demo/                         # Demo execution scripts
├── 01_pre_work/                 #   MTV prep (project, services, routes) + orphan audit
├── 02_MTV/                      #   Cluster switching, inventory refresh, workload teardown
└── 03_portworx/                 #   DR pairs, protection groups, cleanup
docs/                            # All documentation
```

---

## Quick reference

| Task | Command |
|------|---------|
| Deploy the dashboard | `./01_installation_dashboard/setup.sh` |
| Pre-seed MTV migration | `./05_demo/01_pre_work/prep-2tier.sh` |
| Create all DR pairs | `./05_demo/03_portworx/create-dr-pairs.sh` |
| Create protection group | `./05_demo/03_portworx/create-protection-group.sh <pair-name>` |
| Switch load balancer | `./04_loadbalancer_app/trigger.sh <position> http://<lb-host>:8080` |
| Audit for orphans | `./05_demo/01_pre_work/audit-orphans.sh` |
| Deep clean DR state | `./05_demo/03_portworx/deep-clean-drp.sh --all` |
| Teardown all workloads | `./05_demo/02_MTV/teardown-workload.sh all` |
| Full walkthrough | See [docs/demo-runbook.md](docs/demo-runbook.md) |
