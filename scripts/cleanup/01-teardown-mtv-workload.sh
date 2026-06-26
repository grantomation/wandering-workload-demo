#!/bin/bash
#
# 01-teardown-mtv-workload.sh — fully tear down an MTV/KubeVirt workload for a project.
#
# "Clean" means clean: it kills the SOURCE (forklift Plan/Migration in the MTV
# namespace) first so nothing respawns, then loops over the target project
# deleting VMs/VMIs/pods/jobs/DVs/PVCs until it is genuinely empty, and finally
# deletes the project itself and confirms it does not come back.
#
# Usage:
#   ./scripts/cleanup/01-teardown-mtv-workload.sh [project]        # current logged-in cluster
#   ./scripts/cleanup/01-teardown-mtv-workload.sh all [project]    # ALL spokes (self-login)
#
# Env overrides:
#   MTV_NS=openshift-mtv     namespace where forklift Plans/Migrations live
#   RETRIES=12               how many sweeps before giving up
#   DELETE_PROJECT=true      also delete the project (set false to keep it)
#   FORCE=true               skip the confirmation prompt(s)
#
set -euo pipefail

MTV_NS="${MTV_NS:-openshift-mtv}"
RETRIES="${RETRIES:-12}"
DELETE_PROJECT="${DELETE_PROJECT:-true}"
KEEP_PLAN="${KEEP_PLAN:-false}"     # true = don't delete the forklift Plan (for MTV retry)
FORCE="${FORCE:-false}"

SPOKES=(ARO ROSA GCP ONPREM)
# In 'all' mode, clean VMs/PVCs on these spokes but KEEP the namespace.
PRESERVE_NS_SPOKES=(ONPREM)

# --- Cluster credentials (from credentials.env) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# --- Workload deletion primitives (operate on the current login) ------------

# Strip finalizers then delete a single object, never failing the script.
nuke() { # nuke <kind/name> <namespace>
    oc patch "$1" -n "$2" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    oc delete "$1" -n "$2" --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
}

# Delete the forklift Plans/Migrations that drive THIS project's migration.
delete_source() {
    local plans plan mig mig_name mig_plan
    plans="$(oc get plans.forklift.konveyor.io -n "${MTV_NS}" \
        -o jsonpath="{range .items[?(@.spec.targetNamespace=='${PROJECT}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null || true)"

    for mig in $(oc get migrations.forklift.konveyor.io -n "${MTV_NS}" \
            -o jsonpath="{range .items[*]}{.metadata.name}={.spec.plan.name}{'\n'}{end}" 2>/dev/null || true); do
        mig_name="${mig%%=*}"; mig_plan="${mig#*=}"
        if grep -qxF "${mig_plan}" <<<"${plans}"; then
            echo "  - migration: ${mig_name}"
            nuke "migrations.forklift.konveyor.io/${mig_name}" "${MTV_NS}"
        fi
    done

    for plan in ${plans}; do
        echo "  - plan: ${plan}"
        nuke "plans.forklift.konveyor.io/${plan}" "${MTV_NS}"
    done
}

# Delete everything inside the target project namespace.
delete_workload() {
    local job
    oc delete vm  --all -n "${PROJECT}" --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
    oc delete vmi --all -n "${PROJECT}" --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
    for job in $(oc get jobs -n "${PROJECT}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
        nuke "job/${job}" "${PROJECT}"
    done
    oc delete pods        --all -n "${PROJECT}" --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
    oc delete datavolumes --all -n "${PROJECT}" --wait=false >/dev/null 2>&1 || true
    oc delete pvc         --all -n "${PROJECT}" --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
}

# Count anything still lingering for this project (source + workload).
remaining() {
    local n=0
    if [[ "${KEEP_PLAN}" != "true" ]]; then
        n=$(( n + $(oc get plans.forklift.konveyor.io -n "${MTV_NS}" \
            -o jsonpath="{range .items[?(@.spec.targetNamespace=='${PROJECT}')]}x{end}" 2>/dev/null | wc -c) ))
    fi
    if oc get namespace "${PROJECT}" >/dev/null 2>&1; then
        n=$(( n + $(oc get vm,vmi,pods,jobs,datavolumes,pvc -n "${PROJECT}" \
            --no-headers 2>/dev/null | grep -vc '^$' || true) ))
    fi
    echo "$n"
}

# Run the full cleanup on whatever cluster we are currently logged into.
run_cleanup() {
    local CLUSTER_API CLUSTER_USER CLUSTER_NAME CLUSTER_PLATFORM i left
    CLUSTER_API="$(oc whoami --show-server 2>/dev/null || echo '?')"
    CLUSTER_USER="$(oc whoami 2>/dev/null || echo '?')"
    CLUSTER_NAME="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo 'unknown')"
    CLUSTER_PLATFORM="$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || echo '')"

    printf '\n\033[1;31m######################################################################\033[0m\n'
    printf '\033[1;31m#  \033[1;97m%s  (%s)\033[0m\n' "${CLUSTER_NAME}" "${CLUSTER_PLATFORM}"
    printf '\033[1;31m#  \033[0;37m%s   user=%s\033[0m\n' "${CLUSTER_API}" "${CLUSTER_USER}"
    printf '\033[1;31m#  \033[1;91mcleanup-mtv: project=%s (DESTRUCTIVE)\033[0m\n' "${PROJECT}"
    printf '\033[1;31m######################################################################\033[0m\n'

    if ! oc get namespace "${PROJECT}" >/dev/null 2>&1 \
        && [ -z "$(oc get plans.forklift.konveyor.io -n "${MTV_NS}" \
              -o jsonpath="{range .items[?(@.spec.targetNamespace=='${PROJECT}')]}x{end}" 2>/dev/null)" ]; then
        echo "   nothing to do (no '${PROJECT}' namespace, no forklift plans)."
        return 0
    fi

    i=0
    while :; do
        i=$((i+1))
        echo "--> sweep ${i}/${RETRIES}"
        [[ "${KEEP_PLAN}" == "true" ]] || delete_source
        delete_workload
        left="$(remaining)"
        if [ "${left}" -eq 0 ]; then echo "    project is clean."; break; fi
        if [ "${i}" -ge "${RETRIES}" ]; then
            echo "WARNING: ${left} object(s) still present after ${RETRIES} sweeps."
            oc get vm,vmi,pods,jobs,datavolumes,pvc -n "${PROJECT}" 2>/dev/null || true
            return 1
        fi
        sleep 3
    done

    # Never delete the project on clusters listed in PRESERVE_NS_SPOKES.
    local _do_delete="${DELETE_PROJECT}"
    for _pns in "${PRESERVE_NS_SPOKES[@]}"; do
        local _pns_api
        _pns_api="$(creds_for "$_pns" | awk -F'|' '{print $4}')" || continue
        if [[ "${CLUSTER_API}" == "${_pns_api}" ]]; then
            echo "    (${_pns} cluster — preserving project '${PROJECT}')"
            _do_delete="false"
            break
        fi
    done

    if [ "${_do_delete}" = "true" ]; then
        echo "--> deleting project ${PROJECT}"
        i=0
        while oc get project "${PROJECT}" >/dev/null 2>&1; do
            i=$((i+1))
            oc delete project "${PROJECT}" --wait=false >/dev/null 2>&1 || true
            [[ "${KEEP_PLAN}" == "true" ]] || delete_source   # keep source dead so forklift can't recreate the ns
            sleep 3
            if [ "${i}" -ge "${RETRIES}" ]; then
                echo "WARNING: project ${PROJECT} keeps coming back after ${RETRIES} tries."
                return 1
            fi
        done
        echo "    project ${PROJECT} deleted."
    fi
    echo "    cleanup complete on this cluster."
    return 0
}

# --- Parse args -------------------------------------------------------------
if [[ "${1:-}" == "all" || "${1:-}" == "ALL" ]]; then
    MODE="all"
    PROJECT="${2:-wandering-workload}"
else
    MODE="single"
    PROJECT="${1:-}"
fi

# --- ALL spokes -------------------------------------------------------------
if [[ "${MODE}" == "all" ]]; then
    printf '\033[1;31m######################################################################\033[0m\n'
    printf '\033[1;31m#  DELETE project "%s" (VMs/PVCs/namespace) on ALL spokes:\033[0m\n' "${PROJECT}"
    printf '\033[1;31m#    %s\033[0m\n' "${SPOKES[*]}"
    printf '\033[1;31m#  DELETE_PROJECT=%s   (namespace KEPT on: %s)\033[0m\n' "${DELETE_PROJECT}" "${PRESERVE_NS_SPOKES[*]}"
    printf '\033[1;31m######################################################################\033[0m\n'
    if [[ "${FORCE}" != "true" ]]; then
        read -r -p "Proceed on ALL clusters? [y/N] " CONFIRM
        [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi
    rc=0
    for s in "${SPOKES[@]}"; do
        login_cluster "$s" || { echo "WARNING: skipping $s (login failed)"; rc=1; continue; }
        saved_dp="${DELETE_PROJECT}"
        if [[ " ${PRESERVE_NS_SPOKES[*]} " == *" ${s} "* ]]; then
            DELETE_PROJECT="false"
            echo "   (keeping the '${PROJECT}' namespace on ${s} — clearing VMs/PVCs only)"
        fi
        run_cleanup || { echo "WARNING: cleanup issues on $s"; rc=1; }
        DELETE_PROJECT="${saved_dp}"
    done
    echo
    echo "======================================================================"
    if [[ "${rc}" -eq 0 ]]; then
        echo " All spokes cleaned for project '${PROJECT}'."
    else
        echo " Finished WITH WARNINGS — see the lines above."
    fi
    echo "======================================================================"
    exit "${rc}"
fi

# --- Single cluster (current login) -----------------------------------------
if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: not logged in. Run ./scripts/switch.sh <cluster> first, or use 'all'." >&2
    exit 1
fi
if [[ -z "${PROJECT}" ]]; then
    read -r -p "Enter the OpenShift project name [wandering-workload]: " INPUT_PROJECT
    PROJECT="${INPUT_PROJECT:-wandering-workload}"
fi
if [[ "${FORCE}" != "true" ]]; then
    _cur_api="$(oc whoami --show-server)"
    _will_keep_project=false
    for _pns in "${PRESERVE_NS_SPOKES[@]}"; do
        _pns_api="$(creds_for "$_pns" | awk -F'|' '{print $4}')" || continue
        [[ "${_cur_api}" == "${_pns_api}" ]] && { _will_keep_project=true; break; }
    done
    printf '\033[1;31mCluster: %s  (user %s)\033[0m\n' "${_cur_api}" "$(oc whoami)"
    if [[ "${_will_keep_project}" == "true" ]]; then
        printf '\033[1;33mAction:  Delete VMs, pods, PVCs, datavolumes, and jobs in '\''%s'\''\033[0m\n' "${PROJECT}"
        printf '\033[1;33m         Project and permissions will be KEPT.\033[0m\n'
    elif [[ "${DELETE_PROJECT}" == "true" ]]; then
        printf '\033[1;31mAction:  Delete ALL resources AND the '\''%s'\'' project itself.\033[0m\n' "${PROJECT}"
    else
        printf '\033[1;33mAction:  Delete VMs, pods, PVCs, datavolumes, and jobs in '\''%s'\''\033[0m\n' "${PROJECT}"
        printf '\033[1;33m         Project will be KEPT (DELETE_PROJECT=false).\033[0m\n'
    fi
    read -r -p "Proceed? [y/N] " CONFIRM
    [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi
run_cleanup
