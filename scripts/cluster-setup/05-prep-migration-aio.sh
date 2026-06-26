#!/usr/bin/env bash
#
# prep_aio.sh — demo-day pre-seed for the all-in-one Wandering Workload migration
# (VMware -> ARO via MTV). One VM runs both the Node app and Postgres, so the app
# talks to its own LOCAL database — there is NO backend Service. Run ONCE before
# starting the migration. It creates, from scratch:
#   - target project + forklift permissions
#   - frontend Service + Route          (external ingress only; DB is local)
#   - NetworkMap + StorageMap + the migration Plan
# Then start the migration with the "Start" button in the MTV UI.
#
# NOTE: there is currently no 'wandering_aio' VM in the vmware inventory, so the
# plan won't validate until such a source VM exists. The script is kept ready for
# when it does.
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
printf '\033[1;33m#  \033[0;36mScript: \033[0;37m%s\033[0m\n' "prep_aio.sh (all-in-one VMware -> ARO migration pre-seed)"
printf '\033[1;33m#\033[0m\n'
printf '\033[1;33m######################################################################\033[0m\n'
printf '\n'
read -r -p "Proceed on this cluster? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo

PROJECT="${PROJECT:-wandering-workload}"   # target namespace (editable)
MTV_NS="openshift-mtv"                      # where the provider/maps/plan live

# Source vSphere VM name (as it appears in the vmware provider inventory).
# Forklift resolves this to a MoID at validation time, so no vm-xxxx needed.
# (Only pin a MoID if two source VMs share a name — see the 'vms:' note below.)
AIO_VM_NAME="wandering_aio"

echo ">> [1/3] Project + forklift permissions + KubeVirt RBAC: ${PROJECT}"
oc apply -f - <<EOF
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  name: ${PROJECT}
EOF
oc adm policy add-role-to-user edit system:serviceaccount:${MTV_NS}:forklift-controller -n ${PROJECT}
oc adm policy add-scc-to-user privileged system:serviceaccount:${MTV_NS}:forklift-controller -n ${PROJECT}

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

echo ">> [2/3] Frontend Service + Route: ${PROJECT}  (no backend Service — DB is local)"
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: wandering-frontend-svc
  namespace: ${PROJECT}
spec:
  selector:
    app: ${AIO_VM_NAME//_/-}
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
EOF

echo ">> [3/3] NetworkMap + StorageMap + Plan: ${MTV_NS}"
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: NetworkMap
metadata:
  name: vmware-to-aro-aio-net
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
        id: <dvportgroup-id>    # vSphere distributed port group MoID — find via MTV inventory or: govc ls -L /datacenter/network
      destination:
        type: pod
---
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: vmware-to-aro-aio-storage
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
        id: <datastore-id>      # vSphere datastore MoID — find via MTV inventory or: govc ls -L /datacenter/datastore
      destination:
        storageClass: px-csi-replicated
---
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: vmware-to-aro-aio
  namespace: ${MTV_NS}
spec:
  description: Wandering Workload all-in-one (VMware -> ARO)
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
      name: vmware-to-aro-aio-net
      namespace: ${MTV_NS}
    storage:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: StorageMap
      name: vmware-to-aro-aio-storage
      namespace: ${MTV_NS}
  vms:
    # Referenced by name (resolved from inventory). If a name is ambiguous,
    # add 'id: vm-xxxx' on the same entry to disambiguate.
    - name: ${AIO_VM_NAME}
EOF

cat <<MSG

>> Done. Pre-seed complete for project '${PROJECT}'.
   Start the migration with the "Start" button on Plan 'vmware-to-aro-aio' in the
   MTV UI, or from the CLI:

     oc create -f - <<EOM
     apiVersion: forklift.konveyor.io/v1beta1
     kind: Migration
     metadata:
       name: vmware-to-aro-aio-run
       namespace: ${MTV_NS}
     spec:
       plan:
         name: vmware-to-aro-aio
         namespace: ${MTV_NS}
     EOM
MSG
