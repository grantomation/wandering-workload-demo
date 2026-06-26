# Wandering Workload App

The Wandering Workload is the application being migrated. It is a two-tier
Node.js + PostgreSQL app that presents a topographic map where users plant pins
to mark infrastructure stops. As the workload hops between clouds, the pins
record which infrastructure route served them, so the audience watches a visual
trail grow across the terrain.

## What it is

- **Frontend:** Node.js (Express) serving a map UI on port 80
- **Backend:** PostgreSQL storing the `stops` table

Both tiers run natively on VMs (no containers). The app is deployed by Ansible
playbooks that copy the source code, install dependencies, and create systemd
services.

## How it contributes to the demo

The app is the visual payload that proves the migration story:

1. **Before migration:** plant a few pins on the VMware-hosted app. Each pin
   records the hostname/route it was created through.
2. **After each hop:** plant another pin. The sidebar shows each pin's route
   label — the audience can see that different clusters served different pins.
3. **At the end:** the map shows a trail across the terrain. Every pin, every
   colour, every trail segment survived every hop. The data is intact.

The app's database (`stops` table) lives on the VM's own disk, so PostgreSQL's
data directory rides along with every migration — MTV copies the disk, Portworx
DR replicates the PVC. No backup/restore, no data pipeline, no export/import.

## Application architecture

```
Browser
  │
  ├── GET /                    Topographic map UI (static HTML/CSS/JS)
  ├── GET /api/stops           List all pins
  ├── POST /api/stops          Plant a new pin (name, x, y, captured route)
  ├── DELETE /api/stops/:id    Remove a pin
  ├── GET /health              Health check (DB connection status)
  └── GET /db                  Debug: raw database contents
  │
  ↓
Express (server.js)
  │
  ↓
PostgreSQL (stops table)
  │
  └── id | name | x | y | color | url | created_at
```

### How route capture works

When a pin is planted, the server reads the `Host` / `X-Forwarded-Host` header
from the incoming request. If the hostname is a genuine infrastructure route
(not the vanity/LB domain, not localhost, not an IP address), it is stored in
the `url` column of the `stops` table.

This means each pin carries a record of which infrastructure served it:
- `https://wandering.apps.<aro-cluster>.<region>.aroapp.io` — planted on ARO
- `https://wandering.apps.<rosa-cluster>.<id>.openshiftapps.com` — planted on ROSA
- `NULL` — planted via the load balancer's vanity domain or by IP

The `PUBLIC_DOMAIN` env var tells the app which domain is the stable
vanity/redirector domain (so it is excluded from route capture).

### How it survives migration

The frontend resolves the backend by **hostname** (`wandering-backend-svc`),
not by IP. A boot-time systemd service (`wandering-env-detect`) runs
`systemd-detect-virt` to decide how that name resolves:

| Platform | Detection result | Resolution |
|----------|-----------------|------------|
| VMware | `vmware` | `/etc/hosts` entry maps `wandering-backend-svc` → backend's static IP |
| OpenShift Virt | `kvm` | CoreDNS resolves the Kubernetes Service → backend pod IP |

The same `DB_HOST=wandering-backend-svc` works on both platforms. Migration
order doesn't matter — the frontend discovers the backend wherever the pod
network lands it. Nothing inside the guest changes at cutover.

### VM services architecture

The VMs are configured by Ansible playbooks (`ansible/vm-configure/`) that
install systemd services (Fedora) or OpenRC services (Alpine). The golden image
is a generic base; role assignment happens per-clone.

#### Services on the frontend VM

| Service | Type | Purpose |
|---------|------|---------|
| `wandering-env-detect` | oneshot (boot) | Detects VMware vs OpenShift; writes `/etc/hosts` or clears it |
| `wandering-workload` | long-running | Node.js Express app on port 80 |

Boot order: `wandering-env-detect` runs first (the workload service depends on
it via `Requires=` and `After=`), then `wandering-workload` starts.

#### Services on the backend VM

| Service | Type | Purpose |
|---------|------|---------|
| `wandering-env-detect` | oneshot (boot) | Same detection as frontend |
| `postgresql` | long-running | Stock PostgreSQL with the `stops` table |

#### Combined (single-VM) variant

Runs both PostgreSQL and the Node.js app on one VM. No `wandering-env-detect`
is needed because `DB_HOST=127.0.0.1` (loopback). Firewall is enabled with the
app port opened.

#### Configuration files on the VM

| File | Purpose |
|------|---------|
| `/etc/wandering-workload.env` | `DB_HOST`, `DB_PORT`, credentials, `PORT` |
| `/usr/local/bin/wandering-env-detect.sh` | Detection script called by the systemd unit |
| `/opt/wandering-workload/` | App source code (copied from the repo) |

### Why we use `/etc/hosts` (and when you don't need to)

The whole point of this demo is that VMs migrate from VMware to OpenShift
Virtualization **without modifying the guest OS**. The same disk image boots on
both platforms and the app just works. The challenge is name resolution: the
frontend needs to find the backend by hostname (`wandering-backend-svc`), but
the two platforms resolve names in completely different ways.

**On OpenShift** this is easy — we pre-create a Kubernetes Service called
`wandering-backend-svc` before migration, and CoreDNS resolves it to the
backend pod's IP. Standard Kubernetes plumbing; nothing special.

**On VMware** there is no Kubernetes DNS. In a typical lab or demo environment,
there is also no enterprise DNS server where you can register arbitrary A
records. The VMs sit on a flat vSphere network with DHCP handing out IPs but
no reverse-lookup zone you control. So the hostname `wandering-backend-svc`
would simply not resolve.

The `/etc/hosts` approach solves this: a boot-time oneshot service
(`wandering-env-detect`) runs `systemd-detect-virt` and asks "am I on VMware
or something else?"

- **VMware** → writes a managed block into `/etc/hosts` mapping
  `wandering-backend-svc` to the backend's known static IP.
- **Anything else (KVM/OpenShift)** → removes that block so CoreDNS takes over.

This gives us a **zero-touch migration**: the disk is copied byte-for-byte by
MTV, the VM boots on OpenShift, the detect script sees `kvm` instead of
`vmware`, deletes the `/etc/hosts` entry, and the app seamlessly switches to
Kubernetes DNS. No operator intervention, no guest reconfiguration, no scripts
to run post-migration.

#### Why not just hardcode the backend IP?

We could skip hostnames entirely and set `DB_HOST=198.51.100.41`. That works
on VMware, but after migration the backend gets a pod-network IP
(e.g. `10.128.2.15`) that varies per cluster. A hardcoded IP breaks the moment
the VM lands on OpenShift. Using a hostname lets each platform resolve it
through its own native mechanism.

#### In a proper DNS environment this is not needed

If your VMware environment has a DNS server you control (Active Directory DNS,
FreeIPA, BIND, Infoblox, etc.), none of the `/etc/hosts` machinery is required.
The setup becomes much simpler:

1. Create a DNS A record: `wandering-backend-svc` → backend VM's IP address.
2. Point the VMs' resolv.conf at that DNS server.
3. Done. The frontend resolves the backend via DNS on VMware, and via CoreDNS
   on OpenShift, with no boot-time detection needed.

You would remove the `wandering-env-detect` service entirely and drop the
static IP pinning from the Ansible playbooks. The app, the systemd services,
and PostgreSQL all stay exactly the same — only the name-resolution plumbing
changes.

| Aspect | Current (demo/lab) | With enterprise DNS |
|--------|-------------------|---------------------|
| Backend resolution on VMware | `wandering-env-detect` writes `/etc/hosts` at boot | DNS A record resolves `wandering-backend-svc` |
| Backend resolution on OpenShift | CoreDNS resolves the K8s Service | Same — CoreDNS resolves the K8s Service |
| `wandering-env-detect` service | Required (bridges the DNS gap) | Not needed — delete it |
| Static IPs on VMware | Required (so `/etc/hosts` points somewhere known) | Could use DHCP + dynamic DNS registration |
| Post-migration guest changes | None (detect script handles it) | None (DNS just works on both sides) |

In short: **`wandering-env-detect` and the `/etc/hosts` block are a workaround
for not having DNS on the VMware side.** They exist because demo/lab
environments rarely come with a DNS server you can register arbitrary records
in. In any production VMware environment with proper DNS infrastructure, you
would skip this layer entirely and let DNS do its job on both platforms.

### Alpine variant (OpenRC)

The Alpine playbooks (`ansible/vm-configure/alpine/`) provide the same services
using OpenRC instead of systemd. The detection script uses `virt-what` instead
of `systemd-detect-virt`, and network configuration is written to
`/etc/network/interfaces` instead of NetworkManager. See the
[Alpine golden image README](../ansible/golden-images/alpine/README.md) for
the OpenRC cheat sheet.

### Startup behaviour

The app listens on its port **immediately** (so `/health` is always reachable)
but connects to PostgreSQL in the background with infinite retry. This means:

- The app tolerates the backend not being ready yet (e.g. right after a
  migration when the backend VM hasn't booted)
- `/health` reports `{"status":"starting","database":"connecting"}` until the
  DB is reachable, then `{"status":"ok","database":"connected"}`
- The app self-heals without ever exiting — startup order is not a correctness
  requirement

## The map UI

The frontend is a single-page app that renders:

- **Topographic contour lines** on a canvas (procedurally generated)
- **Region labels** (Cloud Summit, Metal Valley, Private Peak, Data Ridge, etc.)
- **Pins** at each stop, colour-cycled from an 8-colour palette
- **A dashed trail** connecting pins in creation order
- **An animated VM marker** that travels along the trail
- **A sidebar** listing every stop with its route and creation time
- **A route inspector** (layers button) showing all unique infrastructure
  routes the app has been served through
- **Stats** (hops, distance, uptime) at the bottom of the map
- **Zoom/pan** with mouse wheel and drag

## Database schema

The `stops` table is created by the `backend.yml` Ansible playbook:

```sql
CREATE TABLE stops (
  id         SERIAL PRIMARY KEY,
  name       VARCHAR(255) NOT NULL,
  x          FLOAT NOT NULL,
  y          FLOAT NOT NULL,
  color      VARCHAR(7),
  url        TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

Pin colours are assigned from a fixed 8-colour palette based on the SERIAL id:
`PALETTE[(id - 1) % 8]`. This keeps each pin's colour stable across deletes.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `DB_HOST` | `wandering-backend-svc` | PostgreSQL hostname (set by env-detect or override) |
| `DB_PORT` | `5432` | PostgreSQL port |
| `DB_USER` | `todo` | PostgreSQL user |
| `DB_PASSWORD` | `todo` | PostgreSQL password |
| `DB_NAME` | `todo` | PostgreSQL database name |
| `DB_SSL` | `false` | Enable SSL for DB connection |
| `PORT` | `8080` | Port the app listens on (overridden to 80 by systemd) |
| `PUBLIC_DOMAIN` | `your-domain.example.com` | Vanity/load-balancer domain excluded from route capture |
| `INFRA_URL` | (none) | Manual override for the captured route (dev use) |

## File inventory

| File | Purpose |
|------|---------|
| `server.js` | Express API server (stops CRUD, health check, route capture, DB retry) |
| `public/index.html` | Main UI: topographic map, sidebar, pin controls, stats |
| `public/app.js` | Frontend logic: contour rendering, pin placement, trail animation, zoom/pan |
| `public/styles.css` | Stylesheet |
| `public/standalone.html` | Standalone variant of the UI |
| `package.json` | Dependencies: `express` (^4.21.2), `pg` (^8.13.1); Node >=18 |
| `package-lock.json` | Locked dependency tree |
| `.env.example` | Example environment variables |

## Running locally (development)

```bash
cd apps/wandering-workload
npm install

# Start a local PostgreSQL with the stops table:
createdb todo
psql -d todo -c "CREATE TABLE stops (id SERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL, x FLOAT NOT NULL, y FLOAT NOT NULL, color VARCHAR(7), url TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
psql -d todo -c "CREATE USER todo WITH PASSWORD 'todo'; GRANT ALL ON ALL TABLES IN SCHEMA public TO todo; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO todo;"

# Start the app:
DB_HOST=127.0.0.1 PORT=8080 npm start
```

Open `http://localhost:8080`, type a name, and double-click the map to plant a
pin.
