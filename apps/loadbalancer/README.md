# Faux Application Load Balancer

A containerized Layer 7 reverse proxy and visual control plane built for infrastructure migration demos. 

This stack runs **Nginx** (the data plane) and a **Node.js Dashboard** (the control plane) in a single container. Nginx proxy passes traffic seamlessly to the active backend while keeping the browser address bar locked to your vanity domain. The dashboard allows you to visually trigger failovers and backend switches in real time.

## Quick Start Guide

### 1. Build the Container

```bash
podman build -t localhost/faux-lb:latest .
```

### 2. Setup Local DNS (Optional)

The domain is read automatically from `configmap.yaml`. Map it to localhost with:

```bash
./hosts.sh add
```

*(Run `./hosts.sh remove` when you are done to clean it up).*

### 3. Deploy the Stack

We use an Ansible playbook to automate generating the Kubernetes Secrets and Pod definitions, and to execute `podman play kube` natively.

```bash
ansible-playbook ../../ansible/loadbalancer/deploy_podman.yml
```

### 4. Access the Stack

- **The Dashboard:** Open `https://dashboard.<your-domain>` to access the visual control plane.
- **The Application:** Open `https://<your-domain>` to see the Nginx reverse proxy serving the live backend.

### 5. Turn Off / Clean Up

```bash
ansible-playbook ../../ansible/loadbalancer/teardown_podman.yml
```

---

## Architecture

- **Data Plane:** Nginx listening on ports 80 and 443. It reads its active target from an `active_backend.conf` file.
- **Control Plane:** Node.js listening on port 8080. When a node is clicked, it updates `active_backend.conf` and executes `nginx -s reload`.
- **Kubernetes-Native:** The deployment is defined by `configmap.yaml` and the Ansible playbook at `../../ansible/loadbalancer/deploy_podman.yml`. Configuration is injected via a `ConfigMap`, and TLS certificates via a `Secret`. The container image is completely stateless.

## Configuration

Edit `configmap.yaml` to define your nodes:

```yaml
title: Application LB
initialActive: 1
domain: wandering-workload.example.com

nodes:
  - name: Legacy VM
    position: 1
    icon: vm                  # vm | cloud | baremetal
    url: http://backend.legacy.local

  - name: "Cloud\nManaged Cluster"
    position: 2
    icon: cloud
    url: https://backend.cloud.example.com
```

*Note: Split long node names across multiple lines using `\n`.*

## Domain and TLS Certificates

The load balancer needs a **real domain name** and valid TLS certificates to
work properly. The domain gives the demo a stable, professional URL that the
audience sees in their browser while the workload migrates between backends.
Without a domain, you would need to use raw IPs or `/etc/hosts` hacks that
break TLS and look unconvincing on stage.

### Getting a domain

Register a domain (or use a subdomain you already control). Point an A record
at the machine running the load balancer. You will need two names:

- `<your-domain>` — the app itself (e.g. `wandering-workload.example.com`)
- `dashboard.<suffix>` — the control plane (the `hosts.sh` script derives this
  automatically from the domain in `configmap.yaml`)

### Obtaining certificates with Let's Encrypt

[Let's Encrypt](https://letsencrypt.org/) provides free, automated TLS
certificates. Use [certbot](https://certbot.eff.org/) to obtain them:

```bash
# Install certbot (Fedora/RHEL)
sudo dnf install certbot

# Obtain a certificate (standalone mode — stop any service on port 80 first)
sudo certbot certonly --standalone -d <your-domain> -d dashboard.<suffix>

# Certificates are written to /etc/letsencrypt/live/<your-domain>/
```

Then copy (or symlink) the certificates into this project:

```bash
cp -rL /etc/letsencrypt/live/<your-domain> apps/loadbalancer/letsencrypt/live/
```

The expected directory layout:

```
letsencrypt/
  live/
    <your-domain>/
      fullchain.pem
      privkey.pem
```

The deploy playbook reads these and generates a Kubernetes Secret automatically.
The `letsencrypt/` directory is gitignored — certificates must never be committed.

Certificates expire after 90 days. Renew with `sudo certbot renew`.

## API Reference

The dashboard provides a REST API to trigger switches programmatically (e.g., from an Ansible task or a webhook):

| Endpoint | Method | Description |
|---|---|---|
| `/` | GET | Dashboard UI |
| `/api/state` | GET | JSON: current state (`title`, `nodes`, `active`) |
| `/api/events` | GET | SSE stream (live updates) |
| `/api/activate` | POST | Switch node: `{"position": 2}` or `{"name": "..."}` |
| `/api/activate?position=2` | GET | Switch node (browser-friendly) |
| `/api/reload` | GET | Re-read config.yaml on demand |
| `/go` | GET | Iframe the currently-active backend |

## Integration with Ansible

Trigger a failover from any Ansible playbook:

```yaml
- name: Switch load balancer to new target
  ansible.builtin.uri:
    url: "http://{{ lb_host }}:8080/api/activate"
    method: POST
    body_format: json
    body:
      position: 2
```

Or use the shell trigger script:

```bash
./trigger.sh 2 http://<lb-host>:8080
```
