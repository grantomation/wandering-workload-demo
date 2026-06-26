#!/usr/bin/env bash
#
# 03-set-stork-admin-namespace.sh — set the Portworx Stork admin-namespace to
# 'portworx' on a spoke's StorageCluster (or on ALL spokes).
#
# Why: on managed clusters (ROSA, OSD) the SRE namespace-validation webhook
# blocks Stork from writing MigrationSchedules into kube-system, and the
# cross-cluster restore looks for the BackupLocation in the SOURCE's
# admin-namespace on the destination. So EVERY spoke must use the same
# admin-namespace ('portworx') or async DR migrations fail with either
# "denied ... managed namespaces" (source) or "backuplocation ... not found"
# (destination restore).
#
# Usage:
#   ./scripts/cluster-setup/03-set-stork-admin-namespace.sh <ARO|ROSA|OSD|ON-PREM>
#   ./scripts/patch_admin.sh ALL              # patch every spoke
#
set -euo pipefail

NAMESPACE="portworx"
ADMIN_NS="portworx"
SPOKES=(ARO ROSA OSD ON-PREM)

usage() {
    printf 'Usage: %s <ARO|ROSA|OSD|ON-PREM|ALL>\n' "$(basename "$0")"
    exit 1
}

[[ $# -eq 1 ]] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# Patch one cluster. Returns non-zero on failure (so ALL can keep going).
patch_one() {
    local target="$1"
    login_cluster "$target" || return 1

    local px; px="$(oc get storagecluster -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$px" ]]; then echo "ERROR: no StorageCluster in '$NAMESPACE' on $label" >&2; return 1; fi

    printf '\033[1;33m>> %s — StorageCluster: %s\033[0m\n' "$label" "$px"
    printf '   before: stork.args=%s\n' "$(oc get storagecluster "$px" -n "$NAMESPACE" -o jsonpath='{.spec.stork.args}' 2>/dev/null || true)"

    local current; current="$(oc get storagecluster "$px" -n "$NAMESPACE" -o jsonpath='{.spec.stork.args.admin-namespace}' 2>/dev/null || true)"
    if [[ "$current" == "$ADMIN_NS" ]]; then
        printf '\033[0;32m>> admin-namespace is already %s — nothing to do.\033[0m\n' "$ADMIN_NS"
        return 0
    fi

    printf '\033[0;36m>> Setting stork admin-namespace=%s ...\033[0m\n' "$ADMIN_NS"
    oc patch storagecluster "$px" -n "$NAMESPACE" --type=merge \
        -p "{\"spec\":{\"stork\":{\"args\":{\"admin-namespace\":\"${ADMIN_NS}\"}}}}"
    printf '   after:  stork.args=%s\n' "$(oc get storagecluster "$px" -n "$NAMESPACE" -o jsonpath='{.spec.stork.args}' 2>/dev/null || true)"

    printf '\033[0;36m>> Waiting for the operator to roll Stork...\033[0m\n'
    oc rollout status deployment/stork -n "$NAMESPACE" --timeout=120s 2>/dev/null \
        || oc wait --for=condition=Ready pod -l name=stork -n "$NAMESPACE" --timeout=120s 2>/dev/null \
        || echo "   (could not confirm rollout — check 'oc get pods -n $NAMESPACE -l name=stork')"

    printf '\033[1;32m>> %s — Stork admin-namespace is now %s.\033[0m\n' "$label" "$ADMIN_NS"
}

TARGET="$(echo "$1" | tr '[:lower:]' '[:upper:]')"

if [[ "$TARGET" == "ALL" ]]; then
    rc=0
    for s in "${SPOKES[@]}"; do
        echo
        patch_one "$s" || { echo "WARNING: $s failed — continuing."; rc=1; }
    done
    echo
    if [[ "$rc" -eq 0 ]]; then
        echo "======================================================================"
        echo " All spokes patched: admin-namespace=${ADMIN_NS}"
        echo "======================================================================"
    else
        echo "Some spokes failed — see WARNING lines above."
    fi
    exit "$rc"
fi

creds_for "$TARGET" >/dev/null || usage
patch_one "$TARGET"
