#!/usr/bin/env bash
#
# (Re)publish the openRuyi minimal OCI image to the registry.
#
# Fetches the openRuyi rootfs tarball from the openruyi:mkosi OBS project,
# imports it, and pushes it so CI hosts can pull it via fetch-openruyi-image.sh.
# Must run natively on riscv64.
#
# Env overrides:
#   OPENRUYI_REGISTRY_IMAGE  push target (default community-ci.openruyi.cn/openruyi-oci:riscv64)
#   OPENRUYI_IMAGE_URL       OBS rootfs tarball URL
#   OPENRUYI_CACHE_DIR       where to cache the downloaded tarball
#   CONTAINER_ENGINE         podman (default) or docker
set -euo pipefail

REGISTRY_IMAGE="${OPENRUYI_REGISTRY_IMAGE:-community-ci.openruyi.cn/openruyi-oci:riscv64}"
IMAGE_URL="${OPENRUYI_IMAGE_URL:-https://repo.build.openruyi.cn/openruyi:/mkosi/riscv64/openruyi-oci_riscv64.tar}"
CACHE_DIR="${OPENRUYI_CACHE_DIR:-${HOME}/.cache/ceph-ci}"
ENGINE="${CONTAINER_ENGINE:-podman}"
TARBALL="${CACHE_DIR}/$(basename "${IMAGE_URL}")"

if [ "$(uname -m)" != riscv64 ]; then
    echo "ERROR: host arch is $(uname -m), not riscv64." >&2
    echo "       The openRuyi image is riscv64-only; publish from a riscv64 host." >&2
    exit 1
fi

mkdir -p "${CACHE_DIR}"
echo "Downloading ${IMAGE_URL}"
curl -fSL --retry 3 --retry-delay 5 -o "${TARBALL}.part" "${IMAGE_URL}"
mv -f "${TARBALL}.part" "${TARBALL}"

echo "Importing ${TARBALL} -> ${REGISTRY_IMAGE}"
"${ENGINE}" import "${TARBALL}" "${REGISTRY_IMAGE}"

echo "Pushing ${REGISTRY_IMAGE}"
"${ENGINE}" push "${REGISTRY_IMAGE}"
echo "OK: pushed ${REGISTRY_IMAGE}"
