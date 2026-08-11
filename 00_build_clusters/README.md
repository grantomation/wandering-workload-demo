# Build Clusters

OpenShift cluster provisioning is out of scope for this repo. The demo assumes
five pre-existing clusters are already provisioned and reachable:

| Cluster | Platform | Role |
|---------|----------|------|
| Hub | ROSA | ACM hub + Portworx multicluster control plane |
| ARO | Azure Red Hat OpenShift | Spoke |
| ROSA | Red Hat OpenShift on AWS | Spoke |
| GCP | OSD on Google Cloud | Spoke |
| On-Prem | Bare-metal / vSphere OpenShift | Spoke + MTV source |

Cluster build automation will be added here as it becomes available.
