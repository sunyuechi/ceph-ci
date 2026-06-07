#!/usr/bin/env bash
#
# (Re)publish the openRuyi minimal OCI image to the registry.
#
# Builds the openRuyi minimal OCI base and pushes it so CI hosts can pull it via
# fetch-openruyi-image.sh. rva23: import the official openruyi:mkosi rootfs
# tarball. rva20: bootstrap a rootfs from the openruyi/rva20 repo (the mkosi
# rva20 image is out of sync with that repo -- see the rva20 block below).
# Must run natively on riscv64.
#
# Env overrides:
#   OPENRUYI_REGISTRY_IMAGE  push target (default community-ci.openruyi.cn/openruyi-oci:<baseline>)
#   OPENRUYI_IMAGE_URL       rva23 OBS rootfs tarball URL
#   OPENRUYI_RVA20_REPO      rva20 bootstrap repo (default repo.build.openruyi.cn/openruyi/rva20/)
#   OPENRUYI_BASELINE        riscv64 (RVA23, has V) or rva20 (no V); default: host ISA
#   OPENRUYI_CACHE_DIR       where to cache the rva23 tarball
#   CONTAINER_ENGINE         podman (default) or docker
set -euo pipefail

# Publish the build matching this host's RISC-V profile: RVA23 hosts (SG2044, has
# 'v') push :riscv64 from mkosi/riscv64; RVA20 hosts (SG2042, no 'v') push :rva20
# from mkosi/rva20. Override with OPENRUYI_BASELINE.
_isa="${OPENRUYI_BASELINE:-$(grep -m1 -oE 'rv64[a-z]+' /proc/cpuinfo)}"
case "${_isa#rv64}" in   # strip 'rv64' prefix so its 'v' can't false-match
    *v*) BASELINE=riscv64 ;;
    *)   BASELINE=rva20 ;;
esac

REGISTRY_IMAGE="${OPENRUYI_REGISTRY_IMAGE:-community-ci.openruyi.cn/openruyi-oci:${BASELINE}}"
IMAGE_URL="${OPENRUYI_IMAGE_URL:-https://repo.build.openruyi.cn/openruyi:/mkosi/${BASELINE}/openruyi-oci_riscv64.tar}"
CACHE_DIR="${OPENRUYI_CACHE_DIR:-${HOME}/.cache/ceph-ci}"
ENGINE="${CONTAINER_ENGINE:-podman}"
TARBALL="${CACHE_DIR}/$(basename "${IMAGE_URL}")"

if [ "$(uname -m)" != riscv64 ]; then
    echo "ERROR: host arch is $(uname -m), not riscv64." >&2
    echo "       The openRuyi image is riscv64-only; publish from a riscv64 host." >&2
    exit 1
fi

if [ "${BASELINE}" = rva20 ]; then
    # The mkosi rva20 OCI image runs ahead of the openruyi/rva20 package repo
    # (image has gnutls split into gnutls-libs-11.x; the repo still ships the
    # merged gnutls-5.x), so installing deps on top of it hits libgnutls.so file
    # conflicts. Until openRuyi publishes a matching rva20 image, bootstrap a
    # same-generation minimal rootfs straight from the repo instead.
    RVA20_REPO="${OPENRUYI_RVA20_REPO:-https://repo.build.openruyi.cn/openruyi/rva20/}"
    . /etc/os-release   # VERSION_ID -> dnf --releasever
    ROOT="$(mktemp -d)"
    trap 'rm -rf "${ROOT}"' EXIT
    echo "Bootstrapping rva20 rootfs from ${RVA20_REPO}"
    dnf -y --installroot="${ROOT}" --releasever="${VERSION_ID:-Creek}" \
        --disablerepo='*' --repofrompath="base,${RVA20_REPO}" \
        --setopt=base.gpgcheck=0 --nogpgcheck \
        install bash dnf5 rpm coreutils curl openruyi-release
    # The minimal install ships no repo file; point Base at the repo we used.
    mkdir -p "${ROOT}/etc/yum.repos.d"
    printf '[Base]\nname=openruyi Base\nbaseurl=%s\nenabled=1\ngpgcheck=0\n' \
        "${RVA20_REPO}" > "${ROOT}/etc/yum.repos.d/openruyi.repo"
    # The %openruyi spec guard ships only in the temp-OBS openruyi-release (2-10.x),
    # not the stock 2-5.2; without it ceph.spec takes the non-openRuyi BuildRequires
    # path (Fedora names -> "No match"). sg2042 runs TEMP_OBS_REPO=0 (no temp repo,
    # to avoid its rva23 binaries), so seed the flag directly. Drop once the stock
    # rva20 openruyi-release ships macros.openruyi.
    mkdir -p "${ROOT}/usr/lib/rpm/macros.d"
    printf '%%openruyi 1\n' > "${ROOT}/usr/lib/rpm/macros.d/macros.openruyi"
    echo "Importing bootstrapped rootfs -> ${REGISTRY_IMAGE}"
    tar -C "${ROOT}" -c . | "${ENGINE}" import - "${REGISTRY_IMAGE}"
else
    # rva23: the official openruyi:mkosi rootfs tarball matches stable/rva23.
    mkdir -p "${CACHE_DIR}"
    echo "Downloading ${IMAGE_URL}"
    curl -fSL --retry 3 --retry-delay 5 -o "${TARBALL}.part" "${IMAGE_URL}"
    mv -f "${TARBALL}.part" "${TARBALL}"
    echo "Importing ${TARBALL} -> ${REGISTRY_IMAGE}"
    "${ENGINE}" import "${TARBALL}" "${REGISTRY_IMAGE}"
fi

echo "Pushing ${REGISTRY_IMAGE}"
"${ENGINE}" push "${REGISTRY_IMAGE}"
echo "OK: pushed ${REGISTRY_IMAGE}"
