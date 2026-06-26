# The Alpine Golden (the "smaller OS" path)

How we build a **much smaller** golden VM image by swapping Fedora Cloud Base for
**Alpine Linux**. Same idea as the Fedora playbooks (build a generic golden offline
on a Linux KVM/libvirt host, assign a role per-clone later, migrate via MTV) — just
on a ~1/6th-the-size base. Building locally with libvirt + virt-customize avoids
repeated slow uploads to vCenter during iteration; only the final VMDK is pushed.

## Why Alpine

We exhausted every way to shrink the **Fedora** golden (see memory
`golden-disk-shrink`) and hit a hard floor of **~1.7 GB**:

- virt-builder → 6 GB template minimum
- kickstart `@core` ext4 → 1.38 GB base (heavier than Cloud Base)
- btrfs→ext4 conversion → Cloud Base's `compress=zstd:1` means its 700 MB is
  *compressed*; uncompressed it's 1.2 GB, so ext4 wins nothing.

The only lever left was a smaller **OS**. Alpine is the smallest base that can
still actually host the app (CirrOS can't — no package manager).

| OS | golden used | notes |
|---|---|---|
| Fedora Cloud Base | ~700 MB (zstd) / 1.2 GB raw | 1.7 GB shrunk disk |
| **Alpine 3.21** | **194 MB** | this doc |

Our app is portable: `server.js` is just `express` + `pg` (pure JS, **no native
modules**), so musl is a non-issue for the code.

## What we proved (boot test, 2026-06-19)

Built `wandering_alpine.qcow2` and snapshot-booted it locally:

- ✅ Boots — Alpine 3.21.2, kernel **`6.12.8-0-virt`** (virtio-optimized flavor)
- ✅ **`virtio_net` + `virtio_blk` loaded** — the canary for MTV **raw-copy**
- ✅ `ansible-core` 2.18.1 runs; repo at `/root/wandering_workload`
- ✅ `root` user only (SSH `PermitRootLogin yes` enabled)
- ✅ **194 MB used**
- ⚠️ `qemu-guest-agent [crashed]` — expected on a bare boot (needs the
  virtio-serial channel, present on OpenShift CNV, not on plain qemu/VMware).
  Verify post-migration.

## Building it

Playbook: **`ansible/golden-images/alpine/golden.yml`** (kept in a separate
`alpine/` folder; artifacts land in `<repo>/build-output/alpine/` by default —
override with `-e golden_base=/my/path`).

```bash
cd wandering_workload/ansible/golden-images/alpine
ansible-playbook golden_alpine.yml
# if the cloud-image URL 404s (Alpine moves fast), bump the version:
ansible-playbook golden_alpine.yml -e alpine_rel=3.21.3
```

What it does:

1. **Download** the Alpine *Generic Cloud* image (uefi + cloud-init, ext4 root).
2. **Expand** it into a 3 GB working disk (`virt-resize --expand`) — see gotcha
   below.
3. **Customize** offline with `virt-customize` (apk install, passwords, repo).
4. **Seal** (`virt-sysprep`) + sparsify.
5. **Shrink** the ext4 back down to `target_size` (default 640 MB):
   `e2fsck -f` + `resize2fs -M` (pre-shrink the fs), then `virt-resize --shrink`.
6. Report size. **No VMDK** — boot-test the shrunk image first.

## Alpine-specific gotchas (vs the Fedora golden)

- **apk works through `virt-customize`.** libguestfs 1.55 supports Alpine. But
  enable the **community repo first** (`sed -i 's,^#\(.*/community\),\1,'
  /etc/apk/repositories`) — `ansible-core` lives there.
- **Expand before installing.** The Alpine cloud image ships a *tiny* root
  partition, and built **offline**, cloud-init's `growpart` never runs — so
  `apk add ansible-core` (~167 MB of deps) overflows it with `No space left on
  device`. We `virt-resize --expand` into 3 GB first, then shrink back at the end.
- **No extra user:** We run everything as `root` and enable `PermitRootLogin yes`.
- **OpenRC, not systemd:** `rc-update add qemu-guest-agent default` (not
  `systemctl enable`).
- **apk cache:** `rm -rf /var/cache/apk/*` (not `dnf clean all`).
- **ext4 shrink** is the same two-step as the Fedora ext4 attempts: `virt-resize`
  shrinks the partition but **not** the filesystem, so `resize2fs -M` first.

## Local testing (before VMDK)

### Option A — quick throwaway (raw qemu, serial console)

```bash
cp /usr/share/edk2/ovmf/OVMF_VARS.fd /tmp/alpine_vars.fd
sudo qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -m 1024 -snapshot \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/tmp/alpine_vars.fd \
  -drive file=<golden_base>/alpine/wandering_alpine.qcow2,format=qcow2,if=virtio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 -nographic
```
- Login `root` / `openshift`. Exit qemu: `Ctrl-a` then `x`.
- `-snapshot` = changes discarded. This does **not** appear in virt-manager
  (it's not a libvirt domain).

### Option B — in virt-manager (libvirt domain, persistent copy)

```bash
sudo virsh destroy alpine-test 2>/dev/null; sudo virsh undefine alpine-test --nvram 2>/dev/null
sudo cp <golden_base>/alpine/wandering_alpine.qcow2 \
        /var/lib/libvirt/images/alpine-test.qcow2
sudo virt-install --name alpine-test --memory 1024 --vcpus 2 \
  --disk path=/var/lib/libvirt/images/alpine-test.qcow2,bus=virtio \
  --import --os-variant alpinelinux3.20 \
  --boot loader=/usr/share/edk2/ovmf/OVMF_CODE.fd,loader.readonly=yes,loader.type=pflash,nvram.template=/usr/share/edk2/ovmf/OVMF_VARS.fd \
  --network network=default,model=virtio --graphics spice --noautoconsole
```
- (`--os-variant linux2022` if `alpinelinux3.20` is unknown.)
- **Use the explicit plain-OVMF `--boot loader=...`, NOT `--boot uefi`.** `--boot
  uefi` selects the **Secure Boot** firmware, and Alpine's grub is **unsigned** →
  "No bootable device." The image itself is fine (the ESP has
  `EFI/boot/bootx64.efi`); it just needs Secure Boot off.
- In virt-manager the **graphical console is blank** (Alpine is serial-first) —
  use **View → Consoles → Serial 1**, or `sudo virsh console alpine-test`.
- Teardown: `sudo virsh destroy alpine-test; sudo virsh undefine alpine-test
  --nvram; sudo rm -f /var/lib/libvirt/images/alpine-test.qcow2`

### In-VM checks
```bash
cat /etc/alpine-release            # booted Alpine
lsmod | grep virtio                # virtio present (raw-copy canary)
ansible --version                  # ansible-core baked in
rc-status                          # services (qemu-guest-agent crash = expected)
ls /root/wandering_workload        # repo copied in
df -h                              # root usage
```

## Convert to VMDK (after the shrunk image boots clean)

```bash
sudo qemu-img convert -f qcow2 -O vmdk -o subformat=monolithicSparse \
  <golden_base>/alpine/wandering_alpine.qcow2 \
  <golden_base>/alpine/wandering_alpine.vmdk
```

## Navigating & testing Alpine (Fedora/systemd → Alpine cheat-sheet)

Alpine is **busybox + OpenRC + musl + apk**. If your fingers type `systemctl`,
here's the translation.

### Services (OpenRC, not systemd)

| You want | Fedora (systemd) | Alpine (OpenRC) |
|---|---|---|
| Status of a service | `systemctl status sshd` | `rc-service sshd status` |
| Start / stop / restart | `systemctl restart sshd` | `rc-service sshd restart` |
| Reload | `systemctl reload sshd` | `rc-service sshd reload` |
| Enable at boot | `systemctl enable sshd` | `rc-update add sshd default` |
| Disable at boot | `systemctl disable sshd` | `rc-update del sshd default` |
| List all services + state | `systemctl` | `rc-status -a` |
| What's running now | `systemctl list-units` | `rc-status` |
| Service scripts live in | `/etc/systemd/system` | `/etc/init.d/` |

`[ crashed ]` in `rc-status` = the service exited unexpectedly (e.g.
`qemu-guest-agent` with no virtio-serial channel — expected on a bare boot).

### Logs (no journald)

| | |
|---|---|
| Kernel ring buffer | `dmesg` |
| System log | `tail -f /var/log/messages` (busybox `syslogd`; `rc-service syslog start` if empty) |
| A service's output | run it in the foreground: `/etc/init.d/<svc> start` shows errors; or check `/var/log/` |
| **No** `journalctl` | use `/var/log/messages` |

### Packages (apk, not dnf)

```sh
apk update                 # refresh index
apk add curl postgresql    # install
apk del curl               # remove
apk info                   # list installed
apk info -L nodejs         # files in a package
apk search nginx           # search
apk upgrade                # upgrade all
```
Repos are in `/etc/apk/repositories` — `main` + `community` (community is where
`ansible-core`, `nodejs`, etc. live; the golden already enables it).

### Network (busybox ifupdown, not NetworkManager)

| | |
|---|---|
| Show addresses | `ip addr` (`ifconfig` also works) |
| Show routes | `ip route` |
| Config file | `/etc/network/interfaces` (NOT nmcli/netplan) |
| Bring iface up/down | `ifup eth0` / `ifdown eth0` |
| DNS | `/etc/resolv.conf` |
| **No** `nmcli` | static IPs go in `/etc/network/interfaces` |

### Testing the app

`curl` is **not** installed by default (busybox `wget` is). Either:
```sh
apk add curl
curl -i http://localhost/        # or /health once the app is deployed
# ...or with the built-in:
wget -qO- http://localhost/health
```
Check what's listening: `ss -ltnp` (or `netstat -ltnp`).

### Shell / editor gotchas

- `/bin/sh` is **busybox ash**, not bash. Scripts with `#!/bin/bash` need
  `apk add bash`.
- Default editor is busybox `vi`; `apk add nano` if you prefer.
- `adduser -D name` (no password) / `addgroup`; not `useradd`.
- `sudo` is installed in the golden; stock Alpine ships `doas` instead.
- No `systemd-detect-virt` — the role playbooks' env-detect uses it, so the
  Alpine rewrite needs `apk add virt-what` (or read `/sys/class/dmi/id/sys_vendor`).

### Quick "is the golden healthy" pass (run after logging in)

```sh
cat /etc/alpine-release            # which Alpine
rc-status                          # services up
lsmod | grep virtio                # virtio present (raw-copy canary)
ansible --version                  # ansible-core baked in
ls /root/wandering_workload        # repo copied in
ip addr; ip route                  # networking
df -h /                            # disk usage
```

## Open items / TODO

- **Role playbooks need an Alpine rewrite.** `frontend/backend/combined.yml` use
  **systemd units + `nmcli`**; Alpine is **OpenRC + busybox ifupdown**. None of
  that runs as-is. (Deferred — the golden is built; role assignment is next.)
- **Secure Boot must be OFF everywhere.** Alpine's grub is unsigned, so the VMware
  VM (EFI, Secure Boot disabled) and OpenShift CNV
  (`domain.firmware.bootloader.efi.secureBoot: false`) must both disable it, or
  boot fails with "No bootable device". Confirmed: the image boots clean under
  plain (non-secboot) OVMF.
- **MTV raw-copy must be proven on a clone.** virtio is in the `-virt` kernel, so
  it has a real shot, but confirm the "Convert image to kubevirt" phase is absent
  and it boots clean after migration.
- **`qemu-guest-agent`** — confirm it runs on OpenShift CNV (where the
  virtio-serial channel exists).
- **ansible stays in the golden** deliberately: the single VMDK upload to VMware
  takes hours, so we upload one generic golden and assign roles per-clone.
