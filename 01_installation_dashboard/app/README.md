# Installation Dashboard

Web dashboard for bootstrapping and managing the Workload Portability demo across multiple OpenShift clusters.

## Bootstrap

```bash
oc login <build-cluster-api> -u kubeadmin -p <password>
./setup.sh
```

`setup.sh` handles everything: namespace, RBAC, secrets, PVC, build, deployment, route.

## Installation Order

### Phase 1: Infrastructure

1. **Bootstrap the dashboard** — run `setup.sh` on the cluster that will host the build server (typically ARO)
2. **Add clusters** — open the dashboard, add all OpenShift clusters (ARO, ROSA, OSD/GCP, on-prem) and the VMware cluster via the sidebar
3. **Test connections** — click Test on each cluster in the Setup tab to verify connectivity and detect platform

### Phase 2: Build Server

4. **Assign the Build role** — Configure tab, select the build cluster, assign Build. This installs the Pipelines and Virtualization operators and generates all Tekton resources (tasks, pipelines, triggers, PVC)
5. **Run pipelines** — trigger the build pipelines to create VM builder images, golden VM images, and the artifact server

### Phase 3: Multi-Cluster Management

6. **Assign the ACM role** — select the hub cluster, assign ACM. Installs Advanced Cluster Management
7. **Onboard to ACM** — click "Onboard to ACM" in Global Configuration. Imports all registered spoke clusters into ACM as ManagedClusters
8. **Assign other roles** — assign MTV (Migration Toolkit for Virtualization) and Virtualization roles to spoke clusters as needed

### Phase 4: Portworx Storage

Portworx setup is multi-step because each cluster needs platform-specific configuration.

9. **Assign the Portworx role** — select each cluster that needs storage, assign Portworx. This installs the Portworx **operator only** (OLM Subscription to `portworx-certified`). Repeat for each cluster
10. **Configure cloud credentials** (per-cluster) — in the Configure tab, the Portworx Cloud Credentials section appears after assigning the role. Fill in the platform-specific credentials:
    - **ARO**: Azure Service Principal (Client ID, Client Secret, Tenant ID) — creates `px-azure` Secret
    - **ROSA**: IAM Role ARN for workload identity (IRSA) — injected into StorageCluster spec
    - **OSD/GCP**: GCP Service Account JSON key — creates `px-gcloud` Secret
    - **OCP on AWS**: uses IAM instance profile by default, optional static key override
11. **Apply StorageCluster** (per-cluster) — from the Operate tab, apply the platform-specific StorageCluster CR. This tells Portworx what cloud drives to provision and starts the storage cluster *(not yet automated — coming soon)*
12. **Configure S3 bucket** (global) — click "S3 Bucket" in Global Configuration. One bucket shared by all clusters for DR backups. The bucket must already exist in AWS
13. **Apply PX license key** (global) — click "PX License Key" in Global Configuration. One key, applied to all clusters with the Portworx role *(apply step not yet automated — coming soon)*

### Phase 5: Disaster Recovery (future)

14. **Create DR pairs** — establish trust between cluster pairs via shared S3 backup location
15. **Create Protection Groups** — define namespace replication policies across paired clusters
16. **Failover/failback** — trigger from the Operate tab

## Global vs Per-Cluster Configuration

| Setting | Scope | Where |
|---------|-------|-------|
| Cloud credentials | Per-cluster | Configure tab → Portworx Cloud Credentials |
| StorageCluster CR | Per-cluster | Operate tab → Apply StorageCluster |
| S3 bucket | Global (all PX clusters) | Configure tab → Global Configuration → S3 Bucket |
| PX license key | Global (all PX clusters) | Configure tab → Global Configuration → PX License Key |
| ACM onboarding | Global (all clusters) | Configure tab → Global Configuration → Onboard to ACM |

## Configuration

All role definitions, operator metadata, resource costs, and the dashboard namespace are defined in `config.yaml`. The app reads this file at startup.

To change configuration in production: edit the `installation-dashboard-config` ConfigMap, then restart the pod (`oc rollout restart deployment/installation-dashboard`). No container rebuild needed.

For local development, edit `config.yaml` directly and restart the server.

## Local Development

```bash
cd 01_installation_dashboard
npm install
DATA_DIR=./data node server.js
# http://localhost:8080
```

## Deploy Manifests

All in `deploy/`:

| File | Resource |
|------|----------|
| `00-namespace.yaml` | Namespace |
| `01-proxy-secret.yaml` | OAuth proxy session secret |
| `02-configmap.yaml` | App configuration (roles, operators, resource costs) |
| `rbac.yaml` | ServiceAccount, ClusterRole, ClusterRoleBinding |
| `pvc.yaml` | PersistentVolumeClaim for dashboard data |
| `buildconfig.yaml` | ImageStream + S2I BuildConfig |
| `service.yaml` | Service with serving-cert annotation |
| `route.yaml` | Route with TLS reencrypt |
| `deployment.yaml` | Deployment with OAuth proxy sidecar |
