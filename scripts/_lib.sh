#!/usr/bin/env bash
#
# _lib.sh — shared credential loading and cluster login helpers.
# Source this from any script that needs cluster access:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"
#

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_LIB_DIR/.." && pwd)"
CREDS_FILE="${CREDS_FILE:-$_REPO_ROOT/credentials.env}"

if [[ ! -f "$CREDS_FILE" ]]; then
    echo "ERROR: credentials file not found: $CREDS_FILE" >&2
    echo "Copy credentials.env.example to credentials.env and fill in the values." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CREDS_FILE"

# creds_for <CLUSTER> — returns "user|pass|api" for the given cluster token.
creds_for() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        hub)               echo "${HUB_USER}|${HUB_PASS}|${HUB_API}" ;;
        rosa)              echo "${ROSA_USER}|${ROSA_PASS}|${ROSA_API}" ;;
        aro)               echo "${ARO_USER}|${ARO_PASS}|${ARO_API}" ;;
        gcp|osd)           echo "${GCP_USER}|${GCP_PASS}|${GCP_API}" ;;
        on-prem|onprem)    echo "${ONPREM_USER}|${ONPREM_PASS}|${ONPREM_API}" ;;
        *) return 1 ;;
    esac
}

# login_cluster <CLUSTER> — log in via oc to the named cluster.
login_cluster() {
    local token="$1"
    local triple; triple="$(creds_for "$token")" || { echo "ERROR: unknown cluster '$token'" >&2; return 1; }
    local u="${triple%%|*}"; local rest="${triple#*|}"
    local p="${rest%%|*}"; local api="${rest##*|}"
    printf '\033[0;36m>> Logging in to %s ...\033[0m\n' "$token"
    oc login -u "$u" -p "$p" "$api" --insecure-skip-tls-verify=true >/dev/null 2>&1 \
        || { echo "ERROR: login failed for '$token' ($api)" >&2; return 1; }
}
