#!/bin/sh
echo "=== Restarting Wandering Workload Frontend ==="
echo "[RESTART] Stopping service..."
rc-service wandering-workload stop 2>&1
echo "[RESTART] Re-resolving DB host..."
. /etc/wandering-workload.env
if command -v virt-what >/dev/null 2>&1 && virt-what 2>/dev/null | grep -q vmware; then
    RESOLVED=$(avahi-resolve -4 --name "${DB_HOST}.local" 2>/dev/null | awk '{print $2}')
    if [ -n "${RESOLVED}" ]; then
        echo "[RESTART] Resolved ${DB_HOST}.local -> ${RESOLVED}"
    else
        echo "[RESTART] Could not resolve ${DB_HOST}.local, using ${DB_HOST}"
    fi
else
    echo "[RESTART] Not on VMware, using ${DB_HOST}"
fi
echo "[RESTART] Starting service..."
rc-service wandering-workload start 2>&1
STATUS=$(rc-service wandering-workload status 2>&1)
echo "[RESTART] ${STATUS}"
echo "=== Done ==="
