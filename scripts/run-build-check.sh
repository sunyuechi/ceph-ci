#!/usr/bin/env bash
#
# L2 driver: clone ceph @ CEPH_REF, apply the openRuyi fork patches, run
# build-with-container.py -d openruyi (build + ctest). Runs by hand on a riscv64
# host and from the self-hosted runner; all config via env.
#
# Env overrides:
#   CEPH_REPO     upstream ceph git URL (default https://github.com/ceph/ceph.git)
#   CEPH_REF      branch/tag/sha to test (default main)
#   WORKDIR       dir holding the ceph checkout (default: this repo's parent dir)
#   STEPS         comma list of bwc steps (default tests)
#   BUILD_INCREMENTAL  1 to reuse an existing build/ (default: clean build)
#   REBUILD_DEPS  1 to drop the cached build image and reinstall BuildRequires,
#                 picking up rolling openRuyi package updates (default: reuse).
#                 Needed because bwc's build-image cache keys on source-file hashes,
#                 not on the actual installed package versions.
#   TEMP_OBS_REPO 1 (default) install deps preferring the temporary OBS project
#                 home:sunyuechi:openruyi-test (patch 2005, repo priority=1);
#                 0 to use only the stock openRuyi repos. Toggling rebuilds the
#                 deps image automatically (tracked in the image fingerprint).
#   CONTAINER_ENGINE   podman (default) or docker
#   GIT_PROXY     proxy for external network; unset = auto-detect via CI_PROXY_PROBE
#                 (abort if it never reaches github); 'direct' forces no proxy
#   CI_PROXY_PROBE  proxy probed for auto-detect (default http://10.200.1.1:8888;
#                   probe target is CEPH_REPO's git smart-http endpoint -- see below)
#   CI_PROXY_PROBE_URL  override the probe URL (default ${CEPH_REPO}/info/refs?...)
#   CI_PROXY_PROBE_RETRIES  probe attempts before aborting as a network error (default 5)
#   CI_PROXY_PROBE_DELAY    seconds between probe attempts (default 5)
#   CI_NO_PROXY   hosts that bypass GIT_PROXY (default: openRuyi repos + loopback)
#   FLAKE_RETRIES ctest --repeat until-pass count for known flakes (default 2)
#   CONFIGURE_ARGS override the cmake feature set (default: CONFIGURE_FLAGS below)
#   CEPH_PYTHON_SYSTEM_SITE  1 (default) run test venvs with system site-packages
#                            (patch 1008); empty to disable
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CEPH_REPO="${CEPH_REPO:-https://github.com/ceph/ceph.git}"
CEPH_REF="${CEPH_REF:-main}"
WORKDIR="${WORKDIR:-$(dirname "${REPO_ROOT}")}"
STEPS="${STEPS:-tests}"
ENGINE="${CONTAINER_ENGINE:-podman}"
CEPH_SRC="${WORKDIR}/ceph"
CEPH_PYTHON_SYSTEM_SITE="${CEPH_PYTHON_SYSTEM_SITE:-1}"
# Normalize to exactly 0/1: it is compared verbatim in the patch list and the
# image fingerprint, so "true"/"yes" must not read as a third state.
case "${TEMP_OBS_REPO:-1}" in
    0|false|no|off) TEMP_OBS_REPO=0 ;;
    *)              TEMP_OBS_REPO=1 ;;
esac

# Per-run timestamped log under ${WORKDIR}/ci-log/; ${WORKDIR}/run.log symlinks to
# the newest, so `tail -f run.log` follows the current run.
mkdir -p "${WORKDIR}/ci-log"
_RUN_LOG="${WORKDIR}/ci-log/$(date +%Y%m%d-%H%M%S)-run.log"
ln -sfn "${_RUN_LOG}" "${WORKDIR}/run.log"
# Prefix each line with elapsed wall time [HH:MM:SS]; t0 before any step covers the whole run.
_RUN_T0=$(date +%s)
exec > >(gawk -v t0="${_RUN_T0}" \
    '{ t = systime() - t0; printf "[%02d:%02d:%02d] %s\n", t/3600, (t%3600)/60, t%60, $0; fflush() }' \
    | stdbuf -oL tee -a "${_RUN_LOG}") 2>&1

# Cancel-safety: build-with-container.py runs the build inside a podman container
# named "ceph_build" (bwc's fixed --name). On Ctrl-C / TERM the bwc python and the
# podman client in our process group die, but the container keeps running under
# conmon (reparented to init), so the build limps on after a "cancel". Kill the
# container explicitly so an interrupt actually stops the build.
BUILD_CONTAINER="ceph_build"
_cleanup_on_signal() {
    trap - INT TERM                      # disarm so a second signal can't re-enter
    echo "=== interrupted: killing build container ${BUILD_CONTAINER} ==="
    "${ENGINE}" kill "${BUILD_CONTAINER}" >/dev/null 2>&1 || true
    "${ENGINE}" rm -f "${BUILD_CONTAINER}" >/dev/null 2>&1 || true
    exit 130
}
trap _cleanup_on_signal INT TERM

# GIT_PROXY resolution: explicit value wins (direct -> none); if unset, probe the
# proxy (with retries) and use it. Probe target is CEPH_REPO's own git smart-http
# endpoint -- the URL the build actually needs; the proxy policy-blocks some other
# github endpoints (web root, api), so probing those would false-negative. If every
# probe fails the network is broken -- abort instead of falling back to direct:
# git fetch from github does not work direct from this host, and podman would leak
# the runner's loopback http_proxy into the build container. To force a proxy-less
# run anyway, set GIT_PROXY=direct.
CI_PROXY_PROBE="${CI_PROXY_PROBE:-http://10.200.1.1:8888}"
CI_PROXY_PROBE_URL="${CI_PROXY_PROBE_URL:-${CEPH_REPO}/info/refs?service=git-upload-pack}"
CI_PROXY_PROBE_RETRIES="${CI_PROXY_PROBE_RETRIES:-5}"
CI_PROXY_PROBE_DELAY="${CI_PROXY_PROBE_DELAY:-5}"
if [ -z "${GIT_PROXY+x}" ]; then
    GIT_PROXY=""
    _try=1
    while [ "${_try}" -le "${CI_PROXY_PROBE_RETRIES}" ]; do
        if curl -fsS -x "${CI_PROXY_PROBE}" -m 10 -o /dev/null "${CI_PROXY_PROBE_URL}" 2>/dev/null; then
            GIT_PROXY="${CI_PROXY_PROBE}"
            echo "  GIT_PROXY: auto-detected proxy at ${CI_PROXY_PROBE} (attempt ${_try})"
            break
        fi
        echo "  GIT_PROXY: probe ${CI_PROXY_PROBE} failed (attempt ${_try}/${CI_PROXY_PROBE_RETRIES})" >&2
        [ "${_try}" -lt "${CI_PROXY_PROBE_RETRIES}" ] && sleep "${CI_PROXY_PROBE_DELAY}"
        _try=$((_try + 1))
    done
    if [ -z "${GIT_PROXY}" ]; then
        echo "ERROR: proxy probe ${CI_PROXY_PROBE} could not reach github after ${CI_PROXY_PROBE_RETRIES} attempts." >&2
        echo "       This is a network problem, not a build failure; aborting now." >&2
        echo "       (Forcing the build on would only fail later, and could leak a loopback proxy into the container.)" >&2
        echo "       To force a proxy-less direct run, re-run with GIT_PROXY=direct." >&2
        exit 1
    fi
elif [ "${GIT_PROXY}" = direct ]; then
    GIT_PROXY=""
fi
# Hosts reached directly, NOT via GIT_PROXY (openRuyi repos, go module CDN, loopback).
CI_NO_PROXY="${CI_NO_PROXY:-boat.openruyi.cn,repo.build.openruyi.cn,.openruyi.cn,goproxy.cn,127.0.0.1,localhost}"

# Must run natively on riscv64 (no QEMU).
if [ "$(uname -m)" != riscv64 ]; then
    echo "ERROR: host arch is $(uname -m); this CI must run on riscv64 hardware." >&2
    exit 1
fi

echo "=== ceph-ci L2 run ==="
echo "  repo=${CEPH_REPO} ref=${CEPH_REF}"
echo "  workdir=${WORKDIR} engine=${ENGINE} steps=${STEPS}"
echo "  CEPH_PYTHON_SYSTEM_SITE='${CEPH_PYTHON_SYSTEM_SITE}' (empty=off)"
echo "  TEMP_OBS_REPO=${TEMP_OBS_REPO} (1=prefer home:sunyuechi:openruyi-test, 0=stock repos only)"
echo "  GIT_PROXY='${GIT_PROXY}' (empty=direct)"

# 1. ensure the openRuyi base image is present
"${REPO_ROOT}/scripts/fetch-openruyi-image.sh"

# 2. clone or update the ceph source at CEPH_REF
mkdir -p "${WORKDIR}"
# Pin git's proxy at command level (empty = none) so a stray host-global http.proxy can't interfere.
declare -a GIT_PROXY_ARGS
if [ -n "${GIT_PROXY}" ]; then
    GIT_PROXY_ARGS=(-c "http.proxy=${GIT_PROXY}" -c "https.proxy=${GIT_PROXY}")
else
    GIT_PROXY_ARGS=(-c "http.proxy=" -c "https.proxy=")
fi
if [ ! -d "${CEPH_SRC}/.git" ]; then
    git "${GIT_PROXY_ARGS[@]}" clone "${CEPH_REPO}" "${CEPH_SRC}"
fi
# Interrupted git invocations (power loss, Ctrl-C, killed ssh) leave *.lock files
# that fail every later git write. Nothing else legitimately runs git on this
# checkout, so clear stale locks unless a git process is still alive.
if ! pgrep -x git >/dev/null; then
    find "${CEPH_SRC}/.git" -name "*.lock" -delete
fi
# CEPH_REF may be a branch/tag (fetchable) or a bare sha. GitHub rejects fetch-by-sha
# ("couldn't find remote ref"); if the fetch fails but the commit already exists
# locally (e.g. an incremental re-run pinned to the sha already checked out), use it.
if git -C "${CEPH_SRC}" "${GIT_PROXY_ARGS[@]}" fetch --force "${CEPH_REPO}" "${CEPH_REF}"; then
    git -C "${CEPH_SRC}" checkout --force FETCH_HEAD
elif git -C "${CEPH_SRC}" rev-parse --verify --quiet "${CEPH_REF}^{commit}" >/dev/null; then
    echo "fetch of ${CEPH_REF} failed; commit exists locally, using local object"
    git -C "${CEPH_SRC}" checkout --force "${CEPH_REF}"
else
    echo "ERROR: cannot fetch ${CEPH_REF} and it is not present locally" >&2
    exit 1
fi
# --force: re-checkout incomplete submodule worktrees (else configure fails). The
# command-level -c http.proxy reaches child clones via GIT_CONFIG_PARAMETERS.
git -C "${CEPH_SRC}" "${GIT_PROXY_ARGS[@]}" submodule update --init --force --recursive ${GIT_PROXY:+--jobs 4}
CEPH_SHA="$(git -C "${CEPH_SRC}" rev-parse --short HEAD)"
echo "checked out ceph ${CEPH_REF} @ ${CEPH_SHA}"

# 3. Fork patches: list lives in tree-patches.sh next to this script.
source "${REPO_ROOT}/scripts/tree-patches.sh"

# Submodule patches: path under fork-patches/submodules/ mirrors the submodule path;
# applied inside that submodule. Same skip convention as TREE_PATCHES.
SUBMODULE_PATCHES=(
    # https://github.com/intel/isa-l/pull/412  (1xxx: upstream-bound)
    src/isa-l/1006-isa-l-riscv64-rvv-raid-aliasing.patch
    # seastar (WITH_CRIMSON) riscv64 support; bundled seastar has no riscv64 defs
    # ours -- rebased from scylladb/seastar@59225b1 (cache line, huge page, cpu_relax, cfi)
    src/seastar/1013-seastar-riscv-initial-port.patch
    # https://github.com/scylladb/seastar/pull/3435 (io_uring socket send EAGAIN)
    src/seastar/1014-seastar-reactor-io-uring-retry-eagain.patch
    # ours -- let GCC's -Wno-error=cpp apply so an advisory #warning isn't fatal under -Werror
    src/seastar/1015-seastar-cmake-detect-wno-error-cpp.patch
)

for name in "${TREE_PATCHES[@]}"; do
    p="${REPO_ROOT}/fork-patches/${name}"
    [ -e "$p" ] || { echo "ERROR: listed patch not found: ${name}" >&2; exit 1; }
    if git -C "${CEPH_SRC}" apply --reverse --check "$p" 2>/dev/null; then
        echo "patch already applied upstream, skipping: ${name}"
        continue
    fi
    echo "applying ${name}"
    git -C "${CEPH_SRC}" apply --3way "$p"
done

# 3b. submodule patches (fresh clone builds from patched source; no relink needed).
for rel in "${SUBMODULE_PATCHES[@]}"; do
    sub="$(dirname "${rel}")"                      # e.g. src/isa-l
    p="${REPO_ROOT}/fork-patches/submodules/${rel}"
    subdir="${CEPH_SRC}/${sub}"
    [ -e "$p" ] || { echo "ERROR: listed submodule patch not found: ${rel}" >&2; exit 1; }
    [ -d "${subdir}/.git" ] || [ -f "${subdir}/.git" ] || {
        echo "ERROR: submodule ${sub} not checked out; cannot apply ${rel}" >&2
        exit 1
    }
    if git -C "${subdir}" apply --reverse --check "$p" 2>/dev/null; then
        echo "submodule patch already applied, skipping: ${rel}"
        continue
    fi
    echo "applying ${rel} (in ${sub})"
    git -C "${subdir}" apply --3way "$p"
done

# 3c. ctest options from known-failures.json, forwarded via CHECK_MAKEOPTS (replaces
#     ceph's default -j, so we re-supply it):
#       --timeout 6000 : riscv64-only (slow hardware), matching openRuyi's %ctest macro
#       -E '^(...)$'   : known-failures.json type=="exclude"
#       --repeat       : retry type=="flake" entries (FLAKE_RETRIES, default 2)
KNOWN_FAILURES="${REPO_ROOT}/known-failures.json"
CHECK_MAKEOPTS="-j$(nproc) --timeout 6000"
if [ -f "${KNOWN_FAILURES}" ]; then
    EXCLUDE_RE="$(python3 - "${KNOWN_FAILURES}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
names = [e["test"] for e in data.get("failures", []) if e.get("type") == "exclude"]
print("^(" + "|".join(names) + ")$" if names else "")
PY
)"
    HAVE_FLAKES="$(python3 - "${KNOWN_FAILURES}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print("1" if any(e.get("type") == "flake" for e in data.get("failures", [])) else "")
PY
)"
    [ -n "${EXCLUDE_RE}" ] && CHECK_MAKEOPTS+=" -E ${EXCLUDE_RE}"
    [ -n "${HAVE_FLAKES}" ] && CHECK_MAKEOPTS+=" --repeat until-pass:${FLAKE_RETRIES:-2}"
fi
echo "  CHECK_MAKEOPTS='${CHECK_MAKEOPTS}'"

# 3d. cmake feature set (override the whole set via CONFIGURE_ARGS). Features are
#     otherwise left at their defaults so the build tracks cmake/run-make.sh; the
#     flags below only suppress defaults unusable here. crimson follows the
#     defaults too: bwc installs its deps into the build image (Dockerfile.build
#     ARG WITH_CRIMSON=true) but the build itself stays at cmake's default OFF.
CONFIGURE_FLAGS=(
    # run-make.sh hardcodes -DWITH_SPDK=ON (cmake and the rpm build default OFF)
    -DWITH_SPDK=OFF
    # cmake defaults ON; needs npm, and even ceph.spec.in turns it OFF unconditionally
    -DWITH_MGR_DASHBOARD_FRONTEND=OFF
    # do_cmake.sh defaults to Debug in a git checkout; Debug enables -Werror via
    # run-make.sh and invalidates the ctest timeout / known-failures calibration
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
    # upstream make-check CI (ceph-pull-requests{,-arm64}) enables both via env
    # (WITH_CRIMSON=true, WITH_RBD_RWL=true -> run-make.sh -DWITH_*=ON);
    # seastar/pmdk unproven on riscv64 -- uncomment after a trial run
    -DWITH_CRIMSON=ON
    -DWITH_RBD_RWL=ON
)
CONFIGURE_ARGS="${CONFIGURE_ARGS:-${CONFIGURE_FLAGS[*]}}"
echo "  CONFIGURE_ARGS='${CONFIGURE_ARGS}'"

# 3e. Drop the cached build image (forcing bwc to rebuild it, i.e. re-run
#     install-deps.sh) when EITHER:
#       - REBUILD_DEPS is set: force a refresh so rolling openRuyi package updates land.
#         bwc keys its build-image cache on the hash of a fixed set of source files
#         (Dockerfile.build, ceph.spec.in, install-deps.sh, ...), NOT on the actual
#         installed package versions, so same-name newer packages are otherwise never
#         reinstalled.
#       - ceph.spec.in changed since the last build image (tracked in .ceph-ci-image-fp).
#         bwc already hashes ceph.spec.in too; this is a belt-and-suspenders check.
IMG_FP_FILE="${WORKDIR}/.ceph-ci-image-fp"
IMG_FP="spec:$(sha256sum "${CEPH_SRC}/ceph.spec.in" | cut -d' ' -f1) tempobs:${TEMP_OBS_REPO}"
_drop_reason=""
case "${REBUILD_DEPS:-}" in
    1|true|yes|on) _drop_reason="REBUILD_DEPS set: forcing dependency refresh" ;;
esac
if [ -z "${_drop_reason}" ] && [ "$(cat "${IMG_FP_FILE}" 2>/dev/null || true)" != "${IMG_FP}" ]; then
    _drop_reason="ceph.spec.in changed since last build image (or first run)"
fi
if [ -n "${_drop_reason}" ]; then
    echo "  dropping build image: ${_drop_reason}"
    _stale_imgs="$(${ENGINE} images -q localhost/ceph-build 2>/dev/null | sort -u)"
    [ -n "${_stale_imgs}" ] && ${ENGINE} rmi -f ${_stale_imgs} >/dev/null 2>&1 || true
fi
printf '%s\n' "${IMG_FP}" > "${IMG_FP_FILE}"

# 3f. Default clean build (rm build/); BUILD_INCREMENTAL=1 reuses build/ for a faster
#     incremental rebuild.
if [ -n "${BUILD_INCREMENTAL:-}" ]; then
    echo "  BUILD_INCREMENTAL=1: reusing existing build/ if present"
else
    echo "  clean build: removing ${CEPH_SRC}/build"
    rm -rf "${CEPH_SRC}/build"
fi

# 4a. Container networking for proxied hosts (only when GIT_PROXY set). The proxy is a
#     routable IP, so both the bwc image-build and run containers reach it over the
#     default bridge net -- no host net needed. Export *_proxy for the image build
#     and the proxied pre-build pass (4c); the STEPS run does NOT inherit them
#     (--http-proxy=false in NET_ARGS, to keep *_proxy away from ctest). Must come
#     AFTER the host git clone/fetch.
if [ -n "${GIT_PROXY}" ]; then
    export http_proxy="${GIT_PROXY}" https_proxy="${GIT_PROXY}" no_proxy="${CI_NO_PROXY}"
fi

# 4b. run build + ctest via bwc. Env goes in via `--extra=` (the '=' form is required;
#     bwc's argparse rejects `-x -eFOO`).
declare -a EXEC=()
IFS=',' read -ra _steps <<< "${STEPS}"
for s in "${_steps[@]}"; do EXEC+=(-e "$s"); done

# Per-host git/go config shared by every container run (only meaningful when proxied).
declare -a GIT_CFG_ARGS=()
if [ -n "${GIT_PROXY}" ]; then
    GIT_CFG_ARGS=(
        --extra="-eGIT_CONFIG_COUNT=2"    # in-container git: github via proxy + trust bind-mount
        --extra="-eGIT_CONFIG_KEY_0=http.https://github.com/.proxy"
        --extra="-eGIT_CONFIG_VALUE_0=${GIT_PROXY}"
        --extra="-eGIT_CONFIG_KEY_1=safe.directory"
        --extra="-eGIT_CONFIG_VALUE_1=*"
        --extra="-eGOPROXY=https://goproxy.cn,direct"   # openRuyi go defaults to GOPROXY=""
    )
fi
# The STEPS run always blocks podman's *_proxy forwarding: with GIT_PROXY=direct
# the runner's own loopback proxy would leak in unreachable, and ctest should run
# with the same proxy-free env it is calibrated against (known-failures.json).
# In-container git reaches github via the per-host GIT_CONFIG above.
declare -a NET_ARGS=(
    --extra="--http-proxy=false"
    "${GIT_CFG_ARGS[@]}"
)

declare -a SYSTEM_SITE_ARG=()
[ -n "${CEPH_PYTHON_SYSTEM_SITE}" ] && \
    SYSTEM_SITE_ARG=(--extra="-eCEPH_PYTHON_SYSTEM_SITE=${CEPH_PYTHON_SYSTEM_SITE}")

cd "${CEPH_SRC}"

# 4c. Proxied pre-build: compile the tests target once with the proxy forwarded
#     into the container (podman --http-proxy default), so cmake's superbuild
#     URL-downloads (boost) go through the proxy instead of a slow direct
#     connection. The STEPS run below re-runs buildtests as an incremental no-op
#     and ctest stays proxy-free. Best-effort: a failure here just falls through;
#     the STEPS run is authoritative.
if [ -n "${GIT_PROXY}" ]; then
    echo "=== proxied pre-build (bwc -e buildtests) ==="
    python3 src/script/build-with-container.py \
        --distro openruyi \
        --container-engine "${ENGINE}" \
        "${GIT_CFG_ARGS[@]}" \
        --extra="-eCONFIGURE_ARGS=${CONFIGURE_ARGS}" \
        "${SYSTEM_SITE_ARG[@]}" \
        -e buildtests \
        || echo "=== proxied pre-build failed (rc=$?); continuing with the proxy-free run ==="
fi

# A failed configure leaves build/ without a generator file, and run-make.sh's
# configure refuses to reuse an existing build/. Clear the half-configured dir
# so the STEPS run gets a fresh configure instead of an instant bail-out.
if [ -d "${CEPH_SRC}/build" ] && [ ! -e "${CEPH_SRC}/build/build.ninja" ] && [ ! -e "${CEPH_SRC}/build/Makefile" ]; then
    echo "=== removing half-configured build/ (no generator file) ==="
    rm -rf "${CEPH_SRC}/build"
fi

# 4d. The authoritative proxy-free STEPS run (build no-op + ctest after 4c).
set +e
python3 src/script/build-with-container.py \
    --distro openruyi \
    --container-engine "${ENGINE}" \
    "${NET_ARGS[@]}" \
    --extra="-eCHECK_MAKEOPTS=${CHECK_MAKEOPTS}" \
    --extra="-eCONFIGURE_ARGS=${CONFIGURE_ARGS}" \
    "${SYSTEM_SITE_ARG[@]}" \
    "${EXEC[@]}"
RC=$?
set -e

# 5. surface where ctest results landed (collected as artifacts by the workflow)
echo "=== ctest output dir (build/Testing) ==="
ls -d "${CEPH_SRC}"/build/Testing/* 2>/dev/null || echo "  (no build/Testing yet)"

echo "=== ceph-ci L2 run done: rc=${RC} ceph=${CEPH_SHA} ==="
exit ${RC}
