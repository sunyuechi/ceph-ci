#!/usr/bin/env bash
#
# Pull the openRuyi minimal OCI image from the registry and tag it as the
# local image build-with-container.py's DefaultImage.OPENRUYI points at.
# (Re)publish the image with scripts/publish-openruyi-image.sh.
#
# Env overrides:
#   OPENRUYI_IMAGE           target local image tag (default localhost/openruyi-oci:riscv64)
#   OPENRUYI_REGISTRY_IMAGE  registry source ref
#   CONTAINER_ENGINE         podman (default) or docker
#   OFFLINE=1                skip the registry pull; use the existing local image
#
# By default this always pulls so an updated upstream image is picked up: the
# registry tag is mutable, and a plain "image exists" check by name would keep a
# stale local copy forever. The pull only transfers layers that actually changed,
# so re-running when nothing moved is cheap.
set -euo pipefail

IMAGE_TAG="${OPENRUYI_IMAGE:-localhost/openruyi-oci:riscv64}"
REGISTRY_IMAGE="${OPENRUYI_REGISTRY_IMAGE:-community-ci.openruyi.cn/openruyi-oci:riscv64}"
ENGINE="${CONTAINER_ENGINE:-podman}"

if [ "$(uname -m)" != riscv64 ]; then
    echo "WARNING: host arch is $(uname -m), not riscv64." >&2
    echo "         The openRuyi image is riscv64-only; this CI must run natively on riscv64." >&2
fi

if [ "${OFFLINE:-0}" = 1 ]; then
    if "${ENGINE}" image exists "${IMAGE_TAG}" 2>/dev/null; then
        echo "OFFLINE=1: using existing local image ${IMAGE_TAG}; skipping pull"
        exit 0
    fi
    echo "OFFLINE=1 but local image ${IMAGE_TAG} is missing; cannot continue" >&2
    exit 1
fi

echo "Pulling ${REGISTRY_IMAGE} (set OFFLINE=1 to reuse the local image without pulling)"
"${ENGINE}" pull "${REGISTRY_IMAGE}"

echo "Tagging ${REGISTRY_IMAGE} -> ${IMAGE_TAG}"
"${ENGINE}" tag "${REGISTRY_IMAGE}" "${IMAGE_TAG}"
echo "OK: ${IMAGE_TAG}"
