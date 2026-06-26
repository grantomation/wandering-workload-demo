#!/usr/bin/env bash
#
# prep_spoke_cluster_permissions.sh — Grant ACM hub visibility into KubeVirt
# VMs, configure Portworx/Stork RBAC, and clean up golden images. Loops
# through all spoke clusters automatically.
#
# Idempotent; safe to re-run.
#
set -euo pipefail

# --- Load credentials ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# --- Spoke cluster definitions (parallel arrays — bash 3.x safe) ---
SPOKE_NAMES=(  "ARO"         "ROSA"        "OSD"           "ON-PREM"     )
SPOKE_LABELS=( "ARO Spoke 1" "ROSA Spoke 1" "OSD on GCP"   "On-Premise"  )
SPOKE_USERS=(  "$ARO_USER"   "$ROSA_USER"   "$GCP_USER"    "$ONPREM_USER" )
SPOKE_PASSES=( "$ARO_PASS"   "$ROSA_PASS"   "$GCP_PASS"    "$ONPREM_PASS" )
SPOKE_APIS=(   "$ARO_API"    "$ROSA_API"    "$GCP_API"     "$ONPREM_API"  )

printf '\n'
printf '\033[1;33m######################################################################\033[0m\n'
printf '\033[1;33m#  \033[1;97mprep_spoke_cluster_permissions.sh — RBAC + cleanup on ALL spokes\033[0m\n'
printf '\033[1;33m#  \033[0;37mClusters: %s\033[0m\n' "${SPOKE_NAMES[*]}"
printf '\033[1;33m######################################################################\033[0m\n'
printf '\n'
read -r -p "Run on all ${#SPOKE_NAMES[@]} spoke clusters? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

succeeded=0
failed=0
failed_list=()

for i in "${!SPOKE_NAMES[@]}"; do
    SPOKE="${SPOKE_NAMES[$i]}"
    LABEL="${SPOKE_LABELS[$i]}"
    API="${SPOKE_APIS[$i]}"

    printf '\n'
    printf '\033[1;36m======================================================================\033[0m\n'
    printf '\033[1;36m  %s  (%s)\033[0m\n' "${LABEL}" "${API}"
    printf '\033[1;36m======================================================================\033[0m\n'

    if ! oc login -u "${SPOKE_USERS[$i]}" -p "${SPOKE_PASSES[$i]}" \
        "${API}" --insecure-skip-tls-verify=true >/dev/null 2>&1; then
        printf '\033[0;31m  !! Login failed — skipping %s\033[0m\n' "${SPOKE}"
        (( failed++ )); failed_list+=("${SPOKE}")
        continue
    fi

    CLUSTER_NAME="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo 'unknown')"
    printf '  Cluster: %s\n\n' "${CLUSTER_NAME}"

    echo "  >> [1/8] cluster-reader for standard resources (PVCs, pods, services, etc.)"
    oc adm policy add-cluster-role-to-user cluster-reader admin 2>&1 || true

    echo "  >> [2/8] KubeVirt admin (VM listing, console, start/stop/restart)"
    oc apply -f - <<'EOF'
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

    echo "  >> [3/8] Disable common boot image import + clean up golden images"
    oc patch hco kubevirt-hyperconverged -n openshift-cnv --type=merge \
      -p '{"spec":{"enableCommonBootImageImport":false}}' 2>&1 || true
    oc scale deployment ssp-operator -n openshift-cnv --replicas=0 2>&1 || true
    oc delete datavolume --all -n openshift-virtualization-os-images 2>&1 || true
    oc delete datasource --all -n openshift-virtualization-os-images 2>&1 || true
    oc delete dataimportcron --all -n openshift-virtualization-os-images 2>&1 || true
    oc delete pvc --all -n openshift-virtualization-os-images 2>&1 || true

    echo "  >> [4/8] Grant portworx ClusterRole full access"
    oc patch clusterrole portworx --type='json' \
      -p='[{"op":"replace","path":"/rules","value":[{"apiGroups":["*"],"resources":["*"],"verbs":["*"]}]}]' 2>&1 || true

    echo "  >> [5/8] Create portworx-wildcard ClusterRole + binding for px-account"
    oc create clusterrole portworx-wildcard --verb='*' --resource='*.*' \
      --dry-run=client -o yaml | oc apply -f - 2>&1
    oc create clusterrolebinding portworx-wildcard --clusterrole=portworx-wildcard \
      --serviceaccount=portworx:px-account \
      --dry-run=client -o yaml | oc apply -f - 2>&1

    echo "  >> [6/8] Grant stork cluster-admin (required for DR failover)"
    oc create clusterrolebinding stork-cluster-admin \
      --clusterrole=cluster-admin \
      --serviceaccount=portworx:stork \
      --dry-run=client -o yaml | oc apply -f - 2>&1

    echo "  >> [7/8] Clear events in portworx namespace"
    oc delete events --all -n portworx 2>&1 || true

    echo "  >> [8/8] Scale SSP operator back up"
    oc scale deployment ssp-operator -n openshift-cnv --replicas=1 2>&1 || true

    printf '\033[0;32m  >> Done on %s\033[0m\n' "${LABEL}"
    (( succeeded++ ))
done

echo
printf '\033[1;33m######################################################################\033[0m\n'
printf '\033[1;32m  Succeeded: %d\033[0m\n' "${succeeded}"
if [[ ${failed} -gt 0 ]]; then
    printf '\033[1;31m  Failed:    %d  (%s)\033[0m\n' "${failed}" "${failed_list[*]}"
fi
printf '\033[1;33m######################################################################\033[0m\n'
