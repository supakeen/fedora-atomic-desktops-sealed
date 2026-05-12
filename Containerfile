# SPDX-FileCopyrightText: Timothée Ravier <tim@siosm.fr>
# SPDX-License-Identifier: CC0-1.0

ARG BASE=overridden
ARG SYSTEMDBOOT=overridden
ARG TOOLS=overridden

FROM $SYSTEMDBOOT as systemd-boot

FROM $BASE as rootfs

ARG TARGETARCH

RUN --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var \
    <<EORUN
set -euxo pipefail

# We can not ship openh264 in the image
rm -f "/etc/yum.repos.d/fedora-cisco-openh264.repo"

# Install fsverity utils to make it easier to check things
# Install systemd-boot (will be replaced by the signed version in a later stage)
dnf install -y fsverity-utils systemd-boot-unsigned

# Remove rpm-ostree and the backends in GNOME Software and Plasma Discover
dnf remove -y \
    rpm-ostree \
    rpm-ostree-libs \
    gnome-software-rpm-ostree \
    plasma-discover-rpm-ostree

# Install latest bootc release
dnf upgrade -y --enablerepo=updates-testing --refresh bootc

## Get fixed bootc build for image-builder
dnf install -y 'dnf*-command(copr)'
dnf copr enable -y packit/bootc-dev-bootc-2191-full fedora-44-x86_64
dnf install -y bootc-202605092003.g8af07fe58a-1.fc44.x86_64

# Uninstall bootupd (no support for systemd-boot yet)
rpm -e bootupd
rm -vrf "/usr/lib/bootupd/updates"

# Mount the root filesystem read-write
# Enable btrfs compression
cat > "/usr/lib/bootc/kargs.d/10-rootfs.toml" << 'EOF'
kargs = ["rw", "rootflags=compress=zstd:1"]
EOF

# Default to btrfs
cat > "/usr/lib/bootc/install/80-rootfs.toml" << 'EOF'
[install.filesystem.root]
type = "btrfs"
EOF

# Dracut will always fail to set security.selinux xattrs at build time
# https://github.com/dracut-ng/dracut-ng/issues/1561
cat > "/usr/lib/dracut/dracut.conf.d/20-bootc-base.conf" << 'EOF'
export DRACUT_NO_XATTR=1
EOF

# Enable composefs backend in dracut
cat > "/usr/lib/dracut/dracut.conf.d/20-bootc-composefs.conf" << 'EOF'
add_dracutmodules+=" bootc "
EOF

# Include systemd's hwdb
# See: https://github.com/systemd/systemd/issues/40159
# See: https://github.com/systemd/systemd/issues/40485
# cat > "/usr/lib/dracut/dracut.conf.d/20-bootc-composefs.conf" << 'EOF'
# install_items+=" /etc/udev/hwdb.bin "
# EOF

# Rebuild the initramfs to get bootc-initramfs-setup
kver=$(cd "/usr/lib/modules" && echo *)
dracut -vf --install "/etc/passwd /etc/group" "/usr/lib/modules/$kver/initramfs.img" "$kver"

# Prepare folders in /boot
mkdir -p /boot/EFI/Linux

###############################################################################
# Changes for development go here

# Enable sshd for bcvk
systemctl enable sshd.service

# Disable root password
passwd -d root

# Enable systemd debug shell for the initrd & final system
cat > "/usr/lib/bootc/kargs.d/10-debug.toml" << 'EOF'
kargs = ["rd.systemd.debug_shell", "systemd.debug_shell"]
EOF

# Mask some systemd units that currently do not work well with some TPMs
# See: https://github.com/systemd/systemd/issues/40159
# See: https://github.com/systemd/systemd/issues/40485
cat > "/usr/lib/bootc/kargs.d/10-tpm2-workaround.toml" << 'EOF'
kargs = [
  "rd.systemd.mask=systemd-tpm2-setup-early.service",
  "systemd.mask=systemd-tpm2-setup-early.service",
  "systemd.mask=systemd-tpm2-setup.service",
  "systemd.mask=systemd-pcrphase.service",
  "systemd.mask=systemd-pcrproduct.service",
]
EOF

# Set up image-builder meta information for the base partition table that
# should be created
mkdir -p /usr/lib/image-builder/bootc

cat > "/usr/lib/image-builder/bootc/disk.yaml" << 'EOF'
partition_table:
  type: "gpt"
  partitions:
    - size: "2 GiB"
      type: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
      payload_type: "filesystem"
      payload:
        type: vfat
        mountpoint: "/boot/efi"
        label: "EFI-SYSTEM"
    - size: "10 GiB"
      payload_type: "filesystem"
      payload:
        label: "root"
        mountpoint: "/"
EOF

if [ "${TARGETARCH}" == "amd64" ]; then
cat >> "/usr/lib/image-builder/bootc/disk.yaml" << 'EOF'
      type: "4f68bce3-e8cd-4db1-96e7-fbcaf984b709"
EOF
elif [ "${TARGETARCH}" == "arm64" ]; then
cat >> "/usr/lib/image-builder/bootc/disk.yaml" << 'EOF'
      type: "b921b045-1df0-41c3-af44-4c6f280d3fae"
EOF
fi
###############################################################################
EORUN

# Replace Fedora's systemd-boot with our signed one
COPY --from=systemd-boot /systemd-bootx64.efi /usr/lib/systemd/boot/efi/systemd-bootx64.efi

FROM rootfs as lint
RUN bootc container lint

# Rechunk container image to ensure that we compute the correct composefs hash
# - Use more layers (128)
# - Ignore legacy ostree folders
FROM quay.io/coreos/chunkah AS chunkah
RUN --mount=from=rootfs,src=/,target=/chunkah,ro \
    --mount=type=bind,target=/run/src,rw \
        chunkah build \
            --max-layers 128 \
            --prune /ostree \
            --prune /sysroot/ostree \
            > /run/src/out.ociarchive

FROM oci-archive:out.ociarchive as rootfs-chunked
LABEL containers.bootc 1
LABEL org.opencontainers.image.title="Fedora Atomic Desktop Sealed"
LABEL org.opencontainers.image.source="https://github.com/travier/fedora-atomic-desktops-sealed"
LABEL org.opencontainers.image.licenses="MIT"
LABEL quay.expires-after="4w"
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

FROM $TOOLS as sealed-uki
RUN --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var/tmp \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_crt \
    --mount=type=bind,from=rootfs-chunked,src=/,target=/run/target \
    <<EORUN
set -euxo pipefail

target="/run/target"
output="/boot/EFI/Linux"
secrets="/run/secrets"

# Find the kernel version (needed for output filename)
kver=$(bootc container inspect --rootfs "${target}" --json | jq -r '.kernel.version')
if [ -z "$kver" ] || [ "$kver" = "null" ]; then
  echo "Error: No kernel found" >&2
  exit 1
fi

# Baseline ukify options
ukifyargs=(
    --measure
    --json pretty
    --output "${output}/${kver}.efi"
)

# Signing options, we use sbsign by default
ukifyargs+=(
    --signtool sbsign
    --secureboot-private-key "${secrets}/secureboot_key"
    --secureboot-certificate "${secrets}/secureboot_crt"
)

# Baseline container ukify options
containerukifyargs=(--rootfs "${target}")

# Build the UKI using bootc container ukify
# This computes the composefs digest, reads kargs from kargs.d, and invokes ukify
bootc container ukify "${containerukifyargs[@]}" -- "${ukifyargs[@]}"
EORUN

# Copy UKI to our final image
FROM rootfs-chunked as final
COPY --from=sealed-uki /boot/EFI/Linux /boot/EFI/Linux
