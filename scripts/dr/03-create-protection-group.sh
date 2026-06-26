#!/usr/bin/env bash
#
# 03-create-protection-group.sh — create a single ProtectionGroup on the hub.
#
# Usage (argument is the DR pair NAME; the PG keeps its numbered name):
#   ./scripts/dr/03-create-protection-group.sh on-prem-aro   # PG 01-on-prem-to-aro
#   ./scripts/dr/03-create-protection-group.sh aro-rosa      # PG 02-aro-to-rosa
#   ./scripts/dr/03-create-protection-group.sh rosa-gcp      # PG 03-rosa-to-gcp
#   ./scripts/dr/03-create-protection-group.sh gcp-on-prem   # PG 04-gcp-to-on-prem (pre-cleans wandering-workload on on-prem first)
#
# Add --yes to skip the destination-pre-clean confirmation (gcp-on-prem only).
#
set -euo pipefail

NAMESPACE="portworx"
API_GROUP="multicluster.portworx.com"
PG_RESOURCE="protectiongroups.${API_GROUP}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Protection group definitions ---
PG_NAMES=(  "01-on-prem-to-aro" "02-aro-to-rosa" "03-rosa-to-gcp" "04-gcp-to-on-prem" )
PG_DRPAIRS=( "on-prem-aro"       "aro-rosa"        "rosa-gcp"       "gcp-on-prem"       )
PG_LABELS=(  "on-prem -> aro"    "aro -> rosa"     "rosa -> gcp"    "gcp -> on-prem"    )

usage() {
    echo "Usage: $(basename "$0") <on-prem-aro|aro-rosa|rosa-gcp|gcp-on-prem> [--yes]"
    echo
    echo "  (argument is the DR pair name; the PG keeps its numbered name)"
    for i in "${!PG_DRPAIRS[@]}"; do
        printf '    %-12s %-15s -> PG %s\n' "${PG_DRPAIRS[$i]}" "${PG_LABELS[$i]}" "${PG_NAMES[$i]}"
    done
    echo
    echo "  gcp-on-prem first DELETES VMs/PVCs in wandering-workload on on-prem"
    echo "  (round-trip needs the px volume names free). --yes skips the prompt."
    echo "  NOTE: ACM cluster name is 'gcp' (not 'osd')"
    exit 1
}

ASSUME_YES=false
PAIR_ARG=""
for a in "$@"; do
    case "$a" in
        --yes|-y) ASSUME_YES=true ;;
        -*)       usage ;;
        *)        PAIR_ARG="$a" ;;
    esac
done
[[ -n "${PAIR_ARG}" ]] || usage

# Map the DR pair name (arg) -> index into the definition arrays.
idx=-1
for i in "${!PG_DRPAIRS[@]}"; do
    [[ "${PG_DRPAIRS[$i]}" == "${PAIR_ARG}" ]] && { idx=$i; break; }
done
[[ "${idx}" -ge 0 ]] || usage

PG_NAME="${PG_NAMES[$idx]}"
PG_PAIR="${PG_DRPAIRS[$idx]}"
PG_LABEL="${PG_LABELS[$idx]}"

# --- Load credentials ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

hub_login() {
    login_cluster hub
}

login_spoke() {
    login_cluster "$1"
}

# Clear all VMs/PVCs from <ns> on a destination cluster so a round-trip restore
# won't collide on Portworx volume names (DR preserves them end-to-end).
preclean_destination() {
    local dst="$1" ns="$2"
    printf '\n\033[1;31m######################################################################\033[0m\n'
    printf '\033[1;31m#  PRE-CLEAN destination %s — deleting VMs/PVCs in ns %s\033[0m\n' "$dst" "$ns"
    printf '\033[1;31m#  (Portworx preserves volume names; the restore needs them free)\033[0m\n'
    printf '\033[1;31m######################################################################\033[0m\n'
    login_spoke "$dst"
    oc get vm,pvc -n "$ns" --no-headers 2>/dev/null | sed 's/^/    /' || true
    if ! ${ASSUME_YES}; then
        read -r -p "Delete ALL VMs/VMIs/DataVolumes/PVCs in '${ns}' on ${dst}? [y/N] " c
        [[ "$c" =~ ^[Yy]$ ]] || { echo "Aborted — destination not cleared, PG not created."; exit 1; }
    fi
    oc delete vm          --all -n "$ns" --wait=false 2>/dev/null || true
    oc delete vmi         --all -n "$ns" --wait=false 2>/dev/null || true
    oc delete datavolumes --all -n "$ns" --wait=false 2>/dev/null || true
    oc delete pods        --all -n "$ns" --grace-period=0 --force --wait=false 2>/dev/null || true
    oc delete pvc         --all -n "$ns" --wait=false 2>/dev/null || true
    printf '\033[0;36m>> Waiting for PVCs (and their px volumes) to clear...\033[0m\n'
    local w=0
    while [ -n "$(oc get pvc -n "$ns" --no-headers 2>/dev/null)" ]; do
        if [ "$w" -ge 90 ]; then
            echo
            echo "WARNING: PVCs still present in '${ns}' on ${dst} after 90s — restore may still collide." >&2
            break
        fi
        sleep 3; w=$((w+3))
        printf '\r   waiting... (%ds)   ' "$w"
    done
    echo
    printf '\033[0;32m>> Destination %s cleared.\033[0m\n' "$dst"
}

printf '\033[0;36m>> Logging in to HUB...\033[0m\n'
hub_login

printf '\n'
printf '\033[1;33m######################################################################\033[0m\n'
printf '\033[1;33m#  \033[1;97mCreating ProtectionGroup: %s\033[0m\n' "${PG_NAME}"
printf '\033[1;33m#  \033[0;37m%s  (DR pair: %s)\033[0m\n' "${PG_LABEL}" "${PG_PAIR}"
printf '\033[1;33m#  \033[0;37mpurgeDeletedResourcesAtSource: false\033[0m\n'
printf '\033[1;33m######################################################################\033[0m\n'
printf '\n'

if oc get "${PG_RESOURCE}" "${PG_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    printf '\033[0;33m%s already exists.\033[0m\n' "${PG_NAME}"
    oc get "${PG_RESOURCE}" "${PG_NAME}" -n "${NAMESPACE}" \
        -o custom-columns='NAME:.metadata.name,PAIR:.spec.disasterRecoveryPairRef,PURGE:.spec.advanceConfiguration.purgeDeletedResourcesAtSource,STATE:.status.protectionState'
    exit 0
fi

# --- Wait for the DR pair to be fully ready on BOTH spokes before creating the
#     PG. Creating the PG too early makes its first migration interval race the
#     destination backuplocation/clusterpair creation -> restore fails with
#     'backuplocations ... not found'.
DR_RESOURCE="disasterrecoverypairs.${API_GROUP}"

if ! oc get "${DR_RESOURCE}" "${PG_PAIR}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "ERROR: DR pair '${PG_PAIR}' does not exist." >&2
    echo "       Run ./scripts/01_create_dr_pairs.sh first." >&2
    exit 1
fi

SRC="$(oc get "${DR_RESOURCE}" "${PG_PAIR}" -n "${NAMESPACE}" -o jsonpath='{.spec.sourceCluster}')"
DST="$(oc get "${DR_RESOURCE}" "${PG_PAIR}" -n "${NAMESPACE}" -o jsonpath='{.spec.destinationCluster}')"

cond() {  # condition-type -> status (True/False/"")
    oc get "${DR_RESOURCE}" "${PG_PAIR}" -n "${NAMESPACE}" \
        -o jsonpath="{.status.conditions[?(@.type=='$1')].status}" 2>/dev/null
}

REQUIRED=( "Ready"
           "${SRC}-Ready" "${DST}-Ready"
           "${SRC}-BackupLocationCreated" "${DST}-BackupLocationCreated" )

printf '\033[0;36m>> Waiting for DR pair %s to be ready on both spokes (%s, %s)...\033[0m\n' \
    "${PG_PAIR}" "${SRC}" "${DST}"
WAIT=0
MAX_WAIT=180
while true; do
    all_ready=true
    for c in "${REQUIRED[@]}"; do
        if [[ "$(cond "$c")" != "True" ]]; then all_ready=false; break; fi
    done
    if ${all_ready}; then
        printf '\033[0;32m>> DR pair %s is ready on both spokes.\033[0m\n\n' "${PG_PAIR}"
        break
    fi
    if [[ "${WAIT}" -ge "${MAX_WAIT}" ]]; then
        printf '\n\033[0;31mERROR: DR pair %s not ready after %ds. Current conditions:\033[0m\n' \
            "${PG_PAIR}" "${MAX_WAIT}" >&2
        oc get "${DR_RESOURCE}" "${PG_PAIR}" -n "${NAMESPACE}" \
            -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{"\n"}{end}' >&2
        exit 1
    fi
    sleep 5
    WAIT=$((WAIT+5))
    printf '\r   waiting... (%ds)   ' "${WAIT}"
done

# Round-trip onto a cluster that still holds the originals fails because
# Portworx preserves the volume name across the chain. gcp-on-prem loops back
# to on-prem, so clear the destination's VMs/PVCs before creating the PG.
if [[ "${PG_PAIR}" == "gcp-on-prem" ]]; then
    preclean_destination "${DST}" "wandering-workload"
    hub_login   # back to the hub for the apply
fi

oc apply -f - <<EOF
apiVersion: ${API_GROUP}/v1alpha1
kind: ProtectionGroup
metadata:
  name: ${PG_NAME}
  namespace: ${NAMESPACE}
spec:
  advanceConfiguration:
    applicationLifecycleHooks: {}
    ignoreDeletedNamespacesAtSource: true
    ignoreOwnerReferencesValidation: false
    purgeDeletedResourcesAtSource: false
    skipServiceUpdate: true
  disasterRecoveryPairRef: ${PG_PAIR}
  namespaceSelection:
    namespaces:
    - wandering-workload
  replicationSchedulePolicy:
    interval:
      intervalMinutes: 15
  resourceConfiguration:
    customSelection:
      includeApplicationVolumes: true
      includeCIDRBasedNetworkPolicies: true
    includeAllResources: true
  migrationConfiguration:
    startApplications: false
EOF

echo
printf '\033[1;32m>> Created %s (startApplications: false — VMs will NOT auto-start)\033[0m\n' "${PG_NAME}"
