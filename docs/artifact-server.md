# Artifact Server

## Overview

The artifact server (`03_artifact_server/`) is a lightweight HTTP file server that acts as the distribution point for VM disk images and VMware migration assets. It is deployed on the Build cluster by Tekton pipeline 5.

## Why it exists

Tekton pipelines build golden VM images (qcow2 for OpenShift Virtualization, vmdk for VMware). Those images need to be accessible over HTTPS for subsequent pipeline stages (VDDK build, containerDisk packaging) and for operators who need to upload proprietary VMware files that cannot be automated.

Two categories of files:

- **Pipeline-built** (automatic): `wandering_frontend.qcow2`, `wandering_frontend.vmdk`, `wandering_backend.qcow2`, `wandering_backend.vmdk`
- **User-uploaded** (manual): VDDK tarball (from Broadcom's support portal -- proprietary, requires login), vCenter CA certificate

The artifact server bridges these two worlds: the pipeline deposits its outputs, and the operator uploads vendor-licensed files through the web UI.

## Architecture

Zero-framework Node.js HTTP server. The only dependency is `busboy` for multipart upload parsing.

| Endpoint | Purpose |
|----------|---------|
| `GET /` | Web UI (SPA) |
| `GET /api/files` | JSON file listing with sizes and timestamps |
| `GET /files/:name` | Stream file download (memory-efficient for multi-GB images) |
| `POST /api/upload` | Multipart upload (2 GB limit, one file at a time) |
| `DELETE /api/files/:name` | Delete a file |

### Input sanitization

`safeName()` strips path traversal via `path.basename()` plus a character whitelist (`[a-zA-Z0-9._-]`). Anything outside the whitelist is replaced with underscores.

## Web UI

The frontend (`public/index.html`) is a self-contained SPA. It organizes files into sections:

- **Frontend VM / Backend VM** -- shows pipeline-built images, tags them "Pipeline", prevents deletion
- **VMware / MTV** -- shows VDDK tarballs and vCenter certs, tags them "Upload", allows deletion
- **Other** -- catch-all for anything that does not match the above

Missing expected files show as "not built yet" placeholders. The right panel has step-by-step instructions for downloading VDDK from Broadcom and extracting the vCenter CA cert.

Includes drag-and-drop upload with progress bar.

## Deployment

Built by Tekton pipeline 5 and deployed as a two-container pod:

- Node.js server on port 8080
- OpenShift OAuth proxy sidecar on port 8443 (auto-generated TLS cert, OpenShift SSO)
- Route with `reencrypt` TLS termination
- 2 GiB RWO PVC (`wandering-artifacts`) mounted at `/var/www/files`

### SELinux/PVC handling

On OpenShift, PVCs have SELinux labels derived from the namespace's MCS level. The pipeline dynamically reads the namespace's `openshift.io/sa.scc.supplemental-groups` and `openshift.io/sa.scc.mcs` annotations, then injects them into the pod spec as `fsGroup` and `seLinuxOptions.level`. Without this, the Node.js process would get "permission denied" when reading files written by a different pod (the copy-artifacts task).

### Why RWO, not RWX

The PVC is ReadWriteOnce -- only one pod can mount it at a time. This is why the pipeline scales down the deployment before copying files, then scales back up. RWO was chosen because it is universally available across storage providers; RWX requires specific storage classes that may not exist on every cluster.

### SHA256 dedup

The copy-artifacts task checksums source and destination files and skips the copy if they match. For multi-GB VM images, this saves significant time on pipeline re-runs.
