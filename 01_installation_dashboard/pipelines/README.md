# Build System — OpenShift Pipelines

Builds the wandering-workload app, Alpine golden VM image, and loadbalancer
container on OpenShift using Tekton Pipelines.

## Prerequisites

- [ ] OpenShift cluster with admin access
- [ ] OpenShift Pipelines operator installed (OperatorHub → Red Hat OpenShift Pipelines)
- [ ] `oc` CLI logged in

## 1. Bootstrap (one-time)

```bash
cd 07_build
./setup.sh
```

Creates the namespace, applies Tekton resources, and builds the builder image.

## 2. Run the full pipeline

Edit `tekton/pipelinerun.yml` — set `git-url` to your repo. Then:

```bash
oc create -f 07_build/tekton/pipelinerun.yml
tkn pipelinerun logs -f -L
```

## 3. Download the artifacts

```bash
oc get route golden-artifacts -n wandering-build -o jsonpath='{.spec.host}'
curl -Ok https://<route>/wandering_alpine.vmdk
```

## Re-running individual tasks

Every task is independent. If one fails, fix your code, push, and re-run
just that task — no need to re-run the whole pipeline.

**Dependencies:**
```
clone ← build-app ← build-golden-vm ← deploy-artifact-server
clone ← build-loadbalancer
```

Re-clone (picks up your latest code):
```bash
tkn task start git-clone \
    -p url=YOUR_GIT_REPO_URL \
    -w name=output,claimName=wandering-build-workspace \
    --showlog
```

Re-run the app build only:
```bash
tkn task start build-wandering-app \
    -w name=source,claimName=wandering-build-workspace \
    --showlog
```

Re-run the golden VM build only:
```bash
tkn task start build-golden-vm \
    -w name=source,claimName=wandering-build-workspace \
    -w name=artifacts,claimName=golden-artifacts \
    --showlog
```

Re-run the loadbalancer build only:
```bash
tkn task start build-loadbalancer \
    -w name=source,claimName=wandering-build-workspace \
    --showlog
```

Re-deploy the artifact server only:
```bash
tkn task start deploy-artifact-server \
    -w name=artifacts,claimName=golden-artifacts \
    --showlog
```

The workspace PVCs persist between runs, so data from earlier tasks is still
there. If you changed code, re-clone first, then re-run the task that failed.

## Webhook (auto-trigger on push)

Bootstrap creates a Tekton EventListener. To wire it up to GitHub:

```bash
# Get the listener URL
oc get route el-wandering-build-listener -n wandering-build -o jsonpath='{.spec.host}'
```

Add that URL as a webhook in your GitHub repo settings
(Settings → Webhooks → `https://<listener-route>/`, content type `application/json`,
trigger on `push` events).

After that, every `git push` triggers a full pipeline run automatically.

---

## Troubleshooting

**QEMU fails in build pod** — The `pipeline` ServiceAccount may need the
privileged SCC:
```bash
oc adm policy add-scc-to-user privileged -z pipeline -n wandering-build
```

**Entitled build failures** — The builder image needs RHEL repos. OpenShift
build pods inherit node entitlements automatically. If you see subscription
errors, check your node subscriptions.
