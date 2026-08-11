#!/bin/sh
set -eu

# Boot-time platform detection: ensures /etc/network/interfaces matches
# the current hypervisor BEFORE the networking service starts.
#   KVM (OpenShift/KubeVirt) → DHCP  (masquerade networking provides 10.0.2.x)
#   VMware                   → no change (vmware-network service handles static later)
#   Unknown                  → no change

IFACE="eth0"
CONF="/etc/network/interfaces"

PLATFORM="unknown"
if command -v virt-what >/dev/null 2>&1; then
    VW=$(virt-what 2>/dev/null || true)
    case "${VW}" in
        *vmware*) PLATFORM="vmware" ;;
        *kvm*)    PLATFORM="kvm" ;;
    esac
fi

echo "[platform-network] platform=${PLATFORM}"

case "${PLATFORM}" in
    kvm)
        echo "[platform-network] Writing DHCP config for KubeVirt masquerade"
        cat > "${CONF}" <<EOF
auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet dhcp
EOF
        ;;
    vmware)
        echo "[platform-network] VMware detected — keeping current config"
        ;;
    *)
        echo "[platform-network] Unknown platform — no changes"
        ;;
esac
