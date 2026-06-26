#!/usr/bin/env bash
#
# refresh-mtv-inventory.sh — force the MTV/forklift vSphere agent to re-poll
# vCenter by deleting the inventory + controller pods. The new pods rebuild
# the cached inventory, which refreshes the view in the OpenShift Virt console.
#
# Usage:
#   ./refresh-mtv-inventory.sh [namespace]
#
# Defaults to the openshift-mtv namespace.

set -euo pipefail

NS="${1:-openshift-mtv}"

if ! oc whoami >/dev/null 2>&1; then
  echo "Not logged in. Run:  oc login --token=<token> --server=<api-url>" >&2
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
printf '\033[1;33m#  \033[0;36mScript: \033[0;37m%s\033[0m\n' "refresh-mtv-inventory.sh (restarts forklift pods)"
printf '\033[1;33m#\033[0m\n'
printf '\033[1;33m######################################################################\033[0m\n'
printf '\n'
read -r -p "Proceed on this cluster? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo

if ! oc get namespace "$NS" >/dev/null 2>&1; then
  echo "Namespace '$NS' not found. Pass the correct one as an argument." >&2
  exit 1
fi

echo "Refreshing MTV inventory in namespace: $NS"
echo

# Match the forklift inventory/controller pods. Try label selector first,
# fall back to name matching if the labels differ in this install.
pods="$(oc -n "$NS" get pods -o name \
  | grep -E 'forklift-(controller|inventory)' || true)"

if [[ -z "$pods" ]]; then
  echo "No forklift-controller/inventory pods found in '$NS'." >&2
  echo "Current pods:" >&2
  oc -n "$NS" get pods >&2
  exit 1
fi

echo "Deleting:"
echo "$pods" | sed 's/^/  /'
echo

echo "$pods" | xargs oc -n "$NS" delete

echo
echo "Waiting for pods to come back Ready..."
oc -n "$NS" wait --for=condition=Ready \
  pod -l app=forklift --timeout=180s || {
    echo "Pods not Ready yet; check:  oc -n $NS get pods" >&2
    exit 1
  }

echo
echo "Done. Inventory is re-polling vCenter."
echo "Give the console a minute, then reload the OpenShift Virt view."
