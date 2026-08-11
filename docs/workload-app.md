# Wandering Workload Application

## What it does

A two-tier application deployed natively on VMs (not containers): Node.js frontend + PostgreSQL backend. The frontend serves a topographic map UI where each "stop" plants a numbered, color-coded pin. A dashed trail connects the pins, and an animated VM marker shows where the workload currently lives.

The core purpose: each pin captures the infrastructure route URL that served the request. As the workload migrates between clouds, the trail of pins proves which cluster served each stop. The data (pins, trails, PostgreSQL rows) survives every migration because it rides on the VM disk.

## Architecture

### Server (server.js)

- Express on port 8080, PostgreSQL via `pg` Pool
- Only 2 dependencies: express, pg. No ORM, no build step
- Starts listening IMMEDIATELY, then connects to PostgreSQL in the background with infinite retry. This means:
  - Health endpoint is always reachable (Kubernetes liveness probes never kill the pod for a transient DB outage)
  - Startup order between frontend and backend VMs is irrelevant
  - After migration, DNS/hosts updates and the next retry succeeds -- self-healing

### API routes

| Route | Method | Purpose |
|-------|--------|---------|
| `/health` | GET | Returns `{status: "ok", database: "connected"}` or 503. Used by readiness probes and the frontend's recovery polling. |
| `/api/stops` | GET | All stops ordered by id |
| `/api/stops` | POST | Create a stop. Accepts `{name, x, y}`. Captures infrastructure URL from request headers. |
| `/api/stops/:id` | DELETE | Delete a stop |
| `/db` | GET | Debug dump of the stops table |

### Route capture (infraUrlFromRequest)

This is the mechanism that makes the demo work. The server reads its own incoming HTTP request to discover which infrastructure route is currently exposing it:

1. Checks for `INFRA_URL` env var override (local dev)
2. Reads `X-Forwarded-Host` (set by OpenShift's HAProxy router) or falls back to `Host` header
3. Filters out non-infrastructure hostnames:
   - The stable vanity/LB domain (`PUBLIC_DOMAIN` env var) -- accessing via the load balancer is not a "real" infrastructure route
   - `localhost` -- development access
   - Bare IP addresses -- direct IP access is not a named route
4. Constructs `{proto}://{host}` for valid hostnames, or returns null (stored as SQL NULL -- the pin shows "route unknown")

**Why HTTP headers instead of a platform API**: The app needs no platform SDK, no `oc` CLI, no vSphere API, no cluster credentials. It reads what the network tells it. Each pin "freezes" the route that was live when the user clicked. After migration, the old route goes dead and the new infrastructure exposes a different hostname. The journey history IS the sequence of Host headers.

### Database schema

The `stops` table (auto-created on first connect):

| Column | Type | Notes |
|--------|------|-------|
| id | SERIAL PRIMARY KEY | Never reused, even after deletes. Used for color derivation. |
| name | TEXT | User-provided label |
| x | NUMERIC | Map x-coordinate (percent, clamped 2-98) |
| y | NUMERIC | Map y-coordinate (percent, clamped 4-95) |
| color | TEXT | Hex color from 8-color palette |
| url | TEXT (nullable) | Infrastructure route URL, or NULL |
| created_at | TIMESTAMP | Used for uptime calculation |

**Why SERIAL for colors**: Colors are assigned as `palette[(id - 1) % 8]`. Because SERIAL IDs are never recycled, deleting a pin doesn't shift subsequent pins' colors. The server reserves the next id via `nextval()` before inserting so it can compute the color deterministically.

**Why asymmetric clamping** (x: 2-98, y: 4-95): The top of the map has HUD elements (title card, banner) that would occlude pins placed too high. The bottom has less chrome, so pins can be placed closer to the edge.

## Frontend (public/app.js)

### Zero external libraries

The entire frontend is vanilla JavaScript in an IIFE. No React, no D3, no Leaflet. External resources are limited to Google Fonts (Space Grotesk for body text, IBM Plex Mono for data/labels).

### The map is procedural and deterministic

The terrain is generated from a seeded PRNG (seed 1337) using fractional Brownian motion (5 octaves of value noise). `drawContours()` runs marching squares to extract 13 iso-levels. Because the seed is fixed, every user sees the same terrain -- the map is deterministic. Pin coordinates stored in the database as abstract percentages always land on the same terrain features.

Region names ("Cloud Summit," "Metal Valley," "Private Peak," "Data Ridge," "Uplink Uplands," "Edge Escarpment") are tongue-in-cheek references to infrastructure concepts. Elevation is fictional but consistent (640m-3320m range).

### Interaction model

- Double-click to place a pin (opens a name input popup near the click)
- Single-click a pin to select it (shows route history in the inspector panel)
- Drag to pan, scroll to zoom (0.45x to 6x range)
- Pins are visually draggable but positions are not persisted to the server (UI-only)
- The VM marker animates smoothly (1100ms ease-in-out) to each new pin

### Stats bar

Bottom-left shows: hop count, total trail distance (km), and uptime since the earliest stop's `created_at` (ticking live).

### Inspector panel

When a pin is selected, shows all infrastructure route URLs up to that point. Only the last stop (where the VM currently lives) is marked "live" with a green dot and a clickable link. Earlier hops are "retired" with strikethrough text.

### DB error recovery

If the initial fetch fails, a full-screen red overlay ("Database Not Connected") appears and polls `/health` every 3 seconds. When the DB comes back, the overlay auto-dismisses and stops reload.

## How it survives migration

The app connects to PostgreSQL via hostname `wandering-backend-svc`, not an IP. Resolution varies by platform:

| Platform | Resolution mechanism |
|----------|---------------------|
| VMware | Avahi/mDNS -- the backend broadcasts its hostname, the frontend resolves `wandering-backend-svc.local` via `avahi-resolve` |
| OpenShift | CoreDNS -- `wandering-backend-svc` resolves as a Kubernetes Service in the same namespace |

The `DB_HOSTS` array defaults to `['wandering-backend-svc', 'wandering-backend-svc.local']`. The connect function tries each host in sequence, retrying every 2 seconds forever. Combined with the health endpoint always being available, the app self-heals after any migration without operator intervention.

**Why hostname not IP**: A hardcoded IP breaks on OpenShift because the backend gets a pod-network IP that varies per cluster. Hostname resolution adapts to the platform.

**Why the app never exits**: The process retries DB connections forever and always responds to health probes. This prevents Kubernetes from restart-looping the pod during the window between VM boot and database availability.

## standalone.html

A self-contained design prototype with all styles and JS inlined, an in-memory mock API (no backend needed), and pre-seeded stops. Used for iterating on the UI without running a server. Can be opened directly from disk. The comment at the top says: "Edit the design here, then re-split."

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| PORT | 8080 | HTTP listen port |
| DB_HOST | wandering-backend-svc | PostgreSQL hostname |
| DB_PORT | 5432 | PostgreSQL port |
| DB_USER | todo | PostgreSQL username |
| DB_PASSWORD | todo | PostgreSQL password |
| DB_NAME | todo | PostgreSQL database name |
| DB_SSL | (unset) | Set to "true" for SSL with rejectUnauthorized: false |
| PUBLIC_DOMAIN | your-domain.example.com | Vanity/LB domain excluded from route capture |
| INFRA_URL | (unset) | Manual override for infrastructure URL (local dev) |
