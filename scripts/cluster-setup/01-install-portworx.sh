#!/usr/bin/env bash
#
# prep_portworx.sh — upgrade Portworx operator + StorageCluster to EA builds,
# configure LoadBalancer annotation, grant stork cluster-admin, and activate
# the SaaS license. Loops through all spoke clusters automatically.
#
set -euo pipefail

NAMESPACE="portworx"

PX_LICENSE_KEY="${PX_LICENSE_KEY:?ERROR: PX_LICENSE_KEY not set in credentials.env}"

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
printf '\033[1;33m#  \033[1;97mprep_portworx.sh — Portworx EA upgrade on ALL spokes\033[0m\n'
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

    # --- Discover StorageCluster ---
    PX_CLUSTER=$(oc get storagecluster -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "${PX_CLUSTER}" ]]; then
        printf '\033[0;31m  !! No StorageCluster in %s — skipping %s\033[0m\n' "${NAMESPACE}" "${SPOKE}"
        (( failed++ )); failed_list+=("${SPOKE}")
        continue
    fi
    echo "  Found StorageCluster: ${PX_CLUSTER}"

    echo "  >> [1/6] Patching portworx-operator CSV to 26.3.0-ea..."
    oc patch csv portworx-operator.v26.2.1 \
      -n "${NAMESPACE}" \
      --type=json \
      -p '[{"op":"replace","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image","value":"docker.io/portworx/px-operator:26.3.0-ea"}]' 2>&1 || true

    echo "  >> [2/6] Patching StorageCluster OCP dynamic plugin images..."
    oc patch storagecluster "${PX_CLUSTER}" \
      -n "${NAMESPACE}" \
      --type=merge \
      -p '{"spec": {"ocpDynamicPlugin": {"cacheAgentImage": "docker.io/portworx/px-cache-agent:1.1.0-ea", "pluginImage": "docker.io/portworx/portworx-dynamic-plugin:2.3.0-ea"}}}' 2>&1 || true

    echo "  >> [3/6] Annotating StorageCluster with LoadBalancer service type..."
    oc patch storagecluster "${PX_CLUSTER}" \
      -n "${NAMESPACE}" \
      --type=json \
      -p '[{"op": "add", "path": "/metadata/annotations/portworx.io~1service-type", "value": "portworx-api:LoadBalancer"}]' 2>&1 || true

    echo "  >> [4/6] Creating stork cluster-admin ClusterRoleBinding..."
    oc create clusterrolebinding stork-cluster-admin \
      --clusterrole=cluster-admin \
      --serviceaccount="${NAMESPACE}:stork" \
      --dry-run=client -o yaml | oc apply -f - 2>&1

    # ROSA: Stork admin-namespace must be 'portworx' to avoid the managed namespace webhook
    # blocking MigrationSchedules in kube-system. No-op on other clusters (harmless).
    if [[ "${SPOKE}" == "ROSA" ]]; then
        echo "  >> [5/6] Setting Stork admin-namespace to portworx (ROSA webhook workaround)..."
        oc patch storagecluster "${PX_CLUSTER}" \
          -n "${NAMESPACE}" \
          --type=merge \
          -p '{"spec":{"stork":{"args":{"admin-namespace":"portworx"}}}}' 2>&1 || true
    fi

    echo "  >> [6/6] Activating Portworx SaaS license..."
    PX_POD=$(oc get pods -n "${NAMESPACE}" -l name=portworx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${PX_POD}" ]]; then
        oc exec -n "${NAMESPACE}" "${PX_POD}" -c portworx -- \
          /opt/pwx/bin/pxctl license activate saas --key "${PX_LICENSE_KEY}" 2>&1 || true
    else
        printf '\033[0;33m  !! No portworx pod found — license activation skipped\033[0m\n'
    fi

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
