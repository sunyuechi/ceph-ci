#!/usr/bin/env bash
#
# Validate the UPSTREAM ceph.spec.in (not the openruyi/ downstream spec) the way a
# distro/OBS build would: run upstream `make-dist` to turn ceph.spec.in into a real
# ceph.spec + ceph-<ver>.tar.bz2, `rpmbuild` it inside the openRuyi container, then run
# our ctest on the spec's own build tree. The container half lives in
# spec-in-build-in-container.sh; this driver sets up the host side (upstream checkout,
# image, proxy, persistent caches, ctest options).
#
# By default the checkout is pristine upstream. To validate a patch you intend to submit
# upstream, drop it in scripts/upstream-spec/*.patch: every such patch is applied (and
# committed, so make-dist's `git archive HEAD` tarball includes source changes) before
# make-dist runs. No patches present -> a clean upstream build.
#
# This is the upstream-spec.in counterpart to scripts/openruyi/run-spec-build.sh (which
# validates the DOWNSTREAM openruyi/ceph.spec). ceph.spec.in -> ceph.spec is done by
# upstream's own make-dist, the only faithful "as upstream ships it" way to get a
# buildable spec (spec.in has only a make-dist Source0 tarball, no URL sources).
#
# Env overrides:
#   CEPH_REPO     upstream ceph git URL (default https://github.com/ceph/ceph.git)
#   CEPH_REF      branch/tag/sha to validate (default main)
#   WORKDIR       parent of the per-CI buckets (default: this repo's parent dir);
#                 this CI lives entirely under ${WORKDIR}/spec-upstream/
#   NPROC         build parallelism (default set below)
#   CTEST_JOBS    ctest -j (default $(nproc))
#   CONTAINER_ENGINE  podman (default) or docker
#   MAKE_DIST_FULL 0 (default) skip make-dist's dashboard-frontend npm build (heavy,
#                 flaky on riscv64, and unused -- the spec's %build sets the dashboard
#                 frontend OFF); 1 = run vanilla upstream make-dist (frontend included)
#   TEMP_OBS_REPO 1 (default) add home:sunyuechi:openruyi-test as a priority=1 dnf repo
#                 so packages it publishes win; 0 = stock openRuyi repos only
#   REBUILD_DEPS  1 to refresh the cached deps image (localhost/specin-deps) -- runs dnf
#                 FROM the existing image to pick up rolling openRuyi updates, commits a
#                 new layer only if the package set changed. Default 0 reuses as-is while
#                 the fingerprint (spec BuildRequires + TEMP_OBS_REPO + base id) holds.
#   GIT_PROXY     proxy for external network (clone + make-dist's boost/liburing/pmdk
#                 downloads); unset = auto-probe via CI_PROXY_PROBE; 'direct' forces none
#   CI_PROXY_PROBE      proxy probed for auto-detect (default http://10.200.1.1:8888)
#   CI_PROXY_PROBE_URL  URL the probe fetches through the proxy (default: CEPH_REPO's
#                       git smart-http endpoint, NOT the policy-blocked web root)
#   CI_PROXY_PROBE_RETRIES  probe attempts before aborting as a network error (default 5)
#   CI_PROXY_PROBE_DELAY    seconds between probe attempts (default 5)
#   CI_NO_PROXY         hosts that bypass the proxy (openRuyi repos + loopback)
#   FLAKE_RETRIES ctest --repeat until-pass count for known flakes (default 2)
#   OFFLINE       1 to reuse the cached local base image instead of pulling
#   SPECIN_SCCACHE_HOST_DIR  sccache cache dir (default ${WORKDIR}/spec-upstream/sccache-cache);
#                 SPECIN_-prefixed so it never collides with the other paths' caches
#   SPECIN_TD_TMPFS_DIR  standalone-test tmpfs td dir (default /dev/shm/ceph-ci-specin-td)
#
# Incremental re-run knobs (the BUILD/ tree is bind-mounted to ${WORKDIR}/spec-upstream/build,
# so it survives the --rm container and a failed run):
#   SKIP_CTEST=1  stop after a full `rpmbuild -bb` (real rpms in RPMS/, %install/%files
#                 validated); skip the build-check ctest. The clean fast path for pure spec checks.
#   RESUME=1      reuse the persisted spec/tarball + BUILD/ tree: skip make-dist and
#                 re-clone, rpmbuild skips %prep. For spec-only / small source edits;
#                 do a full run (RESUME unset) after changing CEPH_REF.
#   FILES_ONLY=1  re-run only the %files check (rpmbuild -bl) against the BUILDROOT a
#                 prior full run left behind -- seconds, no compile/install. Implies
#                 skipping make-dist and ctest.
#   SPECIN_BUILD_DIR  persisted BUILD/ tree dir (default ${WORKDIR}/spec-upstream/build)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKDIR="${WORKDIR:-$(dirname "${REPO_ROOT}")}"
# This CI owns ${WORKDIR}/spec-upstream/ -- its own subdir, so logs/caches/checkout/build
# tree never interleave with the build-check or spec-openruyi CIs. (See run-build-check.sh.)
BASE="${WORKDIR}/spec-upstream"
mkdir -p "${BASE}"
ENGINE="${CONTAINER_ENGINE:-podman}"
CEPH_REPO="${CEPH_REPO:-https://github.com/ceph/ceph.git}"
CEPH_REF="${CEPH_REF:-main}"
# Dedicated CLEAN checkout, kept apart from the build-check path's ${WORKDIR}/build-check/ceph
# (which has the fork patches applied) -- this path must build vanilla upstream.
CEPH_SRC="${BASE}/ceph"
NPROC="${NPROC:-50}"
CTEST_JOBS="${CTEST_JOBS:-$(nproc)}"

case "${TEMP_OBS_REPO:-1}" in
    0|false|no|off) TEMP_OBS_REPO=0 ;;
    *)              TEMP_OBS_REPO=1 ;;
esac
case "${REBUILD_DEPS:-0}" in
    1|true|yes|on) REBUILD_DEPS=1 ;;
    *)             REBUILD_DEPS=0 ;;
esac
case "${MAKE_DIST_FULL:-0}" in
    1|true|yes|on) MAKE_DIST_FULL=1 ;;
    *)             MAKE_DIST_FULL=0 ;;
esac
# RESUME / FILES_ONLY skip the clone+make-dist; normalize to 0/1.
case "${RESUME:-0}"     in 1|true|yes|on) RESUME=1 ;;     *) RESUME=0 ;; esac
case "${FILES_ONLY:-0}" in 1|true|yes|on) FILES_ONLY=1 ;; *) FILES_ONLY=0 ;; esac
case "${SKIP_CTEST:-0}" in 1|true|yes|on) SKIP_CTEST=1 ;; *) SKIP_CTEST=0 ;; esac

# Must run natively on riscv64 (no QEMU).
if [ "$(uname -m)" != riscv64 ]; then
    echo "ERROR: host arch is $(uname -m); this CI must run on riscv64 hardware." >&2
    exit 1
fi

# Per-run timestamped log under this CI's own bucket; ${BASE}/run.log symlinks to the
# newest, so `tail -f spec-upstream/run.log` follows the current run. Separate bucket
# from build-check / spec-openruyi means the three never clobber each other.
mkdir -p "${BASE}/ci-log"
_RUN_LOG="${BASE}/ci-log/$(date +%Y%m%d-%H%M%S)-run.log"
ln -sfn "${_RUN_LOG}" "${BASE}/run.log"
_RUN_T0=$(date +%s)
exec > >(gawk -v t0="${_RUN_T0}" \
    '{ t = systime() - t0; printf "[%02d:%02d:%02d] %s\n", t/3600, (t%3600)/60, t%60, $0; fflush() }' \
    | stdbuf -oL tee -a "${_RUN_LOG}") 2>&1

# Cancel-safety: kill the named containers so an interrupt actually stops the build.
BUILD_CONTAINER="ceph_specin_build"
DEPS_CONTAINER="specin_deps_build"
_cleanup_on_signal() {
    trap - INT TERM
    [ -n "${MEM_SAMPLER_PID:-}" ] && kill "${MEM_SAMPLER_PID}" 2>/dev/null || true
    echo "=== interrupted: killing ${BUILD_CONTAINER} / ${DEPS_CONTAINER} ==="
    for _c in "${BUILD_CONTAINER}" "${DEPS_CONTAINER}"; do
        "${ENGINE}" kill "${_c}" >/dev/null 2>&1 || true
        "${ENGINE}" rm -f "${_c}" >/dev/null 2>&1 || true
    done
    exit 130
}
trap _cleanup_on_signal INT TERM

# Proxy: the host clone and make-dist's tarball downloads (github + download.ceph.com +
# archives.boost.io) need the proxy; dnf reaches the openRuyi repos direct (CI_NO_PROXY).
# Same probe method as the other paths: probe a git smart-http endpoint, not the web root.
CI_PROXY_PROBE="${CI_PROXY_PROBE:-http://10.200.1.1:8888}"
CI_PROXY_PROBE_URL="${CI_PROXY_PROBE_URL:-${CEPH_REPO}/info/refs?service=git-upload-pack}"
CI_PROXY_PROBE_RETRIES="${CI_PROXY_PROBE_RETRIES:-5}"
CI_PROXY_PROBE_DELAY="${CI_PROXY_PROBE_DELAY:-5}"
CI_NO_PROXY="${CI_NO_PROXY:-boat.openruyi.cn,repo.build.openruyi.cn,.openruyi.cn,goproxy.cn,127.0.0.1,localhost}"
PROXY=""
if [ "${GIT_PROXY:-}" = direct ]; then
    PROXY=""
elif [ -n "${GIT_PROXY:-}" ]; then
    PROXY="${GIT_PROXY}"
else
    _try=1
    while [ "${_try}" -le "${CI_PROXY_PROBE_RETRIES}" ]; do
        if curl -fsS -x "${CI_PROXY_PROBE}" -m 10 -o /dev/null "${CI_PROXY_PROBE_URL}" 2>/dev/null; then
            PROXY="${CI_PROXY_PROBE}"
            echo "  proxy: auto-detected ${CI_PROXY_PROBE} (attempt ${_try})"
            break
        fi
        echo "  proxy: probe ${CI_PROXY_PROBE} failed (${_try}/${CI_PROXY_PROBE_RETRIES})" >&2
        [ "${_try}" -lt "${CI_PROXY_PROBE_RETRIES}" ] && sleep "${CI_PROXY_PROBE_DELAY}"
        _try=$((_try + 1))
    done
    if [ -z "${PROXY}" ]; then
        echo "ERROR: proxy probe ${CI_PROXY_PROBE} could not reach the git remote; aborting" >&2
        echo "       (set GIT_PROXY=direct to force a proxy-less run)" >&2
        exit 1
    fi
fi

echo "=== ceph-ci upstream ceph.spec.in validation ==="
echo "  repo=${CEPH_REPO} ref=${CEPH_REF}  checkout=${CEPH_SRC}"
echo "  base=${BASE}  engine=${ENGINE}  NPROC=${NPROC}  CTEST_JOBS=${CTEST_JOBS}"
echo "  proxy='${PROXY}' (empty=direct)  MAKE_DIST_FULL=${MAKE_DIST_FULL} (0=skip dashboard npm)"
echo "  TEMP_OBS_REPO=${TEMP_OBS_REPO}  RESUME=${RESUME} FILES_ONLY=${FILES_ONLY} SKIP_CTEST=${SKIP_CTEST}"

# ctest options from known-failures.json -> CHECK_MAKEOPTS, same assembly as the other paths.
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

# ----------------------------------------------------------------------------
# 1. Clean upstream checkout (NO fork patches). Skipped on RESUME/FILES_ONLY, which
#    reuse the persisted spec/tarball + BUILD/ tree. Mirrors run-build-check.sh's
#    clone/fetch/checkout/submodule, minus the patch-apply steps.
# ----------------------------------------------------------------------------
declare -a GIT_PROXY_ARGS
if [ -n "${PROXY}" ]; then
    GIT_PROXY_ARGS=(-c "http.proxy=${PROXY}" -c "https.proxy=${PROXY}")
else
    GIT_PROXY_ARGS=(-c "http.proxy=" -c "https.proxy=")
fi
if [ "${RESUME}" = 1 ] || [ "${FILES_ONLY}" = 1 ]; then
    [ -d "${CEPH_SRC}/.git" ] || {
        echo "ERROR: RESUME/FILES_ONLY but no checkout at ${CEPH_SRC}; run a full build first." >&2
        exit 1; }
    echo "=== RESUME/FILES_ONLY: reuse existing checkout (skip clone/fetch/make-dist) ==="
else
    if [ ! -d "${CEPH_SRC}/.git" ]; then
        git "${GIT_PROXY_ARGS[@]}" clone "${CEPH_REPO}" "${CEPH_SRC}"
    fi
    if ! pgrep -x git >/dev/null; then
        find "${CEPH_SRC}/.git" -name "*.lock" -delete
    fi
    if git -C "${CEPH_SRC}" "${GIT_PROXY_ARGS[@]}" fetch --force --tags "${CEPH_REPO}" "${CEPH_REF}"; then
        git -C "${CEPH_SRC}" checkout --force FETCH_HEAD
    elif git -C "${CEPH_SRC}" rev-parse --verify --quiet "${CEPH_REF}^{commit}" >/dev/null; then
        echo "fetch of ${CEPH_REF} failed; commit exists locally, using local object"
        git -C "${CEPH_SRC}" checkout --force "${CEPH_REF}"
    else
        echo "ERROR: cannot fetch ${CEPH_REF} and it is not present locally" >&2
        exit 1
    fi
    # Drop untracked files (incl. a prior make-dist's in-tree tarball/spec/symlink) so they
    # don't accumulate; -d for dirs, no -x so submodule/build artifacts under ignore survive.
    git -C "${CEPH_SRC}" clean -fd
    # make-dist needs full submodules (git-archive-all + boost/rook gen). --force re-checks
    # out incomplete worktrees; the -c http.proxy reaches child clones via GIT_CONFIG_PARAMETERS.
    git -C "${CEPH_SRC}" "${GIT_PROXY_ARGS[@]}" submodule update --init --force --recursive ${PROXY:+--jobs 4}
    CEPH_SHA="$(git -C "${CEPH_SRC}" rev-parse --short HEAD)"
    echo "checked out upstream ceph ${CEPH_REF} @ ${CEPH_SHA}"

    # Optional patches under test (e.g. one you're preparing to submit upstream): any
    # *.patch in scripts/upstream-spec/ is applied here, in filename order. None present
    # -> a pristine upstream build (the original intent of this path). We COMMIT them
    # because make-dist's tarball comes from `git archive HEAD`, so source-code changes
    # would otherwise not reach the build; a ceph.spec.in-only patch would also work
    # uncommitted (make-dist generates the spec by `cat`-ing the working-tree spec.in),
    # but committing keeps both kinds correct. The DEPS_FP below is computed from the
    # (now patched) ceph.spec.in, so a patch that changes BuildRequires rebuilds the
    # deps image. `checkout --force` next run discards this commit, so it stays idempotent.
    shopt -s nullglob
    _patches=( "${REPO_ROOT}/scripts/upstream-spec/"*.patch )
    shopt -u nullglob
    if [ "${#_patches[@]}" -gt 0 ]; then
        echo "=== applying ${#_patches[@]} patch(es) from scripts/upstream-spec/ ==="
        for _p in "${_patches[@]}"; do
            echo "  ${_p##*/}"
            # --3way tolerates minor base drift; a hard failure means the patch needs a rebase.
            if ! git -C "${CEPH_SRC}" apply --3way --whitespace=nowarn "${_p}"; then
                echo "ERROR: failed to apply ${_p##*/} onto ${CEPH_REF}; rebase the patch." >&2
                exit 1
            fi
        done
        # A patch may bump a submodule gitlink (1065-seastar-bump.patch moves src/seastar
        # to a riscv64-capable commit -- pristine upstream seastar has no riscv cacheline/
        # hugepage sizes, so crimson's %build dies "not defined for this architecture").
        # git apply --3way records the new gitlink in the INDEX, but the submodule worktree
        # still holds the old checkout; a plain `git add -A` would then re-stage the gitlink
        # from that old worktree HEAD, silently dropping the bump. So check the submodules out
        # to the index gitlink FIRST, then add -A records the new sha and make-dist's
        # git-archive-all packs the bumped submodule. No gitlink change -> a cheap no-op.
        git -C "${CEPH_SRC}" "${GIT_PROXY_ARGS[@]}" submodule update --init --force --recursive ${PROXY:+--jobs 4}
        # Throwaway checkout -> set the committer identity inline; -s for a Signed-off-by.
        git -C "${CEPH_SRC}" add -A
        git -C "${CEPH_SRC}" -c user.name="ceph-ci" -c user.email="ceph-ci@localhost" \
            commit -s -q -m "ceph-ci: apply scripts/upstream-spec patches for validation"
        echo "  patched HEAD: $(git -C "${CEPH_SRC}" rev-parse --short HEAD)"
    else
        echo "  no patches in scripts/upstream-spec/ -- pristine upstream build"
    fi
fi

# ----------------------------------------------------------------------------
# 2. Persistent host dirs bound into the container (all SPECIN_-namespaced so they never
#    collide with the build-check or spec-openruyi caches):
#      sources   : the make-dist Source0 tarball (persists for RESUME)
#      rpms      : built rpms (~/rpmbuild/RPMS) -- populated in SKIP_CTEST mode
#      artifacts : ctest Testing/ + CMakeCache copied out
#      sccache-cache : sccache cache, in this bucket, separate from the other paths' caches
#      build     : the rpm BUILD/ tree (cmake build + nested BUILDROOT), bind-mounted
#                         so a failed run is inspectable and RESUME/FILES_ONLY can reuse it
#      state     : the make-dist-generated ceph.spec (so RESUME can restage it)
# ----------------------------------------------------------------------------
SOURCES_CACHE="${BASE}/sources"
RPMS_OUT="${BASE}/rpms"
ARTIFACTS="${BASE}/artifacts"
BUILD_PERSIST="${SPECIN_BUILD_DIR:-${BASE}/build}"
STATE_DIR="${BASE}/state"
SCCACHE_HOST_DIR="${SPECIN_SCCACHE_HOST_DIR:-${BASE}/sccache-cache}"
SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-100G}"
TD_TMPFS="${SPECIN_TD_TMPFS_DIR:-/dev/shm/ceph-ci-specin-td}"
mkdir -p "${SOURCES_CACHE}" "${RPMS_OUT}" "${ARTIFACTS}" "${SCCACHE_HOST_DIR}" "${BUILD_PERSIST}" "${STATE_DIR}"
rm -rf "${TD_TMPFS}"; mkdir -p "${TD_TMPFS}"

# 3. ensure the openRuyi base image is present
OFFLINE="${OFFLINE:-0}" "${REPO_ROOT}/scripts/fetch-openruyi-image.sh"

declare -a PROXY_ENV=()
if [ -n "${PROXY}" ]; then
    PROXY_ENV=(-e "http_proxy=${PROXY}" -e "https_proxy=${PROXY}" -e "no_proxy=${CI_NO_PROXY}")
fi

# ----------------------------------------------------------------------------
# 4. Cached deps image. Same scheme as the openRuyi-spec path: bake the cacheable half
#    (rpm tooling, make-dist tools, gcc-c++, sccache, builddep'd BuildRequires) into a
#    derived image and build FROM it. Fingerprint keys on the spec's BuildRequires (read
#    from ceph.spec.in) + TEMP_OBS_REPO + base id; reuse / refresh / rebuild as cheapest.
# ----------------------------------------------------------------------------
BASE_IMAGE="localhost/openruyi-oci:riscv64"
DEPS_IMAGE="localhost/specin-deps:riscv64"
DEPS_FP_FILE="${BASE}/.deps-fp"
DEPS_PKGHASH_FILE="${BASE}/.deps-pkghash"
DEPS_META_DIR="${BASE}/.deps-meta"
_base_id="$("${ENGINE}" image inspect --format '{{.Id}}' "${BASE_IMAGE}" 2>/dev/null | cut -c1-19)"
DEPS_FP="br:$(grep -E '^(BuildRequires|BuildConflicts):' "${CEPH_SRC}/ceph.spec.in" | sha256sum | cut -d' ' -f1) tempobs:${TEMP_OBS_REPO} base:${_base_id}"

_deps_exists=0
"${ENGINE}" image inspect "${DEPS_IMAGE}" >/dev/null 2>&1 && _deps_exists=1
_fp_ok=0
[ "$(cat "${DEPS_FP_FILE}" 2>/dev/null || true)" = "${DEPS_FP}" ] && _fp_ok=1

_deps_src=""; _deps_reason=""
if [ "${_deps_exists}" = 0 ]; then
    _deps_src="${BASE_IMAGE}"; _deps_reason="rebuild: deps image missing (first run)"
elif [ "${_fp_ok}" = 0 ]; then
    _deps_src="${BASE_IMAGE}"; _deps_reason="rebuild: BuildRequires/base image changed"
elif [ "${REBUILD_DEPS}" = 1 ]; then
    _deps_src="${DEPS_IMAGE}"; _deps_reason="refresh: REBUILD_DEPS -- pick up rolling package updates in place"
fi

if [ -n "${_deps_src}" ]; then
    echo "=== deps image ${DEPS_IMAGE}: ${_deps_reason} (from ${_deps_src}) ==="
    rm -rf "${DEPS_META_DIR}"; mkdir -p "${DEPS_META_DIR}"
    _old_deps_id="$("${ENGINE}" image inspect --format '{{.Id}}' "${DEPS_IMAGE}" 2>/dev/null || true)"
    "${ENGINE}" rm -f "${DEPS_CONTAINER}" >/dev/null 2>&1 || true
    # The deps phase only needs the checkout to read ceph.spec.in's BuildRequires.
    "${ENGINE}" run --name "${DEPS_CONTAINER}" \
        --pids-limit=-1 \
        -e "PHASE=deps" \
        -e "TEMP_OBS_REPO=${TEMP_OBS_REPO}" \
        "${PROXY_ENV[@]}" \
        -v "${CEPH_SRC}:/ceph:ro" \
        -v "${REPO_ROOT}/scripts/upstream-spec/spec-in-build-in-container.sh:/spec-build.sh:ro" \
        -v "${DEPS_META_DIR}:/deps-meta:Z" \
        "${_deps_src}" \
        bash /spec-build.sh

    _new_pkghash="$(cat "${DEPS_META_DIR}/pkghash" 2>/dev/null || true)"
    _old_pkghash="$(cat "${DEPS_PKGHASH_FILE}" 2>/dev/null || true)"
    if [ "${_deps_exists}" = 1 ] && [ -n "${_new_pkghash}" ] && [ "${_new_pkghash}" = "${_old_pkghash}" ]; then
        echo "  package set unchanged (pkghash ${_new_pkghash:0:12}…); skipping commit, keeping cached image"
        "${ENGINE}" rm -f "${DEPS_CONTAINER}" >/dev/null 2>&1 || true
    else
        echo "  package set changed (or first build); committing deps image"
        "${ENGINE}" commit "${DEPS_CONTAINER}" "${DEPS_IMAGE}" >/dev/null
        "${ENGINE}" rm -f "${DEPS_CONTAINER}" >/dev/null 2>&1 || true
        _cur_deps_id="$("${ENGINE}" image inspect --format '{{.Id}}' "${DEPS_IMAGE}" 2>/dev/null || true)"
        if [ -n "${_old_deps_id}" ] && [ "${_old_deps_id}" != "${_cur_deps_id}" ]; then
            "${ENGINE}" rmi -f "${_old_deps_id}" >/dev/null 2>&1 || true
        fi
        [ -n "${_new_pkghash}" ] && printf '%s\n' "${_new_pkghash}" > "${DEPS_PKGHASH_FILE}"
        echo "  deps image ready: ${DEPS_IMAGE}"
    fi
    printf '%s\n' "${DEPS_FP}" > "${DEPS_FP_FILE}"
else
    echo "=== reusing cached deps image ${DEPS_IMAGE} (fingerprint unchanged, no rebuild_deps) ==="
fi

# ----------------------------------------------------------------------------
# 5. Background memory sampler (the build + ctest are OOM-prone; an OOM is a global kill
#    we cannot watch live), same as the other paths.
# ----------------------------------------------------------------------------
MEM_LOG="${BASE}/ci-log/$(date +%Y%m%d-%H%M%S)-mem.log"
ln -sfn "${MEM_LOG}" "${BASE}/mem-usage.log"
_mem_sampler() {
    local phase last_phase=""
    while :; do
        if pgrep -x ctest >/dev/null 2>&1; then phase=TEST; else phase=BUILD; fi
        if [ "${phase}" != "${last_phase}" ]; then
            printf '===== %s phase @ %s =====\n' "${phase}" "$(date '+%H:%M:%S')"
            last_phase="${phase}"
        fi
        free -m | awk -v ts="$(date '+%H:%M:%S')" -v ph="${phase}" \
            '/^Mem:/{printf "[%s %s] used=%sM avail=%sM", ts, ph, $3, $7}'
        ps -eo rss=,comm= --sort=-rss | awk 'NR<=6{printf " %s=%dM", $2, $1/1024} END{print ""}'
        sleep "${MEM_SAMPLE_INTERVAL:-5}"
    done
}
_mem_sampler >> "${MEM_LOG}" 2>&1 &
MEM_SAMPLER_PID=$!
echo "  memory sampler pid=${MEM_SAMPLER_PID} -> ${MEM_LOG}"

# ----------------------------------------------------------------------------
# 6. make-dist + rpmbuild + ctest in the container. --pids-limit=-1: lift podman's
#    2048-pid cap (a -j${NPROC} build with sccache spawns past it). Build FROM the deps
#    image. The checkout is bind-mounted rw -- make-dist writes the tarball/spec into it.
# ----------------------------------------------------------------------------
set +e
"${ENGINE}" run --rm --name "${BUILD_CONTAINER}" \
    --pids-limit=-1 \
    -e "PHASE=build" \
    -e "NPROC=${NPROC}" \
    -e "CHECK_MAKEOPTS=${CHECK_MAKEOPTS}" \
    -e "TEMP_OBS_REPO=${TEMP_OBS_REPO}" \
    -e "MAKE_DIST_FULL=${MAKE_DIST_FULL}" \
    -e "SCCACHE_DIR=/root/.cache/sccache" \
    -e "SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}" \
    -e "SCCACHE_IDLE_TIMEOUT=0" \
    -e "RESUME=${RESUME}" \
    -e "FILES_ONLY=${FILES_ONLY}" \
    -e "SKIP_CTEST=${SKIP_CTEST}" \
    "${PROXY_ENV[@]}" \
    -v "${CEPH_SRC}:/ceph:Z" \
    -v "${REPO_ROOT}/scripts/upstream-spec/spec-in-build-in-container.sh:/spec-build.sh:ro" \
    -v "${SOURCES_CACHE}:/root/rpmbuild/SOURCES:Z" \
    -v "${RPMS_OUT}:/root/rpmbuild/RPMS:Z" \
    -v "${BUILD_PERSIST}:/root/rpmbuild/BUILD:Z" \
    -v "${STATE_DIR}:/state:Z" \
    -v "${ARTIFACTS}:/out:Z" \
    -v "${SCCACHE_HOST_DIR}:/root/.cache/sccache:Z" \
    -v "${TD_TMPFS}:/td-tmpfs:Z" \
    "${DEPS_IMAGE}" \
    bash /spec-build.sh
RC=$?
set -e

kill "${MEM_SAMPLER_PID}" 2>/dev/null || true
wait "${MEM_SAMPLER_PID}" 2>/dev/null || true
echo "=== memory peak during build (full timeline: ${MEM_LOG}) ==="
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
gawk 'match($0,/(ld\.mold|mold|cc1plus|cc1)=([0-9]+)M/,a){if(a[2]+0>m){m=a[2]+0;p=a[1]}}
      END{if(m)print "  peak "p" RSS="m"M"}' "${MEM_LOG}" || true

echo "=== upstream spec.in validation done: rc=${RC} ==="
echo "  checkout:  ${CEPH_SRC}"
echo "  rpms:      ${RPMS_OUT} (populated only in SKIP_CTEST mode)"
echo "  artifacts: ${ARTIFACTS}"
echo "  sccache:   ${SCCACHE_HOST_DIR} (max ${SCCACHE_CACHE_SIZE})"
echo "  mem log:   ${MEM_LOG}"
exit ${RC}
