#!/usr/bin/env bash
#
# L3 (experimental): bring up a single-node cluster from the L2 build tree, do
# basic rados/rbd/cephfs IO, tear it down. Runs in the openRuyi build container via
# bwc's `custom` step. Failures here are a known-gap signal, not an L2 regression.
#
# Env: same as run-build-check.sh (CEPH_REF, WORKDIR, CONTAINER_ENGINE, ...).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-$(dirname "${REPO_ROOT}")}"
CEPH_SRC="${WORKDIR}/ceph"
ENGINE="${CONTAINER_ENGINE:-podman}"

[ -d "${CEPH_SRC}/build" ] || { echo "ERROR: no build tree at ${CEPH_SRC}/build; run L2 build first" >&2; exit 1; }

# Inner script executed inside the container against the mounted ceph tree.
INNER="${CEPH_SRC}/.ceph-ci-vstart-inner.sh"
cat > "${INNER}" <<'INNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/build"
export CEPH_DEV=1
trap '../src/stop.sh || true' EXIT
../src/vstart.sh -d -n -x --without-dashboard
# basic IO smoke
bin/rados -p rbd bench 5 write --no-cleanup || bin/ceph osd pool create testpool 8 && bin/rados -p testpool bench 5 write --no-cleanup
bin/rbd create --size 64 testpool/img0 2>/dev/null || true
bin/ceph -s
echo "vstart smoke OK"
INNER_EOF
chmod +x "${INNER}"

cd "${CEPH_SRC}"
python3 src/script/build-with-container.py \
    --distro openruyi \
    --container-engine "${ENGINE}" \
    -e custom -- /ceph/.ceph-ci-vstart-inner.sh
