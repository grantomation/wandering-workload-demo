# Architecture

## What Wandering Workload proves

Wandering Workload is a live demonstration that migrates a real, stateful
application -- a two-tier Node.js frontend backed by PostgreSQL, both running
natively on virtual machines -- across five different infrastructure platforms
without downtime and without changing anything inside the guest VMs.

The five platforms are:

1. **VMware vSphere** -- the legacy starting point
2. **On-prem OpenShift** -- OCP on AWS simulating bare-metal infrastructure
3. **Azure Red Hat OpenShift (ARO)** -- managed OpenShift on Azure
4. **Red Hat OpenShift Service on AWS (ROSA)** -- managed OpenShift on AWS
5. **OpenShift Dedicated on GCP (OSD)** -- managed OpenShift on Google Cloud

The demo chain follows a round trip:

    VMware --> on-prem --> ARO --> ROSA --> GCP --> on-prem

Two migration technologies make this possible:

- **MTV (Migration Toolkit for Virtualization)** handles the initial lift from
  VMware into OpenShift. It copies VM disks from vSphere into KubeVirt virtual
  machines on the on-prem cluster. This is the only VMware-specific hop.

- **Portworx DR (Disaster Recovery)** handles every subsequent hop between
  OpenShift clusters. It replicates the VM volumes asynchronously via S3 and
  fails them over to the next cluster in the chain. Because every spoke runs
  Portworx and OpenShift Virtualization, the VMs boot identically on each one.

The demo proves that VM workload portability across hybrid and multi-cloud
environments is practical today, using existing Red Hat and Portworx
technology, with zero application changes.


## The five-cluster topology

```
                              ROSA (Hub)
                           my-rosa-hub
                      AWS ap-southeast-4
                    ACM + PX Multi-Cluster
                    (no PX storage engine)
                              |
            +-----------------+-----------------+
            |                 |                 |
        On-Prem (OCP)     ARO              ROSA (Spoke)         OSD (GCP)
        my-ocp            my-aro           my-rosa-spoke        my-osd
        AWS ap-se-4       Azure au-east    AWS ap-se-4          GCP asia-se1
        PX + Virt         PX + Virt        PX + Virt            PX + Virt
            |                 |                 |                 |
            +-----------------+-----------------+-----------------+
                          DR pair ring
```

**Hub cluster (ROSA):** Runs Advanced Cluster Management (ACM) and the
Portworx Multi-Cluster control plane. The hub does NOT run the Portworx
storage engine -- it only hosts the multicluster custom resources
(DisasterRecoveryPairs and ProtectionGroups) that coordinate replication
between spokes. This separation exists because the hub needs ACM (which is
resource-heavy at ~8 CPU / 16 GB memory) but does not need to store workload
data.

**Four spoke clusters:** Each spoke runs Portworx Enterprise (storage engine)
and OpenShift Virtualization (KubeVirt). The spokes form a directed ring for
disaster recovery pairing:

| DR Pair         | Source   | Destination |
|-----------------|----------|-------------|
| on-prem --> aro | on-prem  | aro         |
| aro --> rosa    | aro      | rosa        |
| rosa --> gcp    | rosa     | gcp         |
| gcp --> on-prem | gcp      | on-prem     |

Each pair is bidirectional (Portworx `BI-DIRECTIONAL` pair type), and
replication flows through a shared S3 bucket in `ap-southeast-4`. The ring
closes back to on-prem, proving the workload can return home.

**Geographic spread:** The clusters span the Asia-Pacific region -- Melbourne
(AWS `ap-southeast-4`), Australia East (Azure), and Singapore (GCP
`asia-southeast1`). This is deliberate: it makes the cross-cloud replication
visible in the demo (different cloud regions, different providers) while
keeping latency reasonable for live demonstrations.


## How the components connect

The repository is organized into six numbered subsystems. Each is
self-contained and can be understood independently, but they connect in a
specific dependency chain during the demo lifecycle.

### 00_build_clusters -- Cluster prerequisites

The demo assumes five pre-existing OpenShift clusters. This folder documents
the expected topology (hub + four spokes) and their roles. Cluster
provisioning is out of scope -- use whatever tooling fits your environment
(Terraform, ROSA CLI, `az aro create`, the OpenShift installer, etc.).

### 01_installation_dashboard -- The main user interface

A Node.js web application deployed on one OpenShift cluster that serves as the
single pane of glass for the entire demo setup. From a browser, an operator
can:

- **Register clusters** by name, API URL, and credentials (stored in a
  Kubernetes Secret on the dashboard's own cluster)
- **Assign roles** to clusters (Build, MTV, ACM, Virtualization, Portworx) --
  each role triggers installation of the required operators
- **Install operators** with generated YAML manifests that the dashboard
  applies via the Kubernetes API of each remote cluster
- **Deploy Tekton pipelines** that build VM images, deploy the artifact
  server, configure the load balancer, and onboard ACM spoke clusters
- **Configure Portworx** per platform -- detecting whether a cluster runs on
  AWS (STS or IAM), Azure (service principal), or GCP, then applying the
  correct StorageCluster spec and credential secret
- **Manage the demo lifecycle** -- create and delete DisasterRecoveryPairs
  and ProtectionGroups, audit for orphaned Stork resources, and deep-clean
  DR state across all spokes

The dashboard communicates with remote clusters via their Kubernetes APIs
using stored credentials. It uses Server-Sent Events (SSE) to push real-time
progress to the browser during long-running operations (operator installs,
pipeline deployments, DR pair creation).

**Why a web dashboard instead of CLI scripts:** The original approach used
shell scripts with `oc` and `kubectl` commands. This required the operator to
have every CLI tool installed, manage kubeconfig contexts for five clusters,
and remember the correct sequence of commands. The dashboard eliminates all of
that -- an operator needs only a browser and the dashboard URL. It also makes
the system demonstrable: you can show the audience the setup process itself,
not just the result.

**Why deploy on OpenShift:** The dashboard runs as a regular OpenShift
deployment with an S2I build. It uses the cluster's own service account for
local API access and stores its state in Kubernetes Secrets and ConfigMaps.
This means there is no external database, no cloud storage dependency, and
the dashboard can be torn down and redeployed from source in minutes. The
OpenShift OAuth Proxy protects the route with existing cluster credentials.

### 02_workload -- The demo application

A two-tier application deployed natively on VMs (not in containers):

- **Frontend VM:** Node.js (Express) serving a topographic map UI. Each
  click on the map plants a pin that records its coordinates, a cycling
  color, and the infrastructure route URL captured from the HTTP request
  headers.
- **Backend VM:** PostgreSQL storing the `stops` table. The database lives
  on the VM's root disk, so it moves with every migration.

The application exists to tell the infrastructure story visually. As the
workload hops between clouds, each pin proves which cluster served it. The
dashed trail across the terrain map shows the journey. After the round trip,
the audience sees pins from five different infrastructure routes -- all
served by the same two VMs, with the same data intact.

**Why VMs and not containers:** The entire point of the demo is showing that
existing VM workloads can migrate without being rewritten. Containerizing the
app would defeat the purpose. The workload represents a typical legacy
application that a customer might want to move to OpenShift without
refactoring.

**Why Node.js + PostgreSQL:** The app needs to be stateful (to prove data
survives migration) and visually engaging (to hold an audience's attention).
A database-backed map with growing trails is more compelling than a static
page. Node.js was chosen because it has no native module dependencies, making
it portable across Alpine and Fedora without recompilation. PostgreSQL is the
simplest relational database to install and configure unattended on a VM.

### 03_artifact_server -- Pipeline-built file server

An HTTP file server deployed by the Tekton pipelines on the build cluster.
It serves two categories of files:

1. **Pipeline-built artifacts** -- the golden VM disk images (qcow2 format)
   produced by the image build pipelines. These are large binary files
   (640 MB to 1.7 GB) that downstream pipelines and MTV migrations consume.

2. **Manually uploaded files** -- the VMware VDDK (Virtual Disk Development
   Kit) tarball and vCenter CA certificate. These cannot be automated because
   VMware's VDDK requires accepting a license agreement and downloading from
   the VMware customer portal. The artifact server provides a drag-and-drop
   upload UI so the operator can place these files where the pipelines
   expect them.

**Why not use an OCI registry or S3:** The VDDK tarball is 200+ MB and must
be consumed by the MTV operator as a container image built from a specific
base. Storing it in S3 would add an AWS dependency to the build pipeline.
Using the OCI registry would work for the VDDK image but not for the raw
qcow2 disk images that `virt-customize` needs as input. A simple HTTP file
server covers both use cases with one component, and it runs on the same
cluster as the build pipelines, so downloads are fast.

### 04_loadbalancer_app -- Visual reverse proxy

A zero-dependency Node.js application that gives the audience one stable URL
pointing at whichever cluster is currently active. It combines a control
plane (dashboard) and a data plane (reverse proxy) on a single port using
Host header routing.

**Control plane (dashboard hostname):** Shows every backend cluster as a
clickable card with live health status. Clicking a card switches the active
backend. Health checks ping each backend every 5 seconds; offline nodes
glow amber. An SSE stream pushes every switch to all connected screens.

**Data plane (vanity domain):** When the incoming `Host` header matches the
configured domain, the request is reverse-proxied to the active backend's
URL. The audience sees the vanity domain in their address bar while the
content comes from whichever cluster is live.

**Why not Nginx or HAProxy:** The load balancer needs to do three things that
a traditional reverse proxy cannot: (1) provide a live visual dashboard
showing all backends, (2) switch backends via a REST API so scripts can
trigger switches programmatically, and (3) push state changes to connected
browsers via SSE. Building this in Node.js keeps it to a single file with
zero dependencies, deployable as a container or a standalone process.

**Why `/go` instead of direct proxy:** The `/go` endpoint wraps the active
backend in an iframe. This keeps the vanity domain in the browser's address
bar even when the backend URL changes, which is important for the demo
narrative -- the audience sees one stable URL serving content from different
clusters.

**How the subsystems connect during a demo:**

```
00_build_clusters            Provisions the 5 clusters (done days before)
        |
01_installation_dashboard    Registers clusters, installs operators, deploys
        |                    pipelines, builds VM images, configures Portworx,
        |                    manages DR pairs and protection groups
        |
        +-- builds --> 03_artifact_server (serves VM disk images)
        |
        +-- builds --> 04_loadbalancer_app (deployed on build cluster)
        |
        +-- runs pipelines that produce VM images
        |
04_loadbalancer_app          Switches active backend after each hop
        |
02_workload                  Audience plants pins at each stop
```


## Design philosophy

### Everything from one cluster

The installation dashboard runs on a single OpenShift cluster and reaches
every other cluster through its Kubernetes API. There is no requirement to
install CLI tools on an operator's laptop, manage kubeconfig files, or
maintain SSH access to cluster nodes.

**Why:** A demo that requires the presenter to have `oc`, `kubectl`,
`terraform`, `ansible`, `gcloud`, and `az` all configured on their laptop is
fragile. Different laptop OSes, different CLI versions, expired tokens, VPN
requirements -- all of these become failure modes during a live
presentation. By centralizing control into a web application running on
OpenShift, the only prerequisite is a browser. The cluster's own service
account handles authentication for local operations, and stored credentials
handle remote cluster access.

### Build assets on OpenShift

VM images are built inside Tekton pipelines using `guestfs-tools` running
in a privileged container, not on a local workstation. The pipeline clones
the repo, downloads a cloud image, runs `virt-customize` to inject the
application and configuration, shrinks the disk, and uploads the result to
the artifact server.

**Why:** Building a 1.7 GB VM image requires `libguestfs`, `qemu-img`, and
several GB of temporary disk space. Requiring these on an operator's laptop
means they need a Linux machine (or nested virtualization on macOS) with
specific packages installed. By building on OpenShift with Tekton, the build
environment is reproducible -- the same container image produces the same
golden VM every time, regardless of who triggers it. The Tekton pipeline
also provides a clear audit trail: each pipeline run records what was built,
when, and from which git commit.

### Alpine over Fedora

The project originally used Fedora Cloud images for the golden VMs. The
resulting disk was approximately 1.7 GB after aggressive shrinking (a
two-step process involving BTRFS pre-shrink with `guestfish` followed by
`virt-resize`). The project added Alpine Linux support, which produces a
640 MB disk image.

**Why:** During a live demo, the audience watches the MTV migration copy VM
disks from VMware to OpenShift. With two VMs (frontend + backend), Fedora
means copying approximately 3.4 GB. Alpine cuts this to approximately
1.3 GB, reducing migration time from several minutes to well under a minute
on stage. The smaller image also means faster Portworx DR replication on
each subsequent hop.

Alpine uses musl libc, BusyBox, and OpenRC instead of glibc, systemd, and
the full GNU userland. The application is pure JavaScript with no native
modules, so it runs identically on both distributions. The VM configuration
scripts needed rewriting for Alpine (OpenRC services instead of systemd
units, `ifupdown` instead of `nmcli`), but the application code is
unchanged.

### No config in code

All platform-specific values -- IP addresses, cluster names, API URLs,
credentials, S3 bucket details, Portworx license keys -- live in
configuration files (`config.yaml`), Kubernetes Secrets, or environment
variables. Nothing is hardcoded in application code.

**Why:** The demo spans five different clusters on three different cloud
providers. Hardcoding any value means the code only works in one specific
environment. Configuration-driven code can be adapted to a different set of
clusters by changing `config.yaml` and re-entering credentials in the
dashboard, without modifying or rebuilding any application.

### Self-healing apps

The workload application starts listening on its HTTP port immediately,
before the database connection is established. It retries the database
connection forever in the background, cycling through candidate hostnames.
The `/health` endpoint always responds -- reporting `starting` while the
database connects and `ok` once it is ready.

**Why:** During migration, the frontend and backend VMs may start in any
order. If the frontend VM boots before the backend VM, a traditional
application would crash on startup because the database is unreachable.
Crash-looping VMs during a live demo is unacceptable. By decoupling the
HTTP listener from the database connection, the frontend VM is always
responsive to health checks and load balancer probes. The database
connection completes whenever the backend VM becomes available, regardless
of timing.

This also means migration order between the two VMs does not matter. Whether
the frontend migrates first or the backend migrates first, the application
recovers without intervention.

### Zero-touch migration

The workload VMs detect their platform at boot time and adjust hostname
resolution accordingly, with no manual configuration at cutover.

On **VMware**, the frontend VM resolves the backend hostname
(`wandering-backend-svc`) via an `/etc/hosts` entry pointing to the
backend's static IP address on the VMware network.

On **OpenShift**, a boot-time service detects KVM (indicating OpenShift
Virtualization) and removes the `/etc/hosts` entry. The same hostname is
then resolved by CoreDNS via a Kubernetes Service that routes to the backend
VM's pod IP.

The same application binary, the same `DB_HOST` environment variable, and
the same hostname work in both environments. The only difference is the
resolution path -- and that difference is handled by the platform detection
service at boot, not by the operator at cutover.

**Why:** Manual rewiring at cutover (editing config files, changing
environment variables, restarting services) is both error-prone during a
live demo and contrary to the zero-change migration narrative. The audience
should see that the VMs boot and reconnect automatically, proving that the
application truly did not need to be modified for migration.


## What this repo does NOT cover

**Cloud IAM permissions:** Portworx requires pre-existing cloud permissions
to provision storage. On AWS, this means IAM roles (or STS role ARNs for
ROSA). On Azure, ARO clusters must be built with a service principal --
managed identity is not supported because Portworx expects credentials on
worker nodes, which ARO does not expose. On GCP, a service account JSON key
is required. The dashboard automates the Portworx installation and
StorageCluster deployment, but it cannot create these cloud-side
prerequisites.

**OpenShift cluster provisioning:** The five clusters must be provisioned
before using this repo. Use whatever tooling fits your environment (Terraform,
ROSA CLI, `az aro create`, the OpenShift installer, etc.). This repo assumes
clusters exist and are reachable via their API URLs.

**VMware vSphere infrastructure:** The VMware environment (vCenter, ESXi
hosts, datastores, networking) must be pre-existing. The demo starts from
VMs already running on vSphere. This repo provides the golden image build
pipeline and the application configuration, but does not automate vSphere
setup.
