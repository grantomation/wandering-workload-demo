#!/usr/bin/env bash
#
# 01-switch-cluster.sh — quickly switch between OpenShift clusters.
# Usage: ./scripts/migration/01-switch-cluster.sh ARO|ROSA|GCP|HUB|ONPREM
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CREDS_FILE="${CREDS_FILE:-$REPO_ROOT/credentials.env}"

if [[ ! -f "$CREDS_FILE" ]]; then
    echo "ERROR: credentials file not found: $CREDS_FILE" >&2
    echo "Copy credentials.env.example to credentials.env and fill in the values." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CREDS_FILE"

usage() {
    printf 'Usage: %s <ARO|ROSA|GCP|HUB|ONPREM>\n' "$(basename "$0")"
    exit 1
}

[[ $# -eq 1 ]] || usage

TARGET="$(echo "$1" | tr '[:lower:]' '[:upper:]')"

case "${TARGET}" in
    HUB)
        LABEL="HUB (ACM on ROSA)"
        USER="$HUB_USER"
        PASS="$HUB_PASS"
        API="$HUB_API"
        ;;
    ARO)
        LABEL="ARO Spoke 1"
        USER="$ARO_USER"
        PASS="$ARO_PASS"
        API="$ARO_API"
        ;;
    ROSA)
        LABEL="ROSA Spoke 1"
        USER="$ROSA_USER"
        PASS="$ROSA_PASS"
        API="$ROSA_API"
        ;;
    GCP)
        LABEL="OSD on GCP"
        USER="$GCP_USER"
        PASS="$GCP_PASS"
        API="$GCP_API"
        ;;
    ONPREM)
        LABEL="On-Premise"
        USER="$ONPREM_USER"
        PASS="$ONPREM_PASS"
        API="$ONPREM_API"
        ;;
    *)
        printf 'Unknown cluster: %s\n\n' "$1"
        usage
        ;;
esac

oc logout >/dev/null 2>&1 || true

printf '\033[0;36m>> Logging in to %s ...\033[0m\n' "${LABEL}"
oc login -u "${USER}" -p "${PASS}" "${API}" --insecure-skip-tls-verify=true

echo
printf '\033[1;33m######################################################################\033[0m\n'
printf '\033[1;33m#\033[0m\n'
printf '\033[1;33m#  \033[1;97m%s\033[0m\n' "${LABEL}"
printf '\033[1;33m#  \033[0;36mServer: \033[0;37m%s\033[0m\n' "$(oc whoami --show-server)"
printf '\033[1;33m#  \033[0;36mUser:   \033[0;37m%s\033[0m\n' "$(oc whoami)"
printf '\033[1;33m#\033[0m\n'
printf '\033[1;33m######################################################################\033[0m\n'
echo
