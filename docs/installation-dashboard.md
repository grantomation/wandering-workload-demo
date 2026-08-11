# Installation Dashboard

## Overview

The installation dashboard is a web-based orchestration tool deployed on an OpenShift cluster. It is the single pane of glass for bootstrapping the entire Wandering Workload demo environment. From this dashboard, an operator can register clusters, install operators, deploy Tekton CI/CD pipelines, configure Portworx storage, build VM images, deploy the load balancer, onboard clusters to ACM, and activate Portworx licenses -- all without leaving the browser.

The dashboard runs as a two-container pod: the Node.js app (port 8080) behind an OpenShift OAuth proxy sidecar (port 8443). Authentication is handled by OpenShift SSO -- users log in with their OpenShift credentials (typically kubeadmin). TLS is auto-generated via the `service.beta.openshift.io/serving-cert-secret-name` annotation on the Service resource, which tells OpenShift's service-CA controller to create a `installation-dashboard-tls` Secret containing a signed certificate and key. The OAuth proxy mounts this Secret to terminate TLS on port 8443.

## Deploying the dashboard

### Prerequisites

- An OpenShift cluster with cluster-admin access
- The `oc` CLI authenticated to the target cluster

### setup.sh flow

The `01_installation_dashboard/setup.sh` script handles the full deployment:

1. **Creates namespace** (`workload-portability-build` by default, overridable via `NAMESPACE` env var). Uses `oc new-project` if the namespace does not exist.
2. **Applies RBAC** -- creates the `installation-dashboard` ServiceAccount plus Role and RoleBinding from `deploy/rbac.yaml`. The ServiceAccount is referenced by both the Deployment and the OAuth proxy.
3. **Creates the OAuth cookie secret** (`installation-dashboard-proxy`) with a random 32-byte base64 session key. The OAuth proxy reads this at startup to sign session cookies. Skipped if the secret already exists, so rerunning the script is safe.
4. **Creates the empty clusters Secret** (`installation-dashboard-clusters`) with an initial value of `{}`. This Secret is the persistent store for all registered cluster data. Skipped if it already exists so that existing cluster registrations are preserved across redeployments.
5. **Applies the PVC** (`installation-dashboard-data`) -- provides `/data` storage for the dashboard pod, used to cache generated YAML files per cluster/operator.
6. **Applies BuildConfig + ImageStream** -- the BuildConfig uses S2I (Source-to-Image) to build the dashboard container from the `app/` directory. The ImageStream (`installation-dashboard`) receives the built image.
8. **Applies Service, Route, and Deployment** -- the Service exposes port 8443 (the OAuth proxy) and carries the serving-cert annotation for automatic TLS. The Route provides external access. The Deployment uses an image trigger annotation so that new builds automatically roll out.
9. **Triggers the S2I build** (`oc start-build --follow`) and waits for the Deployment rollout.
10. **Prints the dashboard URL** by reading the Route hostname.

Every `oc create secret` call is guarded by an existence check, making the entire script idempotent.

## Registering clusters

### OpenShift clusters

OpenShift clusters are registered via the UI with a name, API URL, username, and password. On registration, the dashboard immediately tests connectivity by:

1. Querying the ClusterVersion API to get the OpenShift version.
2. Listing all nodes to capture instance types and allocatable resources.
3. Reading the Infrastructure CR to detect the cloud platform (AWS, Azure, GCP, vSphere, etc.).
4. Checking the Authentication CR to detect STS/IRSA (for distinguishing classic AWS from ROSA STS).
5. Reading the Ingress CR to derive the console URL.

If the connection test succeeds, the cluster is stored with `connectionStatus: connected`. If it fails, the cluster is still saved (so you do not lose the registration) but marked `connectionStatus: error`.

### VMware vSphere

VMware vSphere is registered separately with a name, vCenter URL, workload URL, username, and password. Only one VMware cluster is allowed -- it is always assigned `lbPosition: 0`, which puts it first in the load balancer chain. This restriction exists because the demo has a single VMware environment; the position-0 convention ensures the load balancer always routes to VMware before any cloud clusters.

### Credential storage

Cluster credentials are stored in a Kubernetes Secret (`installation-dashboard-clusters`), not a database. This was a deliberate choice: Secrets are the native Kubernetes mechanism for sensitive data, they participate in RBAC, they can be backed up with cluster etcd snapshots, and they eliminate the need for a database dependency. The entire dashboard has zero external dependencies beyond the OpenShift API.

When running locally for development, the dashboard falls back to a `data/clusters.json` file on the local filesystem.

### Authentication to remote clusters

The dashboard authenticates to remote OpenShift clusters via the OpenShift OAuth challenging-client flow:

1. Discovers the OAuth authorization endpoint via `/.well-known/oauth-authorization-server`.
2. Sends a GET to the authorization endpoint with `client_id=openshift-challenging-client`, a Basic auth header (username:password), and the `X-CSRF-Token: 1` header.
3. OpenShift responds with a 302 redirect whose Location header fragment contains `access_token=<bearer-token>&expires_in=<seconds>`.
4. The token is cached with expiry tracking (30 seconds before actual expiry) and reused for subsequent API calls.
5. If a request returns 401, the token cache is cleared and a fresh token is obtained automatically.

This flow avoids storing bearer tokens persistently -- they are derived on demand from the stored username/password.

## Cluster roles

Each cluster gets assigned one or more roles that determine which operators get installed. Roles are the abstraction that maps business intent ("this cluster runs VMs") to the concrete operator set required.

| Role | Operators installed | Purpose |
|------|-------------------|---------|
| Build | OpenShift Pipelines, OpenShift Virtualization | CI/CD platform for building VM images and running smoke tests |
| MTV | OpenShift Virtualization, MTV (Forklift) | VMware-to-OpenShift VM migration target |
| ACM | ACM, Portworx Multi-Cluster | Multi-cluster management hub and DR control plane |
| Virtualization | OpenShift Virtualization | Cluster that runs VMs (migration destination) |
| Portworx | Portworx Enterprise | Storage layer for CSI volumes, replication, and DR |

When operators overlap between roles (e.g., OpenShift Virtualization is needed by Build, MTV, and Virtualization), they are installed once and tracked. Unassigning a role only uninstalls operators that are not required by any remaining role.

Before assigning a role, the dashboard estimates the CPU and memory cost of the new operators and compares it against the cluster's available capacity (total allocatable resources on worker nodes minus resources already committed to assigned roles). If the cluster cannot fit the operators, the assignment is rejected with a capacity error.

**Why ARO is a good candidate for the Build role**: The Build role requires OpenShift Virtualization for running VM smoke tests (pipeline 4 deploys test VMs to verify the golden images work). OpenShift Virt requires nested virtualization or bare-metal nodes. ARO supports virtualization on Dsv5/Dsv6 instances with 8+ cores -- these are significantly cheaper than the bare-metal instances required on AWS (`.metal` types) or GCP (C3 bare-metal). This makes ARO the most cost-effective choice for the Build cluster when the only virtualization need is running CI smoke tests, not production VM workloads.

**Platform-aware prerequisite checks**: Before installing operators, the dashboard validates that the cluster can actually run them:

- **Virt on AWS**: requires `.metal` instance types; ROSA HCP (hosted control plane, detected via `External` control plane topology) is rejected because it does not support running VMs.
- **Virt on Azure (ARO)**: requires Dsv5/Dsv6 instances with 8+ cores. The regex `/standard_(d|e)\d+a?s?_v[56]/` matches compatible VM sizes, and a secondary check rejects instances with fewer than 8 cores.
- **Virt on GCP**: requires C3 bare-metal instances (machine types containing `-metal`).
- **Virt on vSphere**: warns that nested virtualization must be enabled on ESXi hosts and is not officially supported for production.
- **Portworx on ARO**: checks for an Azure service principal in the `azure-credentials` secret in `kube-system`; rejects managed identity because ARO does not expose MI credentials to worker nodes, which Portworx needs to provision Azure Managed Disks.
- **ACM**: warns if total worker memory is below 48 GiB, but does not block installation.

## Operators

### OpenShift Pipelines

Provides Tekton CI/CD. Every build and deploy action in the demo runs as a Tekton PipelineRun -- VM image builds, artifact server deployment, load balancer build, ACM cluster onboarding, Portworx license activation. The dashboard installs it via OLM in the `openshift-operators` namespace (a shared namespace, so it is never deleted on uninstall). After the Subscription is applied, the dashboard waits up to 120 seconds for the TektonConfig CRD to become available before proceeding.

### OpenShift Virtualization

Lets OpenShift run VMs via KubeVirt. Needed by three roles: Build (smoke-testing VM images in pipeline 4), MTV (target hypervisor for migration), and Virtualization (running production VMs). The dashboard installs the HyperConverged CR with:

- `enableCommonBootImageImport: true` -- pre-pulls common OS boot images so VMs start faster.
- `higherWorkloadDensity.memoryOvercommitPercentage: 100` -- allows memory overcommit to maximize VM density on demo clusters where resource efficiency matters more than isolation guarantees.
- `uninstallStrategy: BlockUninstallIfWorkloadsExist` -- prevents accidental removal while VMs are running.
- Live migration configured with `parallelMigrationsPerCluster: 5` and `completionTimeoutPerGiB: 150`.

### MTV (Migration Toolkit for Virtualization)

Migrates VMs from VMware vSphere to OpenShift Virtualization by copying VM disks. The dashboard auto-creates the VMware Provider CR (including VDDK init image reference from the build namespace ImageStream) and target namespace RBAC. Requires OpenShift Virt to be installed first -- the dashboard checks for the HyperConverged CR and warns if the VDDK ImageStreamTag does not exist yet (the VDDK image is built by pipeline 6).

### ACM (Advanced Cluster Management)

Multi-cluster management hub. Imports all spoke clusters as ManagedClusters via the `dash-onboard-acm-clusters` pipeline. Hosts the Portworx Multi-Cluster DR control plane -- DisasterRecoveryPairs and ProtectionGroups are created here via the dashboard's DR API. Also sets up MultiClusterObservability with S3 for metrics. The observability YAML files (`05-mco-namespace.yaml`, `06-mco-secret.yaml`, `07-mco.yaml`) contain `{{config.s3.bucket}}` and related template placeholders -- if S3 credentials are not configured yet in the dashboard, these placeholders remain unresolved and the files are silently skipped during installation. This means ACM installs cleanly without observability, and observability can be added later by saving S3 configuration and re-applying the ACM role.

### Portworx Enterprise

Enterprise storage layer providing CSI volumes, replication, and disaster recovery. Each cluster gets the operator via OLM in the `portworx` namespace, then a StorageCluster CR is applied with platform-specific configuration (see the next section). The dashboard also enables the `portworx` console plugin in the OpenShift web console so operators can manage storage from the standard UI. Stork (the Portworx storage orchestrator) is given `cluster-admin` privileges to enable volume snapshots and migration scheduling across namespaces.

### Portworx Multi-Cluster

Runs on the ACM hub only. Manages cross-cluster DR pairs and protection groups. Requires ACM because it uses the hub's ManagedCluster topology to coordinate replication between spoke clusters. Installed as part of the ACM role (not the Portworx role) because it lives on the hub, not on storage nodes. The dashboard enables the `px-multi-cluster-plugin` console plugin for this operator.

## Portworx per-platform configuration

Each cloud platform requires different StorageCluster configuration because cloud storage APIs, credential mechanisms, and performance characteristics differ. The dashboard auto-detects the platform from the Infrastructure CR and selects the matching spec.

| Platform | Cloud drives | Credentials | Start port | Notes |
|----------|-------------|-------------|------------|-------|
| ARO (Azure) | Azure Premium_LRS, 150 GiB | `px-azure` Secret (SP client ID, client secret, tenant ID injected as env vars) | 9001 (default) | Azure Managed Disks. ARO requires an Azure Service Principal because Managed Identity is not exposed to worker nodes -- Portworx needs to call the Azure API from worker pods to provision and attach disks, which MI cannot do on ARO. |
| GCP (OSD) | pd-ssd 150 GiB data + pd-ssd 64 GiB KVDB | `px-gcloud` Secret (GCP service account JSON key, volume-mounted to `/etc/pwx/gce/gcloud.json`) | 17001 | Separate KVDB disk because GCP PD performance scales with size -- isolating KVDB from data prevents I/O contention that would degrade metadata operations. The JSON key is mounted as a volume rather than injected as an env var because the GCP client library reads from a file path set in `GOOGLE_APPLICATION_CREDENTIALS`. |
| OCP on AWS | gp3 150 GiB data + gp3 64 GiB metadata | IAM instance profile (no secret needed) | 17001 | Self-managed OCP uses the worker node's IAM instance profile for EBS API calls. `certManager` is disabled (`false`) because cert-manager may not be installed on self-managed clusters. |
| ROSA (AWS STS) | gp3 150 GiB data + gp3 64 GiB metadata | Workload identity (IRSA): IAM Role ARN in `spec.workloadIdentity` | 17001 | STS/IRSA for credential injection instead of static keys. The dashboard injects the user-provided IAM Role ARN at deploy time via the `workloadIdentity.credentials` array with `cloudProvider: aws` and `key: eks.amazonaws.com/role-arn`. |

**Start port divergence**: ARO uses the default port 9001 because it was the first platform configured and had no conflicts. The other platforms use 17001 to avoid port conflicts with the NodePort range (30000-32767) and any cloud-provider services that may bind low-numbered ports. The port must be consistent across the Portworx cluster but does not need to match across different OpenShift clusters.

**Infra node exclusion**: The dashboard injects a `placement` section at deploy time that excludes infra-tainted nodes (`node-role.kubernetes.io/infra:NoSchedule`) via node affinity. This ensures Portworx only runs on worker nodes, not on infrastructure nodes that are typically reserved for routers and monitoring. The exclusion is configured in `config.yaml` under `portworx.excludeTaints` and applied by `storagecluster.js:injectPlacement()`.

**STS detection**: The code distinguishes classic AWS from AWS STS by checking the `serviceAccountIssuer` in the Authentication config (`/apis/config.openshift.io/v1/authentications/cluster`). A non-default URL (anything other than empty or `https://kubernetes.default.svc`) means STS/IRSA is enabled, which routes to the ROSA spec with workload identity credentials. This detection happens at cluster test time and is stored as `stsEnabled` in the cluster data.

## Tekton pipelines

Full details on the VM build process are in [VM Build Pipeline](vm-build-pipeline.md). This section covers the pipeline system as the dashboard manages it.

### Numbered pipelines (1-7)

These run in sequence on the Build cluster. Each builds on the output of the previous:

1. **Build the golden-builder container image** -- builds a Fedora 44 container with guestfs-tools and qemu-img. This image is the build environment for all subsequent VM image creation.
2. **Build backend VM** -- uses the golden-builder to create an Alpine Linux VM with PostgreSQL and Avahi (mDNS) baked in. Outputs qcow2/vmdk disk images.
3. **Build frontend VM** -- same process, but builds an Alpine Linux VM with Node.js, the application frontend, and Avahi.
4. **VM smoke tests** -- packages the VM disk images as containerDisk images, deploys them as VMs on OpenShift Virtualization, tests Service DNS resolution and the application API endpoint, then cleans up. This is why the Build role requires OpenShift Virt.
5. **Deploy artifact server** -- creates a PVC, copies VM images from the build workspace, and deploys an httpd server with oauth-proxy and an HTTPS Route. The artifact server makes VM disk images downloadable for MTV migrations and manual deployments.
6. **Build VDDK image** -- builds the VMware Virtual Disk Development Kit (VDDK) container image from a user-uploaded VMware tarball. MTV requires this image to efficiently copy VM disks from vSphere.
7. **Create MTV OpenShift providers** -- creates MTV Provider CRs for each cluster with the Virtualization role, enabling MTV to target them as migration destinations.

### Dashboard-triggered pipelines (dash- prefix)

These are triggered from the dashboard UI rather than running as part of the numbered sequence:

- **dash-build-deploy-lb**: Generates load balancer configuration from the dashboard's cluster data, builds the load balancer container, and deploys it to the build cluster.
- **dash-onboard-acm-clusters**: Reads cluster data from the `installation-dashboard-clusters` Secret, identifies the ACM hub cluster, and imports all other OpenShift clusters as ManagedClusters.
- **dash-px-license-activate**: Activates Portworx licenses via `pxctl` on all Portworx-role clusters.

### Shared workspace

All pipelines share a single 10 GiB PVC (`wandering-build-workspace`). This PVC is the pipeline's working directory -- it holds cloned source, built artifacts, and intermediate files. Using a single PVC instead of per-pipeline storage means artifacts from pipeline 1 (the builder image reference) are available to pipelines 2 and 3, and VM images from pipelines 2-3 are available to pipelines 4-5. The tradeoff is that pipelines cannot run in parallel (RWO access mode), but the sequential dependency chain makes parallelism impossible anyway.

### GitHub webhook trigger

The `wandering-build-listener` EventListener with a TLS-terminated Route accepts push events from GitHub. When a push occurs, it creates a PipelineRun that executes the full numbered pipeline sequence. The TriggerBinding extracts `repository.clone_url` and `after` (the commit SHA) from the webhook payload, and the TriggerTemplate wires them into the PipelineRun parameters.

Separate EventListeners exist for the load balancer build (`lb-build-listener`) and ACM onboarding (`acm-onboard-listener`), each with their own Routes. The dashboard triggers these by POSTing to their Route URLs.

## How operators are installed

The dashboard installs operators using a pipeline of steps designed for reliability and observability:

1. **Template resolution**: YAML files in `operators/<operator>/` contain `{{config.x.y}}` template placeholders. At install time, `templates.js` resolves these against the merged config (static `config.yaml` + dashboard runtime state). Files with any unresolved placeholders are silently skipped -- this provides graceful degradation when optional configuration (like S3 credentials for ACM observability) is not yet available.

2. **YAML generation**: Resolved manifests are written to the PVC at `/data/yaml/<cluster>/<operator>/` so operators can inspect and edit them from the dashboard UI before installation.

3. **Channel auto-resolution**: For Subscription resources, the dashboard queries `packagemanifests` on the target cluster to find the latest available channel rather than hardcoding a channel name. This means the dashboard always installs the newest version available in the cluster's operator catalog, avoiding version drift.

4. **Server-side apply**: Resources are applied using Kubernetes server-side apply (`PATCH` with `Content-Type: application/apply-patch+yaml` and `fieldManager=installation-dashboard`). Server-side apply was chosen over client-side apply because it handles field ownership correctly -- the dashboard only manages the fields it sets, and other controllers (like OLM) can manage their own fields without conflict. The `force=true` parameter resolves any field ownership conflicts in favor of the dashboard.

5. **CRD readiness wait**: After applying a Subscription, the dashboard waits up to 120 seconds for the operator's CRDs to become available before applying CRs like HyperConverged or ForkliftController. It polls every 5 seconds and also monitors the CSV status, aborting early if the CSV enters a `Failed` phase.

6. **Console plugin enablement**: If the operator has a `consolePlugin` configured (e.g., `portworx`, `px-multi-cluster-plugin`), the dashboard patches the OpenShift Console CR to enable the plugin, making the operator's UI available in the OpenShift web console.

7. **Progress reporting**: Every step emits SSE events so the UI can show real-time progress. The dashboard does not block the HTTP response on long operations -- it returns immediately and runs the installation in the background, streaming progress via Server-Sent Events.

## How operators are uninstalled

Uninstallation follows a specific order to avoid stuck resources. Each step exists because skipping it would leave the cluster in an inconsistent state:

1. **Delete the CR** (e.g., HyperConverged, ForkliftController) and wait up to 120 seconds. The operator needs this time to clean up workloads it manages (VMs, pipelines, etc.). Deleting the operator first would orphan these workloads.

2. **Delete the Subscription** -- stops OLM from reinstalling the operator.

3. **Delete the CSV** (ClusterServiceVersion) -- removes the operator deployment, RBAC, and API services that OLM created.

4. **Delete orphaned webhooks** -- validating and mutating webhook configurations that match the operator's webhook prefixes. Orphaned webhooks would block CRD deletion because the API server tries to call the webhook (which no longer exists) when processing CRD delete requests.

5. **Delete CRDs** -- strips finalizers first to prevent stuck deletions, then deletes. CRDs are matched by their API group against the operator's `crdGroups` list.

6. **Delete the namespace** -- but only if it is the operator's own namespace. Shared namespaces (`openshift-operators`, `openshift-marketplace`) are never deleted because other operators live there.

## App architecture

- **Server**: Express.js on Node.js, 2 runtime dependencies (`express`, `js-yaml`). No ORM, no database driver, no Kubernetes client library.
- **Config**: Single `config.yaml` loaded once at startup via `lib/config.js`. Contains role definitions, operator metadata (namespaces, CSV prefixes, CRD groups, resource estimates, webhook prefixes, console plugins), pipeline settings, Portworx platform detection rules, and platform-specific StorageCluster configuration references. All platform-specific behavior is driven by config, not hardcoded in application code.
- **State**: Stored in Kubernetes Secrets, not a database. `installation-dashboard-clusters` holds all cluster data (credentials, roles, scan results, node info). `installation-dashboard-config` holds dashboard settings (S3 config, Portworx credentials per cluster, license keys). When running locally, these fall back to JSON files in the `data/` directory.
- **Real-time updates**: SSE (Server-Sent Events) for progress on long-running operations (operator installs, scans, StorageCluster deployments, DR pair creation). Every connected browser tab receives the same event stream. SSE was chosen over WebSockets because it is simpler (unidirectional, auto-reconnect built into the browser EventSource API) and sufficient for a progress-reporting use case where the server pushes and the client listens.
- **K8s API access**: Direct HTTPS calls with a hand-rolled `k8sFetch()` function -- no kubectl, no SDK. The function handles redirect following (up to 5 hops), TLS with configurable CA certificates, timeout (15 seconds), and response parsing. Token caching with expiry tracking avoids re-authenticating on every request. Automatic retry on 401 (clear cache, re-authenticate, retry once) handles token expiry during long operations. The decision to avoid the official Kubernetes client library keeps the dependency footprint minimal and gives full control over the authentication flow (the OAuth challenging-client redirect is non-standard).
- **Template system**: `lib/templates.js` resolves `{{config.x.y}}` placeholders in operator YAML files using dot-path traversal against the merged config object. Any file with unresolved placeholders is filtered out, enabling progressive configuration -- install what you can now, add the rest when credentials become available.
