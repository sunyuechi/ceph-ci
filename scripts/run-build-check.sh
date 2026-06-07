#!/usr/bin/env bash
#
# build-check driver: clone ceph @ CEPH_REF, apply the openRuyi fork patches, run
# build-with-container.py -d openruyi (build + ctest). Runs by hand on a riscv64
# host and from the self-hosted runner; all config via env.
#
# Env overrides:
#   CEPH_REPO     upstream ceph git URL (default https://github.com/ceph/ceph.git)
#   CEPH_REF      branch/tag/sha to test (default main)
#   WORKDIR       parent of the per-CI buckets (default: this repo's parent dir);
#                 this CI lives entirely under ${WORKDIR}/build-check/
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
#   CI_PROXY_PROBE_RETRIES  probe attempts before aborting as a network error (default set below)
#   CI_PROXY_PROBE_DELAY    seconds between probe attempts (default set below)
#   CI_NO_PROXY   hosts that bypass GIT_PROXY (default: openRuyi repos + loopback)
#   FLAKE_RETRIES ctest --repeat until-pass count for known flakes (default set below)
#   CTEST_FAIL_OUTPUT_BYTES  bytes of tail output ctest dumps per failed test
#                            (default 100000); raise to see more of a failure
#   CONFIGURE_ARGS override the cmake feature set (default: CONFIGURE_FLAGS below)
#   CEPH_PYTHON_SYSTEM_SITE  true (default) run test venvs with system site-packages
#                            (patch 1008); empty to disable
#   NPROC         build parallelism, overrides run-make.sh's nproc/2 default
#                 (sets build -j and BOOST_J; default set below). ctest -j is CTEST_JOBS.
#   CTEST_JOBS    ctest parallelism (the -j inside CHECK_MAKEOPTS). Set a fixed
#                 number to cap it (e.g. CTEST_JOBS=8), or =$(nproc) for max;
#                 default set below.
#   MAX_PARALLEL_JOBS  fan-out *inside* the dencoder ctest tests, NOT a ctest -j.
#                 check-generated.sh/readable.sh fork ceph-dencoder per encoding
#                 type, defaulting to $(nproc) jobs; each ASAN ceph-dencoder dlopens
#                 the full osd/mon/mds/rgw type set at ~1.3G RSS, so $(nproc) in
#                 parallel OOMs the host regardless of CTEST_JOBS. Only these two
#                 tests read this var; the default below caps them (RSS x jobs).
#   SCCACHE_HOST_DIR    host dir bound as the in-container sccache cache so it
#                       persists across runs (default ${WORKDIR}/build-check/sccache-cache)
#   SCCACHE_CACHE_SIZE  sccache max cache size (default set below; sccache's own default is 5G)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CEPH_REPO="${CEPH_REPO:-https://github.com/ceph/ceph.git}"
CEPH_REF="${CEPH_REF:-main}"
WORKDIR="${WORKDIR:-$(dirname "${REPO_ROOT}")}"
# Each of the three CIs owns a subdir under ${WORKDIR} -- build-check / spec-openruyi /
# spec-upstream -- instead of sharing one flat dir distinguished only by name prefixes.
# So the checkout, logs and caches of the three never interleave: `cd build-check/` and
# everything there is this CI's. This is the build-check bucket.
BASE="${WORKDIR}/build-check"
mkdir -p "${BASE}"
STEPS="${STEPS:-tests}"
ENGINE="${CONTAINER_ENGINE:-podman}"
CEPH_SRC="${BASE}/ceph"
CEPH_PYTHON_SYSTEM_SITE="${CEPH_PYTHON_SYSTEM_SITE:-true}"

NPROC="${NPROC:-50}"
CTEST_JOBS="${CTEST_JOBS:-$(nproc)}"
MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-}"
# NPROC="${NPROC:-50}"
# CTEST_JOBS="${CTEST_JOBS:-50}"
# MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-8}"

# 3d. cmake feature set (override the whole set via CONFIGURE_ARGS). Features are
#     otherwise left at their defaults so the build tracks cmake/run-make.sh; the
#     flags below only suppress defaults unusable here.
CONFIGURE_FLAGS=(
    # run-make.sh hardcodes -DWITH_SPDK=ON (cmake and the rpm build default OFF)
    -DWITH_SPDK=OFF
    # cmake defaults ON; needs npm, and even ceph.spec.in turns it OFF unconditionally
    -DWITH_MGR_DASHBOARD_FRONTEND=OFF
    # No -DCMAKE_BUILD_TYPE: track upstream, which defaults a git checkout to Debug.
    # upstream make-check CI (ceph-pull-requests{,-arm64}) enables both via env
    # (WITH_CRIMSON=true, WITH_RBD_RWL=true -> run-make.sh -DWITH_*=ON)
    -DWITH_CRIMSON=ON
    -DWITH_RBD_RWL=ON
    # Link with mold. ceph's WITH_MOLD (fork patch 1018) finds the mold binary,
    # sets CMAKE_LINKER, injects -fuse-ld=mold into the EXE/SHARED/MODULE linker
    # flags, and gates the mold-only workarounds (disable --exclude-libs so
    # .symver'd rados_* stay visible; objcopy --weaken crimson-alien-common so its
    # duplicate symbols lose to crimson-common) behind USING_MOLD_LINKER. Replaces
    # the old hand-injected -eLDFLAGS=-fuse-ld=mold, which seeded the linker flags
    # but never tripped those workarounds.
    # -DWITH_MOLD=ON
    # add_ceph_test stamps every test with a per-test TIMEOUT property (= this cache
    # var, default 7200s), which OVERRIDES ctest's command-line --timeout below. So
    # the --timeout in CHECK_MAKEOPTS is a no-op for these tests; the kill time is set
    # here at configure time. Slow riscv64 hardware needs the longer ceiling.
    -DCEPH_TEST_TIMEOUT=18000
    # ceph's LimitJobs.cmake sizes the link job pool as total_mem / MAX_LINK_MEM
    # (default 4500 MiB/link -> 28 links here). mold links the crimson/RelWithDebInfo
    # mega-targets at ~2x that, so 28 parallel links OOM this box. Pin the pool via
    # ceph's own knob (avg=N, heavy=N/2); plain -DCMAKE_JOB_POOLS is ignored because
    # ceph already owns the JOB_POOLS global property.
    # -DNINJA_MAX_LINK_JOBS=8
)

# Normalize to exactly 0/1: it is compared verbatim in the patch list and the
# image fingerprint, so "true"/"yes" must not read as a third state.
case "${TEMP_OBS_REPO:-1}" in
    0|false|no|off) TEMP_OBS_REPO=0 ;;
    *)              TEMP_OBS_REPO=1 ;;
esac

# RESUME=1: continue an interrupted build (e.g. one the OOM killer cut short)
# without touching the source tree. Skips clone/fetch/checkout/submodule/patch and
# the standalone configure step; reuses the current checkout + build/ as-is and
# goes straight to build+ctest. Implies BUILD_INCREMENTAL=1, and CEPH_REF is ignored
# (the existing HEAD is reused) so source mtimes stay put and ninja rebuilds only
# what the interrupted run left unfinished. Requires an already-configured build/
# (build.ninja present); aborts otherwise.
case "${RESUME:-}" in
    1|true|yes|on) RESUME=1; BUILD_INCREMENTAL=1 ;;
    *)             RESUME=0 ;;
esac

# Per-run timestamped log under ${BASE}/ci-log/; ${BASE}/run.log symlinks to the
# newest, so `tail -f build-check/run.log` follows the current run.
mkdir -p "${BASE}/ci-log"
_RUN_LOG="${BASE}/ci-log/$(date +%Y%m%d-%H%M%S)-run.log"
ln -sfn "${_RUN_LOG}" "${BASE}/run.log"
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
    [ -n "${MEM_SAMPLER_PID:-}" ] && kill "${MEM_SAMPLER_PID}" 2>/dev/null || true
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

echo "=== ceph-ci build-check run ==="
echo "  repo=${CEPH_REPO} ref=${CEPH_REF}"
echo "  base=${BASE} engine=${ENGINE} steps=${STEPS}"
echo "  CEPH_PYTHON_SYSTEM_SITE='${CEPH_PYTHON_SYSTEM_SITE}' (empty=off)"
echo "  TEMP_OBS_REPO=${TEMP_OBS_REPO} (1=prefer home:sunyuechi:openruyi-test, 0=stock repos only)"
echo "  GIT_PROXY='${GIT_PROXY}' (empty=direct)"
[ "${RESUME}" = 1 ] && echo "  RESUME=1 (skip clone/fetch/patch/configure; reuse build/; CEPH_REF ignored)"

# 1. ensure the openRuyi base image is present
"${REPO_ROOT}/scripts/fetch-openruyi-image.sh"

# 2. clone or update the ceph source at CEPH_REF
mkdir -p "${BASE}"
if [ "${RESUME}" = 1 ]; then
    [ -d "${CEPH_SRC}/.git" ] || {
        echo "ERROR: RESUME=1 but no checkout at ${CEPH_SRC}; run a normal build first." >&2
        exit 1
    }
    CEPH_SHA="$(git -C "${CEPH_SRC}" rev-parse --short HEAD)"
    echo "=== RESUME: reuse existing checkout, ceph @ ${CEPH_SHA} (skip clone/fetch/checkout/submodule/patch) ==="
else
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
# checkout --force only resets tracked files; it leaves untracked files (e.g. ones
# created during manual testing on the CI host) in place, which then collide with
# --3way patches that create new files ("does not exist in index"). git restore
# wouldn't help -- it ignores untracked files -- so clean them. -d for dirs; no -x
# so build/ and other ignored artifacts survive. Submodules aren't descended into.
git -C "${CEPH_SRC}" clean -fd
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
fi   # end "RESUME != 1" guard around clone/fetch/checkout/submodule/patch

# 3c. ctest options from known-failures.json, forwarded via CHECK_MAKEOPTS (replaces
#     ceph's default -j, so we re-supply it):
#       --timeout 18000: fallback only; tests carry a per-test TIMEOUT property that
#                        overrides this, so the real kill time is -DCEPH_TEST_TIMEOUT
#                        in CONFIGURE_FLAGS (kept aligned at 18000 for slow riscv64)
#       -E '^(...)$'   : known-failures.json type=="exclude"
#       --repeat       : retry type=="flake" entries (FLAKE_RETRIES)
#       --test-output-size-failed : cap dumped output per failed test; ctest keeps
#                        the tail, which holds the gtest/sanitizer verdict
#     Note: ctest -E only works at ctest-name granularity (a whole gtest binary),
#     so a single flaky gtest *case* inside an otherwise-good binary cannot live in
#     known-failures.json. unittest_bluefs's BlueFS_wal.wal_v2_check_feature is one
#     such case: a timing benchmark asserting the wal envelope path is >=20% faster
#     than the basic path, unreliable under -j contention on riscv64 (often measures
#     *slower*). Upstream gates it behind SKIP_JENKINS() (skips when JENKINS_HOME is
#     set), but we must NOT set JENKINS_HOME: run-make-check.sh's run() also branches
#     on in_jenkins and there deliberately swallows ctest's exit code ("the jenkins
#     publisher will take care of this"), which we have no publisher for -- it turned
#     a real ctest failure into a green run. So that bluefs case runs here; if it
#     starts flaking, skip it via a per-test GTEST_FILTER instead of JENKINS_HOME.
KNOWN_FAILURES="${REPO_ROOT}/known-failures.json"
CHECK_MAKEOPTS="-j${CTEST_JOBS} --timeout 18000 --test-output-size-failed ${CTEST_FAIL_OUTPUT_BYTES:-100000}"
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
IMG_FP_FILE="${BASE}/.image-fp"
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

# 3g. Build tuning forwarded to the bwc STEPS run (NPROC/CTEST_JOBS set at top):
#   sccache: bwc runs each step in a --rm container (HOME=/root), so the default
#           ~/.cache/sccache is discarded every run -> cold cache, 100% miss. Bind a
#           host dir to persist it across runs; a clean build/ still hits because
#           sccache is content-addressed. Size past the 5G default, and disable the
#           idle timeout that shut the server down mid-build (falling back to local).
SCCACHE_HOST_DIR="${SCCACHE_HOST_DIR:-${BASE}/sccache-cache}"
SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-100G}"
mkdir -p "${SCCACHE_HOST_DIR}"
echo "  NPROC=${NPROC} (build -j / BOOST_J; ctest -j${CTEST_JOBS}; dencoder MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS})"
echo "  sccache: ${SCCACHE_HOST_DIR} -> /root/.cache/sccache (max ${SCCACHE_CACHE_SIZE})"
declare -a BUILD_TUNE_ARGS=(
    --extra="-eNPROC=${NPROC}"
    # Debug build type makes run-make.sh inject -Werror; disable it to first get green.
    --extra="-eWITHOUT_WERROR=1"
    # mold is selected via -DWITH_MOLD=ON in CONFIGURE_FLAGS (ceph's own option
    # finds mold and wires -fuse-ld + the mold workarounds), so no LDFLAGS here.
    --extra="--volume=${SCCACHE_HOST_DIR}:/root/.cache/sccache:Z"
    --extra="-eSCCACHE_DIR=/root/.cache/sccache"
    --extra="-eSCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}"
    --extra="-eSCCACHE_IDLE_TIMEOUT=0"
)

# 3h. standalone test data on tmpfs. qa/standalone tests (smoke.sh, osd-*, mon-*)
#     run file-backed BlueStore OSDs whose block file sits under build/td; on this
#     host that path is NVMe ext4 via the bind-mount, where O_DIRECT/libaio write
#     completion intermittently stalls for minutes -> PGs stuck activating ->
#     wait_for_clean / rados bench hang (smoke.sh's internal `timeout` trips first).
#     Mapping build/td to tmpfs removes the stall. /dev/shm is RAM/2; a td is well
#     under that, and overflow is tmpfs ENOSPC (a test failure), not host OOM.
#     /ceph/build/td assumes bwc's default --homedir=/ceph. STEPS (ctest) run only.
TD_TMPFS_DIR="${TD_TMPFS_DIR:-/dev/shm/ceph-ci-td}"
rm -rf "${TD_TMPFS_DIR}"; mkdir -p "${TD_TMPFS_DIR}"
echo "  standalone td on tmpfs: ${TD_TMPFS_DIR} -> /ceph/build/td"
declare -a TD_TMPFS_ARGS=(
    --extra="--volume=${TD_TMPFS_DIR}:/ceph/build/td:Z"
)

# 4a. Container networking for proxied hosts (only when GIT_PROXY set). The proxy is a
#     routable IP, so both the bwc image-build and run containers reach it over the
#     default bridge net -- no host net needed. Export *_proxy so the image build and
#     the STEPS run inherit it (podman's default *_proxy forwarding). Must come
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
# The STEPS run inherits GIT_PROXY (a routable proxy) via podman's default *_proxy
# forwarding so ctest's python venv/tox tests can pip-install their lint deps;
# without a proxy pip hits pypi.org direct and ReadTimeouts. no_proxy (CI_NO_PROXY)
# keeps the openRuyi repos + loopback direct; GIT_PROXY=direct exports nothing, so
# the container stays proxy-free. In-container git reaches github via GIT_CONFIG above.
declare -a NET_ARGS=(
    "${GIT_CFG_ARGS[@]}"
)

declare -a SYSTEM_SITE_ARG=()
[ -n "${CEPH_PYTHON_SYSTEM_SITE}" ] && \
    SYSTEM_SITE_ARG=(--extra="-eCEPH_PYTHON_SYSTEM_SITE=${CEPH_PYTHON_SYSTEM_SITE}")

cd "${CEPH_SRC}"

# 4b.5 Background memory sampler. The build is OOM-prone (mold links the crimson
#      mega-targets at several GB RSS, and ld.mold OOM is a global kill, not a
#      cgroup one), and we cannot watch it live. Sample host memory + the top RSS
#      consumers every MEM_SAMPLE_INTERVAL seconds to a sibling log so a killed
#      run can be diagnosed afterwards. Host-side ps sees the in-container procs.
MEM_LOG="${BASE}/ci-log/$(date +%Y%m%d-%H%M%S)-mem.log"
ln -sfn "${MEM_LOG}" "${BASE}/mem-usage.log"
_mem_sampler() {
    local phase last_phase=""
    while :; do
        # Phase = build vs test, inferred from whether ctest is running (host ps/pgrep
        # sees the in-container ctest). Build (ninja/cc1plus/mold) always precedes
        # ctest; once ctest is up we are in the test phase. Emit a banner on each
        # transition so the two halves are easy to tell apart, and tag every sample
        # line with the phase so a grep / the peak summary can attribute it.
        if pgrep -x ctest >/dev/null 2>&1; then phase=TEST; else phase=BUILD; fi
        if [ "${phase}" != "${last_phase}" ]; then
            printf '===== %s phase @ %s =====\n' "${phase}" "$(date '+%H:%M:%S')"
            last_phase="${phase}"
        fi
        # avail = MemAvailable (true headroom); pair with top RSS procs so an OOM
        # can be pinned to ld.mold / cc1plus.
        free -m | awk -v ts="$(date '+%H:%M:%S')" -v ph="${phase}" \
            '/^Mem:/{printf "[%s %s] used=%sM avail=%sM", ts, ph, $3, $7}'
        ps -eo rss=,comm= --sort=-rss | awk 'NR<=6{printf " %s=%dM", $2, $1/1024} END{print ""}'
        sleep "${MEM_SAMPLE_INTERVAL:-5}"
    done
}
_mem_sampler >> "${MEM_LOG}" 2>&1 &
MEM_SAMPLER_PID=$!
echo "  memory sampler pid=${MEM_SAMPLER_PID} -> ${MEM_LOG}"

# A half-configured build/ (no generator file, e.g. an incremental reuse of a
# build/ whose configure died last run) makes run-make.sh's configure bail out
# instead of reusing it. Clear it so the STEPS run gets a fresh configure.
if [ -d "${CEPH_SRC}/build" ] && [ ! -e "${CEPH_SRC}/build/build.ninja" ] && [ ! -e "${CEPH_SRC}/build/Makefile" ]; then
    echo "=== removing half-configured build/ (no generator file) ==="
    rm -rf "${CEPH_SRC}/build"
fi

# 4c. Configure in a td-free container first, then run the authoritative build +
#     ctest with the tmpfs td mounted. The split is required: the STEPS run mounts
#     the td at /ceph/build/td, which makes podman pre-create /ceph/build, and
#     do_cmake.sh refuses to configure into an existing build/. Configuring here
#     (no td -> build/ absent) leaves has_build_dir true, so the STEPS run's own
#     configure step short-circuits straight to build + ctest. The mold selection
#     (-DWITH_MOLD=ON in CONFIGURE_ARGS) must be present at this configure so cmake
#     wires the linker and seeds the EXE/SHARED/MODULE flags.
set +e
if [ "${RESUME}" = 1 ]; then
    # build/ must already be configured: the STEPS run mounts the tmpfs td at
    # /ceph/build/td (pre-creating /ceph/build), and do_cmake.sh refuses to
    # configure into an existing build/. Without an existing build.ninja the run
    # would fail there, so demand it up front rather than after a long container spin-up.
    if [ ! -e "${CEPH_SRC}/build/build.ninja" ]; then
        echo "ERROR: RESUME=1 but ${CEPH_SRC}/build/build.ninja is missing; build/ is not configured." >&2
        echo "       Run a normal (non-RESUME) build once to configure, then RESUME to continue it." >&2
        exit 1
    fi
    echo "=== RESUME: build/ already configured, skipping standalone configure ==="
    RC=0
else
    echo "=== configure (td-free, so do_cmake sees no pre-created build/) ==="
    python3 src/script/build-with-container.py \
        --distro openruyi \
        --container-engine "${ENGINE}" \
        "${NET_ARGS[@]}" \
        "${BUILD_TUNE_ARGS[@]}" \
        --extra="-eCONFIGURE_ARGS=${CONFIGURE_ARGS}" \
        "${SYSTEM_SITE_ARG[@]}" \
        -e configure
    RC=$?
fi
if [ "${RC}" -eq 0 ]; then
    python3 src/script/build-with-container.py \
        --distro openruyi \
        --container-engine "${ENGINE}" \
        "${NET_ARGS[@]}" \
        "${BUILD_TUNE_ARGS[@]}" \
        "${TD_TMPFS_ARGS[@]}" \
        --extra="-eCHECK_MAKEOPTS=${CHECK_MAKEOPTS}" \
        --extra="-eMAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS}" \
        --extra="-eCONFIGURE_ARGS=${CONFIGURE_ARGS}" \
        "${SYSTEM_SITE_ARG[@]}" \
        "${EXEC[@]}"
    RC=$?
fi
set -e

# 4e. Stop the memory sampler and surface the low-water mark + peak linker RSS so
#     an OOM shows up in run.log without trawling the full mem timeline.
kill "${MEM_SAMPLER_PID}" 2>/dev/null || true
wait "${MEM_SAMPLER_PID}" 2>/dev/null || true
echo "=== memory peak during build (full timeline: ${MEM_LOG}) ==="
# Whole-host usage peak split by phase (build vs test, from the line tag), regardless
# of build rc, so an OOM or near-miss is visible at a glance AND attributed to the
# half that hit it.
gawk 'match($0,/\[[0-9:]+ (BUILD|TEST)\] used=([0-9]+)M avail=([0-9]+)M/,m){
        ph=m[1]; u=m[2]+0; a=m[3]+0
        if(u>pu[ph]){pu[ph]=u; LU[ph]=$0}
        if(!(ph in pa)||a<pa[ph]){pa[ph]=a; LA[ph]=$0}
      }
      END{split("BUILD TEST",ord); n=0
          for(i=1;i<=2;i++){ph=ord[i]; if(ph in pu){n++
            print "  ["ph"] peak used="pu[ph]"M @ "LU[ph]
            print "  ["ph"] min MemAvailable="pa[ph]"M @ "LA[ph]}}
          if(n==0) print "  (no samples captured)"}' "${MEM_LOG}" || true
gawk 'match($0,/(ld\.mold|mold|cc1plus)=([0-9]+)M/,a){if(a[2]+0>m){m=a[2]+0;p=a[1]}}
      END{if(m)print "  peak "p" RSS="m"M"}' "${MEM_LOG}" || true

# 5. surface where ctest results landed (collected as artifacts by the workflow)
echo "=== ctest output dir (build/Testing) ==="
ls -d "${CEPH_SRC}"/build/Testing/* 2>/dev/null || echo "  (no build/Testing yet)"

echo "=== ceph-ci build-check run done: rc=${RC} ceph=${CEPH_SHA} ==="
exit ${RC}
