#!/usr/bin/env bash
#
# 03-deep-clean-drp.sh — FULL teardown of a single Portworx DR pair.
#
# Why this exists:
#   Deleting the ProtectionGroup + DisasterRecoveryPair on the HUB is NOT
#   enough. The multicluster agent cleans up the *current* pair's source-side
#   clusterpair/schedule/secrets and the destination-side backuplocation/
#   clusterpair/secrets — but it reliably LEAVES BEHIND:
#     * destination-side MigrationSchedules (ns portworx), and
#     * source-side BackupLocations in kube-system (whose secret then gets
#       deleted, leaving a broken pointer that fails the next migration).
#
#   This script deletes the HUB objects AND then scrubs both spokes of every
#   artifact belonging to THIS pair, matched precisely by the DRP/PG UIDs that
#   are captured *before* deletion. It only ever touches the named pair — other
#   live pairs and pre-existing orphans from earlier pairs are left alone (clean
#   those by hand).
#
#   Run from anywhere; the script logs itself into the HUB and the two spokes.
#
# Usage:
#   ./scripts/05_cleanup-drp.sh <drp-name> [--dry-run] [--yes]
#   ./scripts/05_cleanup-drp.sh --all [--dry-run] [--yes]   # tear down EVERY pair
#   ./scripts/05_cleanup-drp.sh            # lists active DR pairs and exits
#
set -euo pipefail

NAMESPACE="portworx"
MC_GROUP="multicluster.portworx.com"
SPOKE_NS=(kube-system portworx)

DRP=""
DRY_RUN=false
ASSUME_YES=false
ALL=false

for arg in "$@"; do
    case "$arg" in
        --all)     ALL=true ;;
        --dry-run) DRY_RUN=true ;;
        --yes|-y)  ASSUME_YES=true ;;
        -*)        echo "Unknown flag: $arg" >&2; exit 1 ;;
        *)         DRP="$arg" ;;
    esac
done

# --- Cluster credentials (from credentials.env) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# --- Generic delete with finalizer fallback ---------------------------------
delete_obj() {
    local kind="$1" name="$2" ns="${3:-}"
    local nsf=(); [ -n "$ns" ] && nsf=(-n "$ns")
    oc get "$kind" "$name" "${nsf[@]}" >/dev/null 2>&1 || return 0
    local where="$kind/$name"; [ -n "$ns" ] && where="$where (ns=$ns)"
    if $DRY_RUN; then printf '    \033[0;33m[dry-run] would delete %s\033[0m\n' "$where"; return 0; fi
    printf '    deleting %s\n' "$where"
    oc delete "$kind" "$name" "${nsf[@]}" --wait=false --ignore-not-found >/dev/null 2>&1 || true
    local w=0
    while oc get "$kind" "$name" "${nsf[@]}" >/dev/null 2>&1; do
        if [ "$w" -ge 20 ]; then
            printf '      \033[0;35mfinalizer stuck — stripping finalizers\033[0m\n'
            oc patch "$kind" "$name" "${nsf[@]}" --type=merge \
                -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        fi
        if [ "$w" -ge 30 ]; then printf '      \033[0;31mSTILL PRESENT — giving up\033[0m\n'; break; fi
        sleep 2; w=$((w+2))
    done
}

# Delete every namespaced object of <kind> whose name contains <pattern>.
delete_by_pattern_ns() {
    local kind="$1" ns="$2" pattern="$3"
    local nm
    while read -r nm; do
        [ -n "$nm" ] && delete_obj "$kind" "$nm" "$ns"
    done < <(oc get "$kind" -n "$ns" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
             | grep -- "$pattern" || true)
}

# Delete every cluster-scoped object of <kind> whose name contains <pattern>.
delete_by_pattern_cluster() {
    local kind="$1" pattern="$2"
    local nm
    while read -r nm; do
        [ -n "$nm" ] && delete_obj "$kind" "$nm" ""
    done < <(oc get "$kind" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
             | grep -- "$pattern" || true)
}

# Scrub one spoke of all artifacts for this pair. $1=DRP UID ; rest=PG UIDs
#
# NOTE: the agent truncates the name *prefix* (e.g. "on-prem-aro" -> "on-prem-ar",
# "gcp-on-prem" -> "gcp-on-pre"), so we must NOT reconstruct the name from the DRP
# name. Both DRP- and PG-derived resources carry the FULL (untruncated) UID in
# their name, so we match on the UID substring instead.
scrub_spoke() {
    local druid="$1"; shift
    local pguids=("$@")
    # DRP-scoped resources (backuplocations/clusterpairs) carry the DRP UID.
    for ns in "${SPOKE_NS[@]}"; do
        delete_by_pattern_ns backuplocations.stork.libopenstorage.org "$ns" "$druid"
        delete_by_pattern_ns clusterpairs.stork.libopenstorage.org    "$ns" "$druid"
        # DR secrets: only the backup-location-*/peer-kubeconfig-* families
        # carrying this DRP UID (avoids touching unrelated secrets).
        local nm
        while read -r nm; do
            [ -n "$nm" ] && delete_obj secret "$nm" "$ns"
        done < <(oc get secrets -n "$ns" \
                    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
                 | grep -E '^(backup-location|peer-kubeconfig)-' | grep -- "$druid" || true)
    done
    # PG-scoped resources carry the PG UID in their name.
    [ ${#pguids[@]} -eq 0 ] && return 0
    local pguid
    for pguid in "${pguids[@]}"; do
        [ -z "$pguid" ] && continue
        for ns in "${SPOKE_NS[@]}"; do
            delete_by_pattern_ns migrationschedules.stork.libopenstorage.org "$ns" "$pguid"
            delete_by_pattern_ns migrations.stork.libopenstorage.org         "$ns" "$pguid"
        done
        delete_by_pattern_cluster schedulepolicies.stork.libopenstorage.org "$pguid"
    done
}

# --- Tear down a single pair (HUB delete + spoke scrub + verify) ------------
# Re-logs into the HUB itself, so it is safe to call in a loop. Returns 1 if
# any residue remained on the spokes, 0 otherwise.
teardown_pair() {
    local DRP="$1"

    login_cluster hub
    if ! oc get "disasterrecoverypairs.${MC_GROUP}" -n "$NAMESPACE" "$DRP" >/dev/null 2>&1; then
        echo "  skip: DR pair '$DRP' not found on the HUB."
        return 0
    fi

    local DRP_UID SRC DST
    DRP_UID="$(oc get "disasterrecoverypairs.${MC_GROUP}" -n "$NAMESPACE" "$DRP" -o jsonpath='{.metadata.uid}')"
    SRC="$(oc get "disasterrecoverypairs.${MC_GROUP}" -n "$NAMESPACE" "$DRP" -o jsonpath='{.spec.sourceCluster}')"
    DST="$(oc get "disasterrecoverypairs.${MC_GROUP}" -n "$NAMESPACE" "$DRP" -o jsonpath='{.spec.destinationCluster}')"

    # Protection groups that reference this pair (capture name + UID before delete).
    local PG_NAMES=() PG_UIDS=()
    local pg ref
    while read -r pg; do
        [ -z "$pg" ] && continue
        ref="$(oc get "protectiongroups.${MC_GROUP}" -n "$NAMESPACE" "$pg" -o jsonpath='{.spec.disasterRecoveryPairRef}' 2>/dev/null)"
        if [ "$ref" = "$DRP" ]; then
            PG_NAMES+=("$pg")
            PG_UIDS+=("$(oc get "protectiongroups.${MC_GROUP}" -n "$NAMESPACE" "$pg" -o jsonpath='{.metadata.uid}')")
        fi
    done < <(oc get "protectiongroups.${MC_GROUP}" -n "$NAMESPACE" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

    echo
    printf '\033[1;31m######################################################################\033[0m\n'
    printf '\033[1;31m#  TEARDOWN %s%s\033[0m\n' "$DRP" "$($DRY_RUN && echo '  (DRY RUN)')"
    printf '\033[1;31m######################################################################\033[0m\n'
    printf '  DR pair        : \033[1;97m%s\033[0m  (uid %s)\n' "$DRP" "$DRP_UID"
    printf '  Source -> Dest : %s -> %s\n' "$SRC" "$DST"
    printf '  Protection grps: %s\n' "${PG_NAMES[*]:-<none>}"

    # --- HUB teardown ---
    echo ">> [HUB] Deleting DR actions for this pair..."
    local act aref pgref _pg
    while read -r act; do
        [ -z "$act" ] && continue
        aref="$(oc get "disasterrecoveryactions.${MC_GROUP}" -n "$NAMESPACE" "$act" -o jsonpath='{.spec.disasterRecoveryPairRef}' 2>/dev/null)"
        pgref="$(oc get "disasterrecoveryactions.${MC_GROUP}" -n "$NAMESPACE" "$act" -o jsonpath='{.spec.protectionGroupReference}' 2>/dev/null)"
        local _match=false
        [ "$aref" = "$DRP" ] && _match=true
        [[ "$act" == "$DRP"* ]] && _match=true
        if [ -n "$pgref" ] && [ ${#PG_NAMES[@]} -gt 0 ]; then
            for _pg in "${PG_NAMES[@]}"; do [ "$pgref" = "$_pg" ] && _match=true; done
        fi
        $_match && delete_obj "disasterrecoveryactions.${MC_GROUP}" "$act" "$NAMESPACE"
    done < <(oc get "disasterrecoveryactions.${MC_GROUP}" -n "$NAMESPACE" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

    echo ">> [HUB] Deleting protection group(s)..."
    if [ ${#PG_NAMES[@]} -gt 0 ]; then
        for pg in "${PG_NAMES[@]}"; do
            delete_obj "protectiongroups.${MC_GROUP}" "$pg" "$NAMESPACE"
        done
    fi

    echo ">> [HUB] Deleting DR pair..."
    delete_obj "disasterrecoverypairs.${MC_GROUP}" "$DRP" "$NAMESPACE"

    # --- Let the agent do its share, then scrub the spokes ---
    if ! $DRY_RUN; then
        echo ">> Waiting 25s for the agent to clean its share on the spokes..."
        sleep 25
    fi

    local spoke ns
    for spoke in "$SRC" "$DST"; do
        echo ">> [${spoke}] Scrubbing pair leftovers..."
        login_cluster "$spoke"
        scrub_spoke "$DRP_UID" ${PG_UIDS[@]+"${PG_UIDS[@]}"}
    done

    # --- Verify (skip in dry-run: nothing was deleted, so it'd false-report) ---
    $DRY_RUN && return 0
    local residue=0 found
    for spoke in "$SRC" "$DST"; do
        login_cluster "$spoke"
        found=""
        for ns in "${SPOKE_NS[@]}"; do
            local _grep_pat="${DRP_UID}"
            if [ ${#PG_UIDS[@]} -gt 0 ]; then
                _grep_pat="${DRP_UID}$(printf '|%s' "${PG_UIDS[@]}")"
            fi
            found+="$(oc get backuplocations.stork.libopenstorage.org,clusterpairs.stork.libopenstorage.org,migrationschedules.stork.libopenstorage.org,migrations.stork.libopenstorage.org,secrets \
                        -n "$ns" -o name 2>/dev/null | grep -E "$_grep_pat" || true)"
        done
        if [ ${#PG_UIDS[@]} -gt 0 ]; then
            found+="$(oc get schedulepolicies.stork.libopenstorage.org -o name 2>/dev/null | grep -E "$(printf '%s|' "${PG_UIDS[@]}")xxx" || true)"
        fi
        if [ -n "$found" ]; then
            printf '   \033[0;31m%s: residue remains:\033[0m\n%s\n' "$spoke" "$found"
            residue=1
        else
            printf '   \033[0;32m%s: clean\033[0m\n' "$spoke"
        fi
    done
    return $residue
}

# --- Build the list of pairs to tear down -----------------------------------
login_cluster hub

PAIRS=()
if $ALL; then
    while read -r p; do [ -n "$p" ] && PAIRS+=("$p"); done < <(oc get "disasterrecoverypairs.${MC_GROUP}" \
        -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [ ${#PAIRS[@]} -eq 0 ]; then echo "No DR pairs on the HUB."; fi
elif [ -n "$DRP" ]; then
    PAIRS=("$DRP")
else
    echo
    echo "No DR pair given. Active DR pairs on the HUB:"
    oc get "disasterrecoverypairs.${MC_GROUP}" -n "$NAMESPACE" --no-headers 2>/dev/null \
        | awk '{printf "    %s\n", $1}'
    echo
    echo "Usage: $(basename "$0") <drp-name>|--all [--dry-run] [--yes]"
    exit 0
fi

OVERALL=0
if [ ${#PAIRS[@]} -gt 0 ]; then
    echo
    echo "Pairs to tear down: ${PAIRS[*]}"
    if ! $DRY_RUN && ! $ASSUME_YES; then
        read -r -p "Proceed with FULL teardown of the above (HUB + spoke scrub)? [y/N] " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    for pair in "${PAIRS[@]}"; do
        teardown_pair "$pair" || OVERALL=1
    done
fi

# --- Sweep orphaned DR actions on the HUB ------------------------------------
# Actions from earlier runs whose DR pair / protection group was already deleted
# won't be matched by teardown_pair. Delete any action whose
# protectionGroupReference no longer exists.
login_cluster hub
live_pgs="$(oc get "protectiongroups.${MC_GROUP}" -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
orphan_count=0
while read -r act; do
    [ -z "$act" ] && continue
    pgref="$(oc get "disasterrecoveryactions.${MC_GROUP}" -n "$NAMESPACE" "$act" \
        -o jsonpath='{.spec.protectionGroupReference}' 2>/dev/null)"
    if [ -z "$pgref" ] || ! grep -qxF "$pgref" <<<"$live_pgs"; then
        orphan_count=$((orphan_count+1))
        delete_obj "disasterrecoveryactions.${MC_GROUP}" "$act" "$NAMESPACE"
    fi
done < <(oc get "disasterrecoveryactions.${MC_GROUP}" -n "$NAMESPACE" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
if [ "$orphan_count" -gt 0 ]; then
    printf '>> Swept %d orphaned DR action(s) from the HUB.\n' "$orphan_count"
fi

echo
echo "======================================================================"
if [ "$OVERALL" -eq 0 ]; then
    echo " Teardown complete — no residue.${PAIRS[*]+  Pairs: ${PAIRS[*]}}"
else
    echo " Teardown finished WITH RESIDUE — inspect the lines above."
fi
echo "======================================================================"
