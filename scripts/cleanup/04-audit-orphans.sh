#!/usr/bin/env bash
#
# 04-audit-orphans.sh — READ-ONLY audit of Portworx DR cruft on the HUB + spokes.
#
# Builds the set of *live* DR pairs / protection groups from the HUB, then:
#   1) Audits the HUB for orphaned DisasterRecoveryActions whose
#      protectionGroupReference no longer maps to a live protection group.
#   2) Walks each spoke and flags every stork DR artifact that does NOT map back
#      to a live pair (orphan), plus any BackupLocation whose credential secret
#      is missing (broken — the thing that fails migrations).
# Nothing is deleted; for each orphan it prints the exact 'oc delete' you'd run
# to clean it by hand.
#
# Matching rules (same identity scheme the agent uses):
#   * backuplocations / clusterpairs / secrets are named "<drp>-<drp-uid>"
#     (secrets: backup-location-<...> and peer-kubeconfig-<...>).
#   * migrationschedules / migrations / schedulepolicies carry the PG UID in
#     their name. Only schedulepolicies prefixed "portworx-" are DR-created;
#     "default-*" policies are Portworx built-ins and are ignored.
#
# Usage:
#   ./scripts/06_audit-orphans.sh                 # audit all spokes
#   ./scripts/06_audit-orphans.sh rosa gcp        # audit a subset
#
set -euo pipefail

MC_GROUP="multicluster.portworx.com"
HUB_NS="portworx"
SPOKE_NS=(kube-system portworx)

SPOKES=("$@")
[ ${#SPOKES[@]} -eq 0 ] && SPOKES=(rosa aro gcp on-prem)

# --- Cluster credentials (from credentials.env) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

contains()        { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
contains_substr() { local h="$1"; shift; local x; for x in "$@"; do [ -n "$x" ] && [[ "$h" == *"$x"* ]] && return 0; done; return 1; }

secret_exists() {  # secret is healthy if present in portworx OR kube-system
    local s="$1" ns
    for ns in portworx kube-system; do
        oc get secret "$s" -n "$ns" >/dev/null 2>&1 && return 0
    done
    return 1
}

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'; C_CYN=$'\033[0;36m'; C_MAG=$'\033[0;35m'; C_OFF=$'\033[0m'

# --- 1) Build the live set from the HUB -------------------------------------
echo "${C_CYN}>> Logging in to HUB to read live DR pairs / protection groups...${C_OFF}"
login_cluster hub || exit 1

# Store DRP UIDs (not "<name>-<uid>"): the agent truncates the name prefix on
# the spokes (e.g. "on-prem-aro" -> "on-prem-ar"), but the full UID is always
# present, so we match resources by UID substring.
VALID_DRUIDS=()
while read -r drp; do
    [ -z "$drp" ] && continue
    uid="$(oc get "disasterrecoverypairs.${MC_GROUP}" -n "$HUB_NS" "$drp" -o jsonpath='{.metadata.uid}' 2>/dev/null)"
    [ -n "$uid" ] && VALID_DRUIDS+=("$uid")
done < <(oc get "disasterrecoverypairs.${MC_GROUP}" -n "$HUB_NS" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

VALID_PGUIDS=()
while read -r pg; do
    [ -z "$pg" ] && continue
    uid="$(oc get "protectiongroups.${MC_GROUP}" -n "$HUB_NS" "$pg" -o jsonpath='{.metadata.uid}' 2>/dev/null)"
    [ -n "$uid" ] && VALID_PGUIDS+=("$uid")
done < <(oc get "protectiongroups.${MC_GROUP}" -n "$HUB_NS" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

echo
echo "${C_CYN}Live DR pairs (valid DRP UIDs):${C_OFF}"
if [ ${#VALID_DRUIDS[@]} -eq 0 ]; then echo "    (none)"; else printf '    %s\n' "${VALID_DRUIDS[@]}"; fi
echo "${C_CYN}Live protection groups (valid PG UIDs):${C_OFF}"
if [ ${#VALID_PGUIDS[@]} -eq 0 ]; then echo "    (none)"; else printf '    %s\n' "${VALID_PGUIDS[@]}"; fi

# Collect live PG names so we can match DR actions by protectionGroupReference.
VALID_PGNAMES=()
while read -r pg; do
    [ -n "$pg" ] && VALID_PGNAMES+=("$pg")
done < <(oc get "protectiongroups.${MC_GROUP}" -n "$HUB_NS" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

# guard against unbound-array expansion under set -u
base_ok()  { [ ${#VALID_DRUIDS[@]} -gt 0 ] && contains_substr "$1" "${VALID_DRUIDS[@]}"; }
pguid_ok() { [ ${#VALID_PGUIDS[@]} -gt 0 ] && contains_substr "$1" "${VALID_PGUIDS[@]}"; }

TOTAL_ORPHANS=0
TOTAL_BROKEN=0

report_resource() {
    # kind, name, ns(""=cluster), classification, reason
    local kind="$1" name="$2" ns="$3" class="$4" reason="$5"
    local nsf=""; [ -n "$ns" ] && nsf=" -n $ns"
    case "$class" in
        ok)     printf '    %s%-7s%s %s%s\n' "$C_GRN" "OK"     "$C_OFF" "$kind/$name" "${ns:+ (ns=$ns)}" ;;
        orphan) printf '    %s%-7s%s %s%s  %s(%s)%s\n' "$C_YEL" "ORPHAN" "$C_OFF" "$kind/$name" "${ns:+ (ns=$ns)}" "$C_YEL" "$reason" "$C_OFF"
                printf '            %s-> oc delete %s %s%s%s\n' "$C_MAG" "$kind" "$name" "$nsf" "$C_OFF"
                TOTAL_ORPHANS=$((TOTAL_ORPHANS+1)) ;;
        broken) printf '    %s%-7s%s %s%s  %s(%s)%s\n' "$C_RED" "BROKEN" "$C_OFF" "$kind/$name" "${ns:+ (ns=$ns)}" "$C_RED" "$reason" "$C_OFF"
                printf '            %s-> oc delete %s %s%s%s\n' "$C_MAG" "$kind" "$name" "$nsf" "$C_OFF"
                TOTAL_BROKEN=$((TOTAL_BROKEN+1)) ;;
    esac
}

# --- 2) Audit HUB DR actions ------------------------------------------------
echo
echo "${C_CYN}######################################################################${C_OFF}"
echo "${C_CYN}#  HUB: DisasterRecoveryActions${C_OFF}"
echo "${C_CYN}######################################################################${C_OFF}"
login_cluster hub || { echo "    ${C_RED}skipped (login failed)${C_OFF}"; }

while read -r act; do
    [ -z "$act" ] && continue
    pgref="$(oc get "disasterrecoveryactions.${MC_GROUP}" -n "$HUB_NS" "$act" \
        -o jsonpath='{.spec.protectionGroupReference}' 2>/dev/null)"
    if [ -n "$pgref" ] && contains "$pgref" "${VALID_PGNAMES[@]+"${VALID_PGNAMES[@]}"}"; then
        report_resource "disasterrecoveryactions.${MC_GROUP}" "$act" "$HUB_NS" ok ""
    else
        report_resource "disasterrecoveryactions.${MC_GROUP}" "$act" "$HUB_NS" orphan "no live protection group"
    fi
done < <(oc get "disasterrecoveryactions.${MC_GROUP}" -n "$HUB_NS" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

# --- 3) Walk each spoke -----------------------------------------------------
for spoke in "${SPOKES[@]}"; do
    echo
    echo "${C_CYN}######################################################################${C_OFF}"
    echo "${C_CYN}#  SPOKE: ${spoke}${C_OFF}"
    echo "${C_CYN}######################################################################${C_OFF}"
    if ! login_cluster "$spoke"; then
        echo "    ${C_RED}skipped (login failed)${C_OFF}"; continue
    fi

    for ns in "${SPOKE_NS[@]}"; do
        # BackupLocations & ClusterPairs (matched by base name)
        for kind in backuplocations.stork.libopenstorage.org clusterpairs.stork.libopenstorage.org; do
            while read -r nm; do
                [ -z "$nm" ] && continue
                if base_ok "$nm"; then
                    # extra: a live BL with a missing secret is BROKEN
                    if [[ "$kind" == backuplocations* ]]; then
                        sc="$(oc get "$kind" "$nm" -n "$ns" -o jsonpath='{.location.secretConfig}' 2>/dev/null)"
                        if [ -n "$sc" ] && ! secret_exists "$sc"; then
                            report_resource "$kind" "$nm" "$ns" broken "secret '$sc' missing"
                            continue
                        fi
                    fi
                    report_resource "$kind" "$nm" "$ns" ok ""
                else
                    if [[ "$kind" == backuplocations* ]]; then
                        sc="$(oc get "$kind" "$nm" -n "$ns" -o jsonpath='{.location.secretConfig}' 2>/dev/null)"
                        if [ -n "$sc" ] && ! secret_exists "$sc"; then
                            report_resource "$kind" "$nm" "$ns" broken "orphan + secret '$sc' missing"
                            continue
                        fi
                    fi
                    report_resource "$kind" "$nm" "$ns" orphan "no live DR pair"
                fi
            done < <(oc get "$kind" -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
        done

        # MigrationSchedules & Migrations (matched by PG UID)
        for kind in migrationschedules.stork.libopenstorage.org migrations.stork.libopenstorage.org; do
            while read -r nm; do
                [ -z "$nm" ] && continue
                if pguid_ok "$nm"; then report_resource "$kind" "$nm" "$ns" ok ""
                else report_resource "$kind" "$nm" "$ns" orphan "no live protection group"; fi
            done < <(oc get "$kind" -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
        done

        # DR secrets (matched by base after stripping prefix)
        while read -r nm; do
            [ -z "$nm" ] && continue
            stripped="${nm#backup-location-}"; stripped="${stripped#peer-kubeconfig-}"
            if base_ok "$stripped"; then report_resource secret "$nm" "$ns" ok ""
            else report_resource secret "$nm" "$ns" orphan "no live DR pair"; fi
        done < <(oc get secrets -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
                    | grep -E '^(backup-location|peer-kubeconfig)-' || true)
    done

    # SchedulePolicies (cluster-scoped; only DR-created portworx-* ones)
    while read -r nm; do
        [ -z "$nm" ] && continue
        if pguid_ok "$nm"; then report_resource schedulepolicies.stork.libopenstorage.org "$nm" "" ok ""
        else report_resource schedulepolicies.stork.libopenstorage.org "$nm" "" orphan "no live protection group"; fi
    done < <(oc get schedulepolicies.stork.libopenstorage.org -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
                | grep -E '^portworx-' || true)
done

# --- 4) Summary -------------------------------------------------------------
echo
echo "======================================================================"
printf ' Audit complete: %s%d orphan(s)%s, %s%d broken backuplocation(s)%s\n' \
    "$C_YEL" "$TOTAL_ORPHANS" "$C_OFF" "$C_RED" "$TOTAL_BROKEN" "$C_OFF"
echo " (read-only — nothing was deleted; run the printed 'oc delete' lines to clean)"
echo "======================================================================"
