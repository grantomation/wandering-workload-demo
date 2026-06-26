# Future: modernise the two VMs into containers on OpenShift

Goal: once the app has been lift-and-shifted onto KubeVirt VMs, optionally retire the VMs
and run it as native OpenShift **containers**.

> **Heads up:** the container manifests and `Dockerfile` that used to live in this repo
> (`openshift/gitops/`, `Dockerfile`, `.dockerignore`) were **removed** during the
> Wandering Workload rebrand — they still referenced the old `todo-web`/`todo-db` images
> and the `todos` schema. A snapshot was archived to
> `~/wandering-workload-containers-backup-2026-06-17.tgz`. Treat the steps below as a plan
> to **rebuild** that path, not a description of files that exist today.

The app needs **zero code changes** to containerise — it already talks to the database by
the name `wandering-db` (via `DB_HOST`) and serves UI + API on one port with relative URLs.

## What to rebuild before deploying
- **Frontend image** — build from this repo's `server.js` + `public/` (a minimal
  `node:20` image: copy the app, `npm install --omit=dev`, `CMD node server.js`).
- **Backend** — a stock `postgres` image **plus the `stops` schema**. The old baked
  `todo-db` image provisioned the *`todos`* table, which no longer exists; apply the
  `stops` table from `backend.yml` via an init script / ConfigMap or a one-off `psql`.
- **Manifests** — Deployment + Service for each tier, a PVC for Postgres, and a **Route**
  for the frontend. Name them `wandering-workload` (the old manifests used `todo-web`).
  Keep the DB Service named **`wandering-db`** so `DB_HOST=wandering-db` keeps resolving.

## Where you're going
```
Browser ── Route ──> wandering-workload (Deployment/Service) ──> wandering-db (Deployment/Service + PVC)
```

## Steps (live-demo runbook; doing a few by hand is fine)

### 1. Log in and pick a namespace
```bash
oc login ...
oc new-project wandering-workload
```

### 2. Build the frontend image from this repo
```bash
oc new-build --name wandering-workload --binary --strategy docker   # needs a Dockerfile
oc start-build wandering-workload --from-dir=.. --follow
```
(Recreate a `Dockerfile` first — see the archived backup for the previous one.)

### 3. Deploy both tiers
Apply your rebuilt manifests (Deployments + Services + PVC + Route). The frontend's
`DB_HOST=wandering-db` resolves to the database Service automatically — same name as on the VMs.

### 4. Migrate the data (VM Postgres → container Postgres)
The container DB starts empty. Copy the data across:
```bash
# On the backend VM, dump data only (schema is applied separately):
pg_dump -U todo -d todo --data-only > /tmp/stops.sql

# Load it into the containerised Postgres (after the stops table exists):
oc cp /tmp/stops.sql deploy/wandering-db:/tmp/stops.sql
oc exec deploy/wandering-db -- bash -lc 'psql -U todo -d todo -f /tmp/stops.sql'
```

### 5. Swap ingress to an OpenShift Route
```bash
oc get route wandering-workload -o jsonpath='{.spec.host}{"\n"}'
```
Open that URL — the app is now served via an OpenShift Route.

### 6. Verify and decommission the VMs
```bash
oc get pods                       # wandering-db + wandering-workload Running
curl -s https://$(oc get route wandering-workload -o jsonpath='{.spec.host}')/health
```
Once the containerised app serves and the data checks out, stop and delete the KubeVirt VMs.

---

## Why this is smooth
- **Same DB name end to end** (`wandering-db`) — no app reconfiguration, ever.
- **Persistence handled by the platform** — the Postgres PVC replaces the VM disk.
- **Ingress is the only real swap** — the VM's direct port becomes an OpenShift Route.

## Nice-to-haves
- Move `DB_PASSWORD` from a plain env var into a `Secret`.
- Add resource requests/limits and an HPA if needed.
- Wire a gitops folder into Argo CD / OpenShift GitOps for continuous deployment.
