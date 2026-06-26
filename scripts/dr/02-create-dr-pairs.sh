#!/usr/bin/env bash
#
# 02-create-dr-pairs.sh — create Portworx DisasterRecoveryPair resources on the
# ACM hub cluster. Skips any pair that already exists.
#
set -euo pipefail

NAMESPACE="portworx"
API_GROUP="multicluster.portworx.com"
DR_RESOURCE="disasterrecoverypairs.${API_GROUP}"

# --- Load credentials (S3 keys come from credentials.env) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# --- DR pairs: "name  sourceCluster  destinationCluster" ---
DR_PAIRS=(
  "on-prem-aro   on-prem  aro"
  "aro-rosa      aro      rosa"
  "rosa-gcp      rosa     gcp"
  "gcp-on-prem   gcp      on-prem"
)

# --- Optional: create just ONE pair by name. Omit to create all. ---
#   ./scripts/01_create_dr_pairs.sh rosa-gcp
TARGET="${1:-}"
if [[ -n "${TARGET}" ]]; then
    valid=false
    for entry in "${DR_PAIRS[@]}"; do
        read -r n _ _ <<< "${entry}"
        [[ "${n}" == "${TARGET}" ]] && valid=true
    done
    if ! ${valid}; then
        echo "ERROR: unknown DR pair '${TARGET}'." >&2
        echo "       Valid: on-prem-aro, aro-rosa, rosa-gcp, gcp-on-prem (omit to create all)." >&2
        exit 1
    fi
fi

# --- Login to hub ---
printf '\033[0;36m>> Logging in to HUB...\033[0m\n'
if ! login_cluster hub; then
    echo "ERROR: failed to login to hub" >&2
    exit 1
fi

CLUSTER_API="$(oc whoami --show-server)"
CLUSTER_USER="$(oc whoami)"

printf '\n'
printf '\033[1;33m######################################################################\033[0m\n'
printf '\033[1;33m#\033[0m\n'
printf '\033[1;33m#  \033[1;97mHUB: %s\033[0m\n' "${CLUSTER_API}"
printf '\033[1;33m#  \033[0;36mUser: \033[0;37m%s\033[0m\n' "${CLUSTER_USER}"
printf '\033[1;33m#\033[0m\n'
printf '\033[1;33m######################################################################\033[0m\n'
echo

created=0
skipped=0

for entry in "${DR_PAIRS[@]}"; do
    read -r name src dst <<< "${entry}"

    # When a single pair was requested, skip everything else.
    [[ -n "${TARGET}" && "${name}" != "${TARGET}" ]] && continue

    if oc get "${DR_RESOURCE}" "${name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        printf '\033[0;33m⏭  %s already exists — skipping\033[0m\n' "${name}"
        skipped=$((skipped+1))
        continue
    fi

    printf '\033[0;36m>> Creating DR pair: %s  (%s → %s)\033[0m\n' "${name}" "${src}" "${dst}"
    oc apply -f - <<EOF
apiVersion: ${API_GROUP}/v1alpha1
kind: DisasterRecoveryPair
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
spec:
  backupLocation:
    s3Config:
      accessKeyID: ${S3_ACCESS_KEY}
      bucketName: ${S3_BUCKET}
      disableSSL: false
      endpoint: ${S3_ENDPOINT}
      region: ${S3_REGION}
      secretAccessKey: ${S3_SECRET_KEY}
      useIam: false
    type: s3
  destinationCluster: ${dst}
  disasterRecoveryType: ASYNC
  pairType: BI-DIRECTIONAL
  sourceCluster: ${src}
EOF
    created=$((created+1))
done

echo
printf '\033[1;32m>> Done — created: %d, skipped (already existed): %d\033[0m\n' "${created}" "${skipped}"
