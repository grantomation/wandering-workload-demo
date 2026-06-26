# Load Balancer App

The load balancer gives the demo a single stable URL that follows the workload
wherever it goes, and a visual dashboard that makes backend switches visible to
the audience in real time.

## What it is

A containerized stack that runs **Nginx** (data plane) and a **Node.js
dashboard** (control plane) in a single container.

- **Nginx** listens on ports 80 and 443, reverse-proxying traffic to whichever
  cluster route is currently active. It reads its target from
  `active_backend.conf`, so switching backends is an nginx reload, not a
  restart.
- **The dashboard** (Node.js on port 8080) shows every backend as a clickable
  node with live health status. Clicking a node updates `active_backend.conf`
  and triggers `nginx -s reload`. All connected screens update instantly via
  Server-Sent Events.

## How it contributes to the demo

The presenter opens the dashboard on the big screen alongside the Wandering
Workload map. As each Portworx failover completes, the presenter clicks the
next node on the dashboard (or a script calls the API). The audience sees:

1. The health indicator go green on the new cluster
2. The map app load from the new backend
3. All existing pins and data preserved

The vanity domain in the browser address bar never changes — the audience
sees one URL serving the app as it migrates across clouds.

## Architecture

```
Browser ─── https://wandering-workload.example.com ──→  Nginx (443)
                                                           │
                                                    active_backend.conf
                                                           │
         ┌─────────────────────────────────────────────────┤
         ↓              ↓              ↓              ↓    ↓
     Legacy VM      On-Prem OCP      ARO          ROSA    GCP

Browser ─── https://dashboard.example.com ──→ Nginx (443) ──→ Node.js (8080)
```

Nginx serves two virtual hosts:
- `dashboard.*` — proxies to the Node.js dashboard on port 8080
- Everything else — proxies to the currently active backend URL

## Dashboard features

| Feature | Detail |
|---------|--------|
| Click to switch | Click any node to make it the active backend |
| Live updates | SSE stream pushes every switch to all connected screens |
| Health checks | Pings each backend every 5 seconds; offline nodes glow amber |
| REST API | `POST /api/activate` for programmatic switches from scripts or Ansible |
| Config hot-reload | Edit `config.yaml` and the dashboard updates live, no restart |
| Go endpoint | `/go` iframes the active backend (stable vanity URL in the address bar) |

## API reference

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Dashboard UI |
| `/api/state` | GET | JSON: current state (`title`, `nodes`, `active`, `health`) |
| `/api/events` | GET | SSE stream (live updates) |
| `/api/activate` | POST | Switch node: `{"position": 2}` or `{"name": "..."}` |
| `/api/activate?position=2` | GET | Switch node (browser-friendly) |
| `/api/reload` | GET | Re-read config.yaml on demand |
| `/go` | GET | Iframe the currently-active backend |

## Configuration

### Defining backends (`configmap.yaml`)

The ConfigMap is the single source of truth for backend nodes. Edit it to add,
remove, or reorder nodes. The dashboard hot-reloads on save.

```yaml
title: Application LB
initialActive: 1
domain: wandering-workload.example.com

nodes:
  - name: Legacy VM
    position: 1
    icon: vm                  # vm | cloud | baremetal
    url: http://app.legacy.local

  - name: "OpenShift\nOn-Premise"
    position: 2
    icon: baremetal
    url: https://app.apps.ocp-onprem.example.com/

  - name: "Cloud\nManaged Cluster"
    position: 3
    icon: cloud
    url: https://app.apps.cloud-cluster.example.com/
```

Split long node names across lines with `\n`.

### Domain name

The load balancer needs a **real domain name** to give the demo a stable,
audience-facing URL. Register a domain (or use a subdomain you already control)
and point an A record at the machine running the load balancer. You need two
DNS entries:

- `<your-domain>` — the app (e.g. `wandering-workload.example.com`)
- `dashboard.<suffix>` — the control plane (derived automatically by `hosts.sh`)

Set the domain in `configmap.yaml` under the `domain:` key.

### TLS certificates (Let's Encrypt)

The load balancer terminates TLS via Nginx, so it needs valid certificates.
[Let's Encrypt](https://letsencrypt.org/) provides free, automated certs.
Use [certbot](https://certbot.eff.org/) to obtain them:

```bash
sudo certbot certonly --standalone -d <your-domain> -d dashboard.<suffix>
```

Then copy the certificates into the project:

```bash
cp -rL /etc/letsencrypt/live/<your-domain> apps/loadbalancer/letsencrypt/live/
```

Expected layout:

```
letsencrypt/
  live/
    <your-domain>/
      fullchain.pem
      privkey.pem
```

The deploy playbook reads these and generates a Kubernetes Secret automatically.
The `letsencrypt/` directory is gitignored — certificates must never be committed.
Renew with `sudo certbot renew` (certs expire every 90 days).

## Running the load balancer

### Build

```bash
cd apps/loadbalancer
podman build -t localhost/faux-lb:latest .
```

### Set up local DNS

```bash
./hosts.sh add        # maps vanity domain to 127.0.0.1 via /etc/hosts
./hosts.sh remove     # clean up when done
./hosts.sh status     # check current state
```

The domain is read from `config.yaml` automatically.

### Deploy

```bash
ansible-playbook ../../ansible/loadbalancer/deploy_podman.yml
```

This reads the TLS certificates from `letsencrypt/live/`, generates a
Kubernetes Secret and Pod definition, and deploys via `podman play kube`.

### Tear down

```bash
ansible-playbook ../../ansible/loadbalancer/teardown_podman.yml
```

### Access

- **Dashboard:** `https://dashboard.<your-domain>`
- **Application:** `https://<your-domain>` (proxied to the active backend)

## Triggering switches from scripts

### Shell trigger script

```bash
./trigger.sh 2                          # switch to node position 2
./trigger.sh 3 http://laptop:8080       # custom LB host
GLB_URL=http://<lb-host>:8080 ./trigger.sh 4
```

### From Ansible

```yaml
- name: Switch load balancer to new target
  ansible.builtin.uri:
    url: "http://{{ lb_host }}:8080/api/activate"
    method: POST
    body_format: json
    body:
      position: 2
```

### From curl

```bash
curl -X POST http://localhost:8080/api/activate \
  -H 'Content-Type: application/json' \
  -d '{"position": 2}'
```

## File inventory

| File | Purpose |
|------|---------|
| `server.js` | Node.js dashboard server (zero dependencies, Node 18+) |
| `dashboard.html` | Visual dashboard UI (dark/light mode, animated node graphics) |
| `config.yaml` | Local dev node definitions |
| `configmap.yaml` | Production node definitions (Kubernetes ConfigMap format) |
| `Containerfile` | Container image: `node:18-alpine` + nginx |
| `nginx_conf/nginx.conf` | Nginx base config (HTTP→HTTPS redirect, two virtual hosts) |
| `switch_backend.sh` | Writes `active_backend.conf` and reloads nginx |
| `hosts.sh` | Add/remove `/etc/hosts` entries for the vanity domain |
| `trigger.sh` | CLI trigger for switching backends (wraps `curl POST`) |
| `deployment.yaml` | Generated pod spec (hostPort 80/443/8080). Gitignored — regenerated on deploy |
| `package.json` | Node metadata (zero runtime dependencies) |
| `../../ansible/loadbalancer/deploy_podman.yml` | Ansible playbook to deploy via `podman play kube` |
| `../../ansible/loadbalancer/teardown_podman.yml` | Ansible playbook to tear down the deployment |
| `../../ansible/loadbalancer/inventory.ini` | Ansible inventory (localhost) |
| `test/harness.js` | API smoke test |
| `test/dummy-targets.js` | Dummy HTTP backends for local testing |
| `test/config.test.yaml` | Test configuration |

## Testing locally

```bash
# Terminal 1: start dummy backends
node test/dummy-targets.js

# Terminal 2: start the dashboard
node server.js

# Terminal 3: run the smoke test
node test/harness.js
```
