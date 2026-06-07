#!/usr/bin/env bash
#
# Fetch the openRuyi minimal OCI image and `podman import` it as the local image
# build-with-container.py's DefaultImage.OPENRUYI points at.
#
# The tarball is the official openRuyi rootfs published by the openruyi:mkosi
# OBS project.
#
# Env overrides:
#   OPENRUYI_IMAGE      target local image tag (default localhost/openruyi-oci:riscv64)
#   OPENRUYI_IMAGE_URL  tarball URL
#   OPENRUYI_CACHE_DIR  where to cache the downloaded tarball
#   CONTAINER_ENGINE    podman (default) or docker
#   OFFLINE=1           skip the download; re-import the cached tarball (or reuse
#                       the existing local image if no cache is present)
#
# By default this checks upstream every run so an updated tarball is picked up:
# the tarball URL is mutable, and a plain "image exists" check by name would keep
# a stale local image forever. The download is conditional (If-Modified-Since
# against the cached tarball), so when nothing changed the server returns 304 and
# no bytes are transferred.
set -euo pipefail

# Pick the OBS mkosi build by host RISC-V profile: RVA23 (SG2044, has 'v') ->
# mkosi/riscv64; RVA20 (SG2042, no 'v') -> mkosi/rva20 (RVA23 binaries SIGILL on
# a no-V host). Local tag stays :riscv64 (bwc's DefaultImage.OPENRUYI hardcodes it).
_isa="${OPENRUYI_BASELINE:-$(grep -m1 -oE 'rv64[a-z]+' /proc/cpuinfo)}"
case "${_isa#rv64}" in   # strip 'rv64' prefix so its 'v' can't false-match
    *v*) BASELINE=riscv64 ;;
    *)   BASELINE=rva20 ;;
esac

IMAGE_TAG="${OPENRUYI_IMAGE:-localhost/openruyi-oci:riscv64}"
IMAGE_URL="${OPENRUYI_IMAGE_URL:-https://repo.build.openruyi.cn/openruyi:/mkosi/${BASELINE}/openruyi-oci_riscv64.tar}"
CACHE_DIR="${OPENRUYI_CACHE_DIR:-${HOME}/.cache/ceph-ci}"
ENGINE="${CONTAINER_ENGINE:-podman}"
TARBALL="${CACHE_DIR}/$(basename "${IMAGE_URL}")"

if [ "$(uname -m)" != riscv64 ]; then
    echo "WARNING: host arch is $(uname -m), not riscv64." >&2
    echo "         The openRuyi image is riscv64-only; this CI must run natively on riscv64." >&2
fi

if [ "${OFFLINE:-0}" = 1 ]; then
    if [ -f "${TARBALL}" ]; then
        echo "OFFLINE=1: re-importing cached ${TARBALL}; skipping download"
    elif "${ENGINE}" image exists "${IMAGE_TAG}" 2>/dev/null; then
        echo "OFFLINE=1: no cached tarball, using existing local image ${IMAGE_TAG}"
        exit 0
    else
        echo "OFFLINE=1 but neither cached tarball nor local image exists; cannot continue" >&2
        exit 1
    fi
else
    mkdir -p "${CACHE_DIR}"
    # Conditional download: -z makes curl send If-Modified-Since from the cached
    # tarball's mtime, so an unchanged upstream answers 304 and we keep the cache.
    declare -a COND_ARGS=()
    [ -f "${TARBALL}" ] && COND_ARGS=(-z "${TARBALL}")
    echo "Downloading ${IMAGE_URL} (conditional on cached copy)"
    http_code="$(curl -fSL --retry 3 --retry-delay 5 "${COND_ARGS[@]}" \
        -o "${TARBALL}.part" -w '%{http_code}' "${IMAGE_URL}")"
    if [ "${http_code}" = 304 ]; then
        echo "upstream unchanged (HTTP 304); using cached ${TARBALL}"
        rm -f "${TARBALL}.part"
    else
        mv -f "${TARBALL}.part" "${TARBALL}"
    fi
fi

echo "Importing ${TARBALL} -> ${IMAGE_TAG}"
"${ENGINE}" import "${TARBALL}" "${IMAGE_TAG}"
echo "OK: ${IMAGE_TAG}"
