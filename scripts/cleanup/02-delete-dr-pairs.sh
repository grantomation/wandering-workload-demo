#!/usr/bin/env bash
#
# cleanup-dr-pairs.sh — delete all Portworx DR pairs, protection groups, and
# DR actions from the ACM hub cluster. The Portworx multicluster agent will
# clean up the corresponding resources on the spoke clusters automatically.
#
# Run on the HUB.
#
set -euo pipefail

NAMESPACE="portworx"
API_GROUP="multicluster.portworx.com"

# --- Load credentials ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# --- Login to hub ---
printf '\033[0;36m>> Logging in to HUB...\033[0m\n'
if ! login_cluster hub; then
    echo "ERROR: failed to login to hub" >&2
    exit 1
fi

CLUSTER_API="$(oc whoami --show-server)"
CLUSTER_USER="$(oc whoami)"

printf '\n'
printf '\033[1;31m######################################################################\033[0m\n'
printf '\033[1;31m#\033[0m\n'
printf '\033[1;31m#  \033[1;97mHUB: %s\033[0m\n' "${CLUSTER_API}"
printf '\033[1;31m#  \033[0;36mUser: \033[0;37m%s\033[0m\n' "${CLUSTER_USER}"
printf '\033[1;31m#  \033[1;91mScript: cleanup-dr-pairs.sh (DESTRUCTIVE — deletes ALL DR pairs)\033[0m\n'
printf '\033[1;31m#\033[0m\n'
printf '\033[1;31m######################################################################\033[0m\n'

# --- Show what will be deleted ---
echo
printf '\033[0;36m  DR Actions:\033[0m\n'
oc get "disasterrecoveryactions.${API_GROUP}" -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | while read -r line; do printf '    %s\n' "${line}"; done
echo
printf '\033[0;36m  Protection Groups:\033[0m\n'
oc get "protectiongroups.${API_GROUP}" -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | while read -r line; do printf '    %s\n' "${line}"; done
echo
printf '\033[0;36m  DR Pairs:\033[0m\n'
oc get "disasterrecoverypairs.${API_GROUP}" -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | while read -r line; do printf '    %s\n' "${line}"; done

echo
read -r -p "Delete ALL of the above? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo

# --- Delete in dependency order: actions → protection groups → DR pairs ---

echo ">> [1/3] Deleting DR Actions..."
for obj in $(oc get "disasterrecoveryactions.${API_GROUP}" -n "${NAMESPACE}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    printf '   - %s\n' "${obj}"
    oc delete "disasterrecoveryactions.${API_GROUP}/${obj}" -n "${NAMESPACE}" \
        --wait=false 2>&1 || true
done

echo ">> [2/3] Deleting Protection Groups..."
for obj in $(oc get "protectiongroups.${API_GROUP}" -n "${NAMESPACE}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    printf '   - %s\n' "${obj}"
    oc delete "protectiongroups.${API_GROUP}/${obj}" -n "${NAMESPACE}" \
        --wait=false 2>&1 || true
done

echo ">> [3/3] Deleting DR Pairs..."
for obj in $(oc get "disasterrecoverypairs.${API_GROUP}" -n "${NAMESPACE}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    printf '   - %s\n' "${obj}"
    oc delete "disasterrecoverypairs.${API_GROUP}/${obj}" -n "${NAMESPACE}" \
        --wait=false 2>&1 || true
done

# --- Wait for cleanup to settle ---
echo
echo ">> Waiting for resources to be removed..."
WAIT=0
MAX_WAIT=90
while true; do
    remaining=0
    remaining=$(( remaining + $(oc get "disasterrecoveryactions.${API_GROUP}" -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l) ))
    remaining=$(( remaining + $(oc get "protectiongroups.${API_GROUP}" -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l) ))
    remaining=$(( remaining + $(oc get "disasterrecoverypairs.${API_GROUP}" -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l) ))

    if [[ "${remaining}" -eq 0 ]]; then
        break
    fi
    if [[ "${WAIT}" -ge "${MAX_WAIT}" ]]; then
        printf '\033[0;33m   %d resource(s) still present after %ds — finalizers may need manual removal.\033[0m\n' \
            "${remaining}" "${MAX_WAIT}"
        echo "   Remaining:"
        oc get "disasterrecoveryactions.${API_GROUP},protectiongroups.${API_GROUP},disasterrecoverypairs.${API_GROUP}" \
            -n "${NAMESPACE}" 2>/dev/null || true
        break
    fi
    sleep 5
    (( WAIT += 5 ))
    printf '\r   %d remaining... (%ds)' "${remaining}" "${WAIT}"
done

echo
echo "======================================================================"
echo " DR cleanup complete."
echo "======================================================================"
