#!/usr/bin/env bash
#
# prep_2tier.sh — demo-day pre-seed for the 2-tier Wandering Workload migration
# (VMware -> MTV cluster). Run ONCE before starting the migration. It creates,
# from scratch:
#   - target project + forklift permissions
#   - backend Service, frontend Service, Route   (so the FE finds the DB at once)
#   - NetworkMap + StorageMap + the migration Plan
# Then start the migration with the "Start" button in the MTV UI (or see the
# commented Migration block at the bottom).
#
# No pre-hook: the Services exist before the VMs boot because you run this first.
#
set -euo pipefail

# --- Cluster identity check ---
if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: not logged in. Run: oc login --token=<token> --server=<api>" >&2
    exit 1
fi
CLUSTER_API="$(oc whoami --show-server)"
CLUSTER_USER="$(oc whoami)"
CLUSTER_NAME="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo 'unknown')"
CLUSTER_PLATFORM="$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || echo '')"

printf '\n'
printf '\033[1;33m######################################################################\033[0m\n'
printf '\033[1;33m#\033[0m\n'
printf '\033[1;33m#  \033[1;97m%s\033[0m\n' "${CLUSTER_NAME}  (${CLUSTER_PLATFORM})"
printf '\033[1;33m#  \033[0;37m%s\033[0m\n' "${CLUSTER_API}"
printf '\033[1;33m#\033[0m\n'
printf '\033[1;33m#  \033[0;36mUser:   \033[0;37m%s\033[0m\n' "${CLUSTER_USER}"
printf '\033[1;33m#  \033[0;36mScript: \033[0;37m%s\033[0m\n' "prep_2tier.sh (VMware -> MTV cluster migration pre-seed)"
printf '\033[1;33m#\033[0m\n'
printf '\033[1;33m######################################################################\033[0m\n'
printf '\n'
read -r -p "Proceed on this cluster? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo

PROJECT="${PROJECT:-wandering-workload}"   # target namespace (editable)
MTV_NS="openshift-mtv"                      # where the provider/maps/plan live

# Source vSphere VM names (as they appear in the vmware provider inventory).
# Forklift resolves these to MoIDs at validation time, so no vm-xxxx needed.
# (Only pin a MoID if two source VMs share a name — see the 'vms:' note below.)
FE_VM_NAME="wandering-front"
BE_VM_NAME="wandering-db"

# Fail BEFORE creating the Plan if a source VM name does not exist in the
# vmware provider inventory — that exact mismatch is what produces the
# "VMNotFound" critical error and blocks the plan from starting.
validate_vm_names() {
    local inv token puid vms rc=0 want
    inv="$(oc get route forklift-inventory -n "${MTV_NS}" -o jsonpath='{.spec.host}' 2>/dev/null)"
    token="$(oc whoami -t 2>/dev/null)"
    puid="$(oc get providers.forklift.konveyor.io vmware -n "${MTV_NS}" -o jsonpath='{.metadata.uid}' 2>/dev/null)"
    if [ -z "${inv}" ] || [ -z "${puid}" ]; then
        echo "WARN: could not reach forklift inventory (route/provider missing); skipping name pre-check."
        return 0
    fi
    vms="$(curl -sk -H "Authorization: Bearer ${token}" \
        "https://${inv}/providers/vsphere/${puid}/vms?detail=1" 2>/dev/null \
        | python3 -c 'import sys,json; print("\n".join(v.get("name","") for v in json.load(sys.stdin)))' 2>/dev/null)"
    if [ -z "${vms}" ]; then
        echo "WARN: inventory returned no VMs (not loaded yet?); skipping name pre-check."
        return 0
    fi
    for want in "$@"; do
        if ! grep -qxF "${want}" <<<"${vms}"; then
            echo "ERROR: source VM '${want}' not found in vmware inventory."
            echo "       Closest matches:"
            grep -i "${want%%-*}" <<<"${vms}" | sed 's/^/         - /' || true
            rc=1
        else
            echo "  ok: '${want}' found in inventory."
        fi
    done
    return ${rc}
}

echo ">> [1/3] Project + forklift permissions + KubeVirt RBAC: ${PROJECT}"
oc apply -f - <<EOF
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  name: ${PROJECT}
EOF
oc adm policy add-role-to-user edit system:serviceaccount:${MTV_NS}:forklift-controller -n ${PROJECT}
oc adm policy add-scc-to-user privileged system:serviceaccount:${MTV_NS}:forklift-controller -n ${PROJECT}
oc policy add-role-to-group system:image-puller system:serviceaccounts:${PROJECT} -n ${MTV_NS}

# Grant the admin user cluster-reader for standard resources (PVCs, pods, services, etc.)
oc adm policy add-cluster-role-to-user cluster-reader admin

# Grant the admin user full access to KubeVirt resources (ACM hub VM listing + console)
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubevirt-admin
rules:
  - apiGroups: ["kubevirt.io"]
    resources:
      - virtualmachines
      - virtualmachineinstances
      - virtualmachineinstancemigrations
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["subresources.kubevirt.io"]
    resources:
      - virtualmachines/start
      - virtualmachines/stop
      - virtualmachines/restart
      - virtualmachineinstances/vnc
      - virtualmachineinstances/console
      - virtualmachineinstances/pause
      - virtualmachineinstances/unpause
    verbs: ["get", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-kubevirt-admin
subjects:
  - kind: User
    name: admin
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: kubevirt-admin
  apiGroup: rbac.authorization.k8s.io
EOF

echo ">> [2/3] Backend Service + Frontend Service + Route: ${PROJECT}"
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: wandering-backend-svc
  namespace: ${PROJECT}
spec:
  selector:
    app: ${BE_VM_NAME//_/-}
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: wandering-frontend-svc
  namespace: ${PROJECT}
spec:
  selector:
    app: ${FE_VM_NAME//_/-}
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: wandering
  namespace: ${PROJECT}
spec:
  subdomain: wandering
  to:
    kind: Service
    name: wandering-frontend-svc
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: wandering-aro
  namespace: ${PROJECT}
spec:
  host: wandering.apps.<aro-cluster>.<region>.aroapp.io           # replace with your ARO cluster's apps domain
  to:
    kind: Service
    name: wandering-frontend-svc
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: wandering-rosa
  namespace: ${PROJECT}
spec:
  host: wandering.apps.<rosa-cluster>.<id>.p3.openshiftapps.com   # replace with your ROSA cluster's apps domain
  to:
    kind: Service
    name: wandering-frontend-svc
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: wandering-gcp
  namespace: ${PROJECT}
spec:
  host: wandering.apps.<gcp-cluster>.<id>.p2.openshiftapps.com    # replace with your GCP cluster's apps domain
  to:
    kind: Service
    name: wandering-frontend-svc
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: wandering-onprem
  namespace: ${PROJECT}
spec:
  host: wandering.apps.<onprem-cluster>.<domain>                  # replace with your on-prem cluster's apps domain
  to:
    kind: Service
    name: wandering-frontend-svc
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

echo ">> [pre-flight] validating source VM names against vmware inventory"
validate_vm_names "${FE_VM_NAME}" "${BE_VM_NAME}"

if [ -z "${PLAN_NAME:-}" ]; then
    read -r -p "Migration Plan name [vmware-to-on-prem]: " PLAN_NAME
    PLAN_NAME="${PLAN_NAME:-vmware-to-on-prem}"
fi
if [ -z "${NET_MAP_NAME:-}" ]; then
    read -r -p "NetworkMap name [vmware-to-virt-default]: " NET_MAP_NAME
    NET_MAP_NAME="${NET_MAP_NAME:-vmware-to-virt-default}"
fi
if [ -z "${STOR_MAP_NAME:-}" ]; then
    read -r -p "StorageMap name [vmware-to-portworx]: " STOR_MAP_NAME
    STOR_MAP_NAME="${STOR_MAP_NAME:-vmware-to-portworx}"
fi

CREATED=()
SKIPPED=()

echo ">> [3/3] NetworkMap + StorageMap + Plan: ${MTV_NS}"

if oc get networkmaps.forklift.konveyor.io -n "${MTV_NS}" 2>/dev/null | grep -q .; then
    echo "  skip: NetworkMap(s) already exist in ${MTV_NS}"
    SKIPPED+=("NetworkMap")
else
    echo "  creating NetworkMap: ${NET_MAP_NAME}"
    CREATED+=("NetworkMap/${NET_MAP_NAME}")
    oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: NetworkMap
metadata:
  name: ${NET_MAP_NAME}
  namespace: ${MTV_NS}
spec:
  provider:
    source:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: Provider
      name: vmware
      namespace: ${MTV_NS}
    destination:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: Provider
      name: host
      namespace: ${MTV_NS}
  map:
    - source:
        name: <vsphere-network-segment>    # vSphere network segment name — find via: govc ls /datacenter/network
      destination:
        type: pod
EOF
fi

if oc get storagemaps.forklift.konveyor.io -n "${MTV_NS}" 2>/dev/null | grep -q .; then
    echo "  skip: StorageMap(s) already exist in ${MTV_NS}"
    SKIPPED+=("StorageMap")
else
    echo "  creating StorageMap: ${STOR_MAP_NAME}"
    CREATED+=("StorageMap/${STOR_MAP_NAME}")
    oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: ${STOR_MAP_NAME}
  namespace: ${MTV_NS}
spec:
  provider:
    source:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: Provider
      name: vmware
      namespace: ${MTV_NS}
    destination:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: Provider
      name: host
      namespace: ${MTV_NS}
  map:
    - source:
        name: <vsphere-datastore>          # vSphere datastore name — find via: govc ls /datacenter/datastore
      destination:
        storageClass: px-csi-replicated
EOF
fi

if oc get plans.forklift.konveyor.io -n "${MTV_NS}" 2>/dev/null | grep -q .; then
    echo "  skip: Plan(s) already exist in ${MTV_NS}"
    SKIPPED+=("Plan")
else
    echo "  creating Plan: ${PLAN_NAME}"
    CREATED+=("Plan/${PLAN_NAME}")
    oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: ${PLAN_NAME}
  namespace: ${MTV_NS}
spec:
  description: "Wandering Workload 2-tier (VMware -> ${PLAN_NAME#vmware-to-})"
  type: cold
  warm: false
  targetNamespace: ${PROJECT}
  targetPowerState: auto
  skipGuestConversion: true
  migrateSharedDisks: true
  useCompatibilityMode: true
  deleteVmOnFailMigration: true
  preserveStaticIPs: false
  xfsCompatibility: false
  pvcNameTemplateUseGenerateName: true
  runPreflightInspection: true
  provider:
    source:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: Provider
      name: vmware
      namespace: ${MTV_NS}
    destination:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: Provider
      name: host
      namespace: ${MTV_NS}
  map:
    network:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: NetworkMap
      name: ${NET_MAP_NAME}
      namespace: ${MTV_NS}
    storage:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: StorageMap
      name: ${STOR_MAP_NAME}
      namespace: ${MTV_NS}
  vms:
    - name: ${FE_VM_NAME}
    - name: ${BE_VM_NAME}
EOF
fi

printf '\n'
printf '\033[1;32m>> Done. Pre-seed complete for project '\''%s'\''.\033[0m\n' "${PROJECT}"
printf '\n'
if [ ${#CREATED[@]} -gt 0 ]; then
    printf '\033[1;32m  Created:\033[0m\n'
    for r in "${CREATED[@]}"; do printf '    + %s\n' "$r"; done
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
    printf '\033[1;33m  Skipped (already exist):\033[0m\n'
    for r in "${SKIPPED[@]}"; do printf '    - %s\n' "$r"; done
fi
printf '\n'
printf '  Project:           %s\n' "${PROJECT}"
printf '  Forklift RBAC:     edit + privileged + image-puller\n'
printf '  Services/Routes:   wandering-backend-svc, wandering-frontend-svc, wandering\n'
printf '\n'

EXISTING_PLAN="$(oc get plans.forklift.konveyor.io -n "${MTV_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${EXISTING_PLAN}" ]; then
cat <<MSG
  Start the migration with the "Start" button on Plan '${EXISTING_PLAN}' in the
  MTV UI, or from the CLI:

    oc create -f - <<EOM
    apiVersion: forklift.konveyor.io/v1beta1
    kind: Migration
    metadata:
      name: ${EXISTING_PLAN}-run
      namespace: ${MTV_NS}
    spec:
      plan:
        name: ${EXISTING_PLAN}
        namespace: ${MTV_NS}
    EOM
MSG
fi
