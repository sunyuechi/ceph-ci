#!/usr/bin/env bash
#
# Validate the openRuyi downstream ceph spec (openruyi/) the way OBS does, minus
# OBS: run `rpmbuild` for openruyi/ceph.spec inside the openRuyi container, then
# run our ctest on the spec's own build tree. The container half lives in
# spec-build-in-container.sh; this driver sets up the host side (image, proxy,
# persistent caches, ctest options) and launches it.
#
# The spec does all of %prep itself (submodule tarballs, isa-l v2.32.0 swap,
# %autopatch) -- there is no hand-rolled patch reproduction here, unlike the
# upstream-main path in run-build-check.sh. The build is the spec's real
# downstream config (WITH_CRIMSON=OFF, RelWithDebInfo, no ASan).
#
# Env overrides:
#   WORKDIR       parent of the per-CI buckets (default: this repo's parent dir);
#                 this CI lives entirely under ${WORKDIR}/spec-openruyi/
#   NPROC         build parallelism (default set below)
#   CTEST_JOBS    ctest -j (default $(nproc))
#   CONTAINER_ENGINE  podman (default) or docker
#   TEMP_OBS_REPO 1 (default) add home:sunyuechi:openruyi-test as a priority=1 dnf
#                 repo so deps it publishes win over the stock repos (carries the
#                 spec's promtool BuildRequire); 0 = stock openRuyi repos only
#   REBUILD_DEPS  1 to refresh the cached deps image (localhost/openruyi-deps, holds the
#                 tooling + gcc-c++ + sccache + builddep'd BuildRequires) -- runs dnf FROM
#                 the existing image to pick up rolling openRuyi package updates, and only
#                 commits a new image layer if the package set actually changed (a no-op
#                 refresh skips the commit, so a same-as-last-time rebuild_deps is cheap).
#                 Default 0 reuses the image as-is while its fingerprint (spec
#                 BuildRequires + TEMP_OBS_REPO + base id) holds. A missing image or a
#                 changed fingerprint forces a full rebuild from the base image instead.
#   GIT_PROXY     proxy for external network (spectool fetches github/boost.io);
#                 unset = auto-probe via CI_PROXY_PROBE; 'direct' forces none
#   CI_PROXY_PROBE      proxy probed for auto-detect (default http://10.200.1.1:8888)
#   CI_PROXY_PROBE_URL  URL the probe fetches through the proxy (default: a github
#                       git smart-http endpoint, NOT the policy-blocked web root)
#   CI_PROXY_PROBE_RETRIES  probe attempts before aborting as a network error (default 5)
#   CI_PROXY_PROBE_DELAY    seconds between probe attempts (default 5)
#   CI_NO_PROXY         hosts that bypass the proxy (openRuyi repos + loopback)
#   FLAKE_RETRIES ctest --repeat until-pass count for known flakes (default 2)
#   OFFLINE       1 to reuse the cached local image instead of pulling
#   OPENRUYI_SCCACHE_HOST_DIR  sccache cache dir (default ${WORKDIR}/spec-openruyi/sccache-cache);
#                 OPENRUYI_-prefixed so it never collides with the build-check path's SCCACHE_HOST_DIR
#   OPENRUYI_TD_TMPFS_DIR  standalone-test tmpfs td dir (default /dev/shm/ceph-ci-openruyi-td);
#                 likewise distinct from the build-check path's TD_TMPFS_DIR
#
# Incremental re-run knobs. The BUILD/ tree -- which holds BOTH the cmake build and
# (rpm 4.20 nests it there) the BUILDROOT -- is bind-mounted to ${WORKDIR}/spec-openruyi/build,
# so it now survives the --rm container and a failed run; that is what makes these work:
#   FILES_ONLY=1  re-run only the %files packaging check (rpmbuild -bl) against the
#                 BUILDROOT a prior full run left behind -- seconds, no compile/install.
#                 The fix for a %files mismatch on a version bump (renamed unit, moved
#                 file): %install already succeeded, only the file list is wrong. Implies
#                 skipping ctest.
#   RESUME=1      reuse the persisted BUILD/ tree: rpmbuild --noprep skips %prep (no
#                 tarball re-extract, no isa-l swap, no %autopatch), %build is a ninja
#                 incremental (no-op if sources are untouched; sccache covers the rest),
#                 then %install + packaging re-run. For spec-only or small source edits;
#                 do a full run (RESUME unset) after changing patches/sources.
#   SKIP_CTEST=1  stop once rpmbuild succeeds (the rpm is already on the host via RPMS/);
#                 skip the build-check ctest -- unrelated to a packaging/%files fix.
#   OPENRUYI_BUILD_DIR  persisted BUILD/ tree dir (default ${WORKDIR}/spec-openruyi/build)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENRUYI_DIR="${REPO_ROOT}/openruyi"
WORKDIR="${WORKDIR:-$(dirname "${REPO_ROOT}")}"
# This CI owns ${WORKDIR}/spec-openruyi/ -- its own subdir, so logs/caches/build tree
# never interleave with the build-check or spec-upstream CIs. (See run-build-check.sh.)
BASE="${WORKDIR}/spec-openruyi"
mkdir -p "${BASE}"
ENGINE="${CONTAINER_ENGINE:-podman}"
NPROC="${NPROC:-50}"
CTEST_JOBS="${CTEST_JOBS:-$(nproc)}"

# Prefer the temporary OBS project home:sunyuechi:openruyi-test (priority=1) for deps,
# same toggle as the build-check path: it carries packages the stock repos lack -- notably the
# spec's `BuildRequires: promtool` (provided by its `prometheus` pkg). Normalize to
# 0/1 (forwarded verbatim to the container half). Default 1.
case "${TEMP_OBS_REPO:-1}" in
    0|false|no|off) TEMP_OBS_REPO=0 ;;
    *)              TEMP_OBS_REPO=1 ;;
esac

# REBUILD_DEPS forces a rebuild of the cached deps image (picks up rolling openRuyi
# package updates). Normalize to 0/1. Default 0 -> reuse the cached image when its
# fingerprint still matches. Unlike the prior behavior, this path now honors it.
case "${REBUILD_DEPS:-0}" in
    1|true|yes|on) REBUILD_DEPS=1 ;;
    *)             REBUILD_DEPS=0 ;;
esac

[ -f "${OPENRUYI_DIR}/ceph.spec" ] || {
    echo "ERROR: ${OPENRUYI_DIR}/ceph.spec not found" >&2; exit 1; }

# Must run natively on riscv64 (no QEMU).
if [ "$(uname -m)" != riscv64 ]; then
    echo "ERROR: host arch is $(uname -m); this CI must run on riscv64 hardware." >&2
    exit 1
fi

# Per-run timestamped log under this CI's own bucket; ${BASE}/run.log symlinks to the
# newest, so `tail -f spec-openruyi/run.log` follows the current run. Separate bucket
# from build-check / spec-upstream means the three never clobber each other.
mkdir -p "${BASE}/ci-log"
_RUN_LOG="${BASE}/ci-log/$(date +%Y%m%d-%H%M%S)-run.log"
ln -sfn "${_RUN_LOG}" "${BASE}/run.log"
_RUN_T0=$(date +%s)
exec > >(gawk -v t0="${_RUN_T0}" \
    '{ t = systime() - t0; printf "[%02d:%02d:%02d] %s\n", t/3600, (t%3600)/60, t%60, $0; fflush() }' \
    | stdbuf -oL tee -a "${_RUN_LOG}") 2>&1

# Cancel-safety: kill the named container so an interrupt actually stops the build
# (the podman client dying leaves conmon's container running under init otherwise).
BUILD_CONTAINER="ceph_openruyi_build"
DEPS_CONTAINER="openruyi_deps_build"   # transient: PHASE=deps run that gets committed
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

# Proxy: spectool fetches Source0..33 from github.com + archives.boost.io, which
# need the proxy from this host; dnf reaches the openRuyi repos direct (CI_NO_PROXY).
# Same policy AND same probe method as run-build-check.sh: probe a github git
# smart-http endpoint, NOT the web root -- the proxy policy-blocks github's web root
# and api, so probing those false-negatives even when the archive downloads work.
# (spectool's github archive fetches hit codeload over this same proxy.) podman
# forwards *_proxy into the container.
CI_PROXY_PROBE="${CI_PROXY_PROBE:-http://10.200.1.1:8888}"
CI_PROXY_PROBE_URL="${CI_PROXY_PROBE_URL:-https://github.com/ceph/ceph.git/info/refs?service=git-upload-pack}"
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
        echo "ERROR: proxy probe ${CI_PROXY_PROBE} could not reach github; aborting" >&2
        echo "       (set GIT_PROXY=direct to force a proxy-less run)" >&2
        exit 1
    fi
fi

echo "=== ceph-ci openRuyi spec validation ==="
echo "  spec=${OPENRUYI_DIR}/ceph.spec  base=${BASE}  engine=${ENGINE}"
echo "  NPROC=${NPROC}  CTEST_JOBS=${CTEST_JOBS}  proxy='${PROXY}' (empty=direct)"
echo "  TEMP_OBS_REPO=${TEMP_OBS_REPO} (1=prefer home:sunyuechi:openruyi-test, 0=stock repos only)"

# ctest options from known-failures.json -> CHECK_MAKEOPTS, same assembly as
# run-build-check.sh (exclude/flake entries; --timeout is a fallback ceiling).
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

# Persistent host dirs bound into the container:
#   sources   : Source0..33 tarball cache (rpmdev-spectool skips present files)
#   rpms      : built rpms land here (~/rpmbuild/RPMS)
#   artifacts : ctest Testing/ + CMakeCache copied out by the container
#   sccache-cache : sccache cache, in this bucket so it never shares the build-check
#                  (run-build-check.sh) cache, whose differing compile flags would
#                  churn one shared cache. sccache is content-addressed, so it hits
#                  even though rpmbuild reconfigures a fresh BUILD/ each run -- that
#                  recovers most of what a clean rebuild would lose.
#   build     : the rpm BUILD/ tree (cmake build + nested BUILDROOT), bind-mounted
#                  so it survives the --rm container -> failed runs are inspectable and
#                  RESUME/FILES_ONLY can reuse it. rpm 4.20 nests BUILDROOT under
#                  BUILD/<name>-<ver>-build/, so this single mount covers both.
SOURCES_CACHE="${BASE}/sources"
RPMS_OUT="${BASE}/rpms"
ARTIFACTS="${BASE}/artifacts"
BUILD_PERSIST="${OPENRUYI_BUILD_DIR:-${BASE}/build}"
# Location overrides use OPENRUYI_-prefixed names, NOT the build-check path's SCCACHE_HOST_DIR /
# TD_TMPFS_DIR: sharing those names would let an `export SCCACHE_HOST_DIR=...` meant
# for run-build-check.sh redirect this path onto the same dir. SCCACHE_CACHE_SIZE is
# a tuning value (not a location), so sharing it is harmless and intentional.
SCCACHE_HOST_DIR="${OPENRUYI_SCCACHE_HOST_DIR:-${BASE}/sccache-cache}"
SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-100G}"
TD_TMPFS="${OPENRUYI_TD_TMPFS_DIR:-/dev/shm/ceph-ci-openruyi-td}"
mkdir -p "${SOURCES_CACHE}" "${RPMS_OUT}" "${ARTIFACTS}" "${SCCACHE_HOST_DIR}" "${BUILD_PERSIST}"
rm -rf "${TD_TMPFS}"; mkdir -p "${TD_TMPFS}"
echo "  RESUME=${RESUME:-0} FILES_ONLY=${FILES_ONLY:-0} SKIP_CTEST=${SKIP_CTEST:-0}  BUILD persist=${BUILD_PERSIST}"

# 1. ensure the openRuyi base image is present
OFFLINE="${OFFLINE:-0}" "${REPO_ROOT}/scripts/fetch-openruyi-image.sh"

# 2. run rpmbuild + ctest in the container
declare -a PROXY_ENV=()
if [ -n "${PROXY}" ]; then
    PROXY_ENV=(-e "http_proxy=${PROXY}" -e "https_proxy=${PROXY}" -e "no_proxy=${CI_NO_PROXY}")
fi

# 2a. Cached deps image. The build container is --rm from a base image, so without this
#     every run would reinstall the rpm tooling + gcc-c++ + sccache + the full `dnf
#     builddep` BuildRequires from scratch. Bake that cacheable half into a derived image
#     (spec-build.sh PHASE=deps) and run the actual build FROM it -- the same idea as the
#     build-check path's bwc build image. Three outcomes, cheapest first:
#       reuse   : fingerprint unchanged and no REBUILD_DEPS -> use the image as-is, no
#                 container at all. Fingerprint keys on the spec's BuildRequires +
#                 TEMP_OBS_REPO + base image id, so editing %files / %build does NOT bust
#                 it (a %files iteration reuses the deps image).
#       refresh : REBUILD_DEPS set and the image already exists with a matching
#                 fingerprint -> run PHASE=deps FROM the existing deps image so dnf only
#                 refreshes metadata + upgrades the already-installed packages to pick up
#                 rolling openRuyi updates. Then commit ONLY if the resolved package set
#                 actually changed -- a no-update refresh resolves identically and skips
#                 the CPU-heavy commit, which is the common case for a rebuild_deps run.
#       rebuild : image missing or fingerprint changed -> full PHASE=deps FROM the base
#                 image (the expensive ~3GB commit), the one-time cost per structural change.
BASE_IMAGE="localhost/openruyi-oci:riscv64"
DEPS_IMAGE="localhost/openruyi-deps:riscv64"
DEPS_FP_FILE="${BASE}/.deps-fp"
DEPS_PKGHASH_FILE="${BASE}/.deps-pkghash"   # NEVRA hash of the cached image's pkgs
DEPS_META_DIR="${BASE}/.deps-meta"          # rw bind mount: deps phase drops pkghash here
_base_id="$("${ENGINE}" image inspect --format '{{.Id}}' "${BASE_IMAGE}" 2>/dev/null | cut -c1-19)"
DEPS_FP="br:$(grep -E '^(BuildRequires|BuildConflicts):' "${OPENRUYI_DIR}/ceph.spec" | sha256sum | cut -d' ' -f1) tempobs:${TEMP_OBS_REPO} base:${_base_id}"

_deps_exists=0
"${ENGINE}" image inspect "${DEPS_IMAGE}" >/dev/null 2>&1 && _deps_exists=1
_fp_ok=0
[ "$(cat "${DEPS_FP_FILE}" 2>/dev/null || true)" = "${DEPS_FP}" ] && _fp_ok=1

_deps_src=""        # empty -> reuse as-is (no container)
_deps_reason=""
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
    # Old image id: a commit re-points the tag and leaves the old one dangling -> prune it.
    _old_deps_id="$("${ENGINE}" image inspect --format '{{.Id}}' "${DEPS_IMAGE}" 2>/dev/null || true)"
    "${ENGINE}" rm -f "${DEPS_CONTAINER}" >/dev/null 2>&1 || true
    # --pids-limit=-1 matches the build run (builddep + scriptlets fan out widely). No
    # SOURCES/BUILD mounts: the deps phase only needs the spec to parse BuildRequires.
    # /deps-meta is where the deps phase writes the installed-package hash for the
    # commit-or-skip decision below.
    "${ENGINE}" run --name "${DEPS_CONTAINER}" \
        --pids-limit=-1 \
        -e "PHASE=deps" \
        -e "TEMP_OBS_REPO=${TEMP_OBS_REPO}" \
        "${PROXY_ENV[@]}" \
        -v "${OPENRUYI_DIR}:/spec:ro" \
        -v "${REPO_ROOT}/scripts/openruyi/spec-build-in-container.sh:/spec-build.sh:ro" \
        -v "${DEPS_META_DIR}:/deps-meta:Z" \
        "${_deps_src}" \
        bash /spec-build.sh

    # Commit only when the resolved package set differs from the cached image -- a
    # REBUILD_DEPS refresh that found no updates resolves to the same NEVRA set, so skip
    # the CPU-heavy layer commit entirely and keep the existing image.
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

# Background memory sampler, same as the build-check path (run-build-check.sh): the
# rpmbuild is OOM-prone, and an OOM is a global kill we cannot watch live. Sample host
# memory + top RSS every MEM_SAMPLE_INTERVAL seconds to a sibling mem.log so a killed
# run can be diagnosed afterwards. Host-side ps sees the in-container procs.
MEM_LOG="${BASE}/ci-log/$(date +%Y%m%d-%H%M%S)-mem.log"
ln -sfn "${MEM_LOG}" "${BASE}/mem-usage.log"
_mem_sampler() {
    local phase last_phase=""
    while :; do
        # Phase = build vs test, inferred from whether ctest is running (host pgrep
        # sees the in-container ctest). rpmbuild + the tests-target build precede our
        # ctest; once ctest is up we are in the test phase. Emit a banner on each
        # transition so the two halves are easy to tell apart, and tag every sample
        # line with the phase so a grep / the peak summary can attribute it.
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

set +e
# --pids-limit=-1: lift podman's default 2048-pid cgroup cap, same as bwc does on the
# build-check path. A -j${NPROC} ninja build with sccache spawns well past 2048 live procs
# (each compile = cc driver + cc1plus + sccache client/server threads) and otherwise
# dies early with "ninja: fatal: posix_spawn: Resource temporarily unavailable".
# Build FROM the cached deps image (PHASE=build), not the bare base image: the tooling,
# gcc-c++, sccache binary, and builddep'd BuildRequires are already baked in, so this run
# does no dnf install -- it stages the spec and goes straight to rpmbuild.
"${ENGINE}" run --rm --name "${BUILD_CONTAINER}" \
    --pids-limit=-1 \
    -e "PHASE=build" \
    -e "NPROC=${NPROC}" \
    -e "CHECK_MAKEOPTS=${CHECK_MAKEOPTS}" \
    -e "TEMP_OBS_REPO=${TEMP_OBS_REPO}" \
    -e "SCCACHE_DIR=/root/.cache/sccache" \
    -e "SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}" \
    -e "SCCACHE_IDLE_TIMEOUT=0" \
    -e "RESUME=${RESUME:-0}" \
    -e "FILES_ONLY=${FILES_ONLY:-0}" \
    -e "SKIP_CTEST=${SKIP_CTEST:-0}" \
    "${PROXY_ENV[@]}" \
    -v "${OPENRUYI_DIR}:/spec:ro" \
    -v "${REPO_ROOT}/scripts/openruyi/spec-build-in-container.sh:/spec-build.sh:ro" \
    -v "${SOURCES_CACHE}:/root/rpmbuild/SOURCES:Z" \
    -v "${RPMS_OUT}:/root/rpmbuild/RPMS:Z" \
    -v "${BUILD_PERSIST}:/root/rpmbuild/BUILD:Z" \
    -v "${ARTIFACTS}:/out:Z" \
    -v "${SCCACHE_HOST_DIR}:/root/.cache/sccache:Z" \
    -v "${TD_TMPFS}:/td-tmpfs:Z" \
    "${DEPS_IMAGE}" \
    bash /spec-build.sh
RC=$?
set -e

# Stop the sampler and surface the host usage peak + peak compiler/linker RSS so an
# OOM shows up here without trawling the full mem timeline (same as the build-check path).
kill "${MEM_SAMPLER_PID}" 2>/dev/null || true
wait "${MEM_SAMPLER_PID}" 2>/dev/null || true
echo "=== memory peak during build (full timeline: ${MEM_LOG}) ==="
# Split by phase (build vs test, from the line tag) so the peak is attributed to the
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
gawk 'match($0,/(ld\.mold|mold|cc1plus|cc1)=([0-9]+)M/,a){if(a[2]+0>m){m=a[2]+0;p=a[1]}}
      END{if(m)print "  peak "p" RSS="m"M"}' "${MEM_LOG}" || true

echo "=== spec validation done: rc=${RC} ==="
echo "  rpms:      ${RPMS_OUT}"
echo "  artifacts: ${ARTIFACTS}"
echo "  sccache:   ${SCCACHE_HOST_DIR} (max ${SCCACHE_CACHE_SIZE})"
echo "  mem log:   ${MEM_LOG}"
exit ${RC}
