# Modernising the Wandering Workload — the demo story

## The situation

We've already moved the app off VMware and onto OpenShift on ARO. It's running, it's stable, and the users are on it right now at its public address. But it's running exactly as it did before — two virtual machines, a web tier and a database tier, lifted across as-is.

That migration bought us the platform. It didn't change the app. To actually *benefit* from OpenShift — faster builds, smaller footprint, self-healing, no servers to patch — we need to take the next step and turn these VMs into containers.

*The migration was the on-ramp. This is where we start driving.*

## What we're going to do

We're not going to flip a switch and pray. We'll modernise one tier at a time, keep the app live throughout, and make every step reversible.

1. Rebuild the **web tier** as a container, straight from our source code.
2. Prove it works while the original is still running, then move traffic to it and switch the old VM off.
3. Do the same for the **database**, carrying its data across safely.

If anything looks wrong at any point, we step back — the old VM is still there, switched off, not thrown away.

## What we did — the web tier

The web app's code is in Git, so we didn't drag its old disk along. We pointed OpenShift at the repository and let it **build a fresh, clean container image for us** — no Dockerfile to write, no rewrite of the app.

```
oc -n wandering-workload new-app \
  nodejs:20-ubi9~https://github.com/<your-org>/wandering_workload.git \
  --name=wandering-front-app \
  -e DB_HOST=wandering-backend-svc -e DB_USER=todo -e DB_NAME=todo
oc -n wandering-workload create secret generic wandering-db-cred --from-literal=DB_PASSWORD=todo
oc -n wandering-workload set env deploy/wandering-front-app --from=secret/wandering-db-cred
```

*Minutes, not a project. And the result is a slim, modern image — not a forklifted server.*

Then we gave it a private test door and checked it against the **live database** before risking anything:

```
oc -n wandering-workload create route edge wandering-front-test --service=wandering-front-app --port=8080
```

It came up healthy and showed the same data as the running app. Now we had both versions side by side — old and new, reading the same source of truth. *No leap of faith required.*

Happy with it, we moved the real traffic over and switched the old web VM off:

```
oc -n wandering-workload patch route wandering --type=merge \
  -p '{"spec":{"to":{"name":"wandering-front-app"},"port":{"targetPort":8080}}}'
oc -n wandering-workload patch vm wandering-front --type=merge -p '{"spec":{"running":false}}'
```

Same address, same experience for the user — now served by a container. *Zero downtime, and the VM is parked, not deleted, so undo is instant.*

## What we did — the database

The web tier was the easy half because it holds no state. The database is the opposite: the value *is* the data, so the careful work is moving that data onto modern, platform-managed storage — not building the container.

So we stood up a fresh PostgreSQL on a proper persistent volume, and while the old database kept serving, we copied everything across into it:

```
oc -n wandering-workload new-app --template=postgresql-persistent \
  -p DATABASE_SERVICE_NAME=wandering-pg \
  -p POSTGRESQL_USER=todo -p POSTGRESQL_PASSWORD=todo -p POSTGRESQL_DATABASE=todo \
  -p VOLUME_CAPACITY=1Gi
# copy the data from the old DB into the new one (runs unattended)
oc -n wandering-workload create job pg-sync --image=registry.redhat.io/rhel9/postgresql-15 -- \
  bash -c 'pg_dump "postgresql://todo:todo@wandering-backend-svc:5432/todo" | psql "postgresql://todo:todo@wandering-pg:5432/todo"'
```

Then we pointed the app at the new database — **without reconfiguring the app at all** — confirmed it was healthy, and switched off the last VM:

```
oc -n wandering-workload patch svc wandering-backend-svc --type=merge -p '{"spec":{"selector":{"name":"wandering-pg"}}}'
oc -n wandering-workload patch vm wandering-db --type=merge -p '{"spec":{"running":false}}'
```

*The data made the journey intact, and the application never knew the ground moved under it.*

## Why we did it this way

- **One tier at a time** — so a problem is small, obvious, and contained, never a big-bang outage.
- **Rebuilt the web tier from source** rather than wrapping its old disk — that's *real* modernisation: a small, clean image, not a VM in a costume.
- **Proved the new before retiring the old**, every time — old and new ran together until we trusted the new one.
- **Stopped the VMs, didn't delete them** — rollback stayed one command away the whole way through.
- **Treated the data as precious** — copied it deliberately into managed storage while the source stayed safely online.

*Modernisation without a maintenance window, and without a single risky moment where we couldn't go back.*

## Recap

We started with a working-but-unchanged lift-and-shift: two VMs doing things the old way. We rebuilt the web tier into a clean container from our own code, moved its data-tier sibling onto modern managed storage, and retired both VMs — all while the app stayed live at the same address for our users.

The workload has now made its full journey: **VMware → ARO virtual machine → cloud-native container**, on one platform, with nothing lost and nothing offline. The last leg is the most valuable one — and we can record it right inside the app, as the workload's newest stop on the map.
