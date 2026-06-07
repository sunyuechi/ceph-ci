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
#   WITH_CRIMSON  true/1 to enable crimson (default off)
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
#   GIT_PROXY     proxy for external network; unset = auto-detect 127.0.0.1:7890
#                 (use only if it reaches github, else direct); 'direct' forces none
#   CI_PROXY_PROBE  port probed for auto-detect (default http://127.0.0.1:7890)
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
# port and use it only if it reaches github, else direct.
CI_PROXY_PROBE="${CI_PROXY_PROBE:-http://127.0.0.1:7890}"
if [ -z "${GIT_PROXY+x}" ]; then
    if curl -fsS -x "${CI_PROXY_PROBE}" -m 5 -o /dev/null https://github.com 2>/dev/null; then
        GIT_PROXY="${CI_PROXY_PROBE}"
        echo "  GIT_PROXY: auto-detected reverse proxy at ${CI_PROXY_PROBE}"
    else
        GIT_PROXY=""
        echo "  GIT_PROXY: none (probe ${CI_PROXY_PROBE} did not reach github; assuming direct)"
    fi
elif [ "${GIT_PROXY}" = direct ]; then
    GIT_PROXY=""
fi
# openRuyi's package repo must be reached directly (NOT via GIT_PROXY).
CI_NO_PROXY="${CI_NO_PROXY:-boat.openruyi.cn,repo.build.openruyi.cn,.openruyi.cn,127.0.0.1,localhost}"

# Must run natively on riscv64 (no QEMU).
if [ "$(uname -m)" != riscv64 ]; then
    echo "ERROR: host arch is $(uname -m); this CI must run on riscv64 hardware." >&2
    exit 1
fi

# bwc reads UNSET WITH_CRIMSON as ON; export empty to actually disable it.
case "${WITH_CRIMSON:-false}" in
    true|1|yes|on) export WITH_CRIMSON=1 ;;
    *)             export WITH_CRIMSON="" ;;
esac

echo "=== ceph-ci L2 run ==="
echo "  repo=${CEPH_REPO} ref=${CEPH_REF}"
echo "  workdir=${WORKDIR} engine=${ENGINE} steps=${STEPS}"
echo "  WITH_CRIMSON='${WITH_CRIMSON}' (empty=off)"
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

# 3. Fork patches, in listed order. Comment a line out to skip it. Numbering:
#    1xxx = upstream-bound (comment links the PR), 2xxx = openRuyi downstream.
#    An already-present patch is auto-skipped.
TREE_PATCHES=(
    # -- 1xxx: upstream-bound --
	# https://github.com/ceph/ceph/pull/69315
    1001-riscv64-fetch-sccache.patch
    # ours -- TODO: not submitted yet; planned ceph PR (openRuyi as a build target)
    1002-openruyi-build-tooling.patch
    # ours -- TODO: not submitted yet; same ceph PR as 1002 (openRuyi BuildRequires)
    1003-openruyi-spec-buildrequires.patch
    # https://github.com/ceph/ceph/pull/69165
    1004-cmake-catch2-imported-target.patch
    # https://github.com/ceph/ceph/pull/69157
    1005-test-mds-quiesce-agent-await-idle.patch
    # https://github.com/ceph/ceph/pull/69156
    1007-monitoring-jsonnet-bundler-v0.6.0.patch
	# 1003-openruyi-spec-buildrequires.patch
    1008-tests-venv-system-site-packages.patch
    # ours -- TODO: not submitted yet; follow-up to 1008 (typed system prettytable trips mgr mypy under system-site)
	1009-mypy-skip-follow_imports-for-prettytable.patch
    # -- 2xxx: openRuyi downstream, not for upstream --
    # bump pylint 2.6.0 -> 2.17.7 for py3.13 / wrapt compat
    2001-monitoring-ceph-mixin-bump-pylint.patch
    # bump cephadm pyfakefs pin to >=5.7,<6 for py3.13
    2002-cephadm-tox-pyfakefs-py313.patch
    # cephadm tox: drop flake8 git ls-files registry assertions (no .git in tarball)
    2003-cephadm-tox-drop-git-lsfiles-checks.patch
    # mgr tox: drop flake8 git ls-files refcount checks (no .git in tarball)
    2004-mgr-tox-skip-git-ls-files.patch
)
# 2005: prefer the temporary OBS project home:sunyuechi:openruyi-test (priority=1)
# for deps, falling back to stock openRuyi repos for packages it doesn't publish.
# Conditional: TEMP_OBS_REPO=0 leaves the patch out entirely.
if [ "${TEMP_OBS_REPO}" = 1 ]; then
    TREE_PATCHES+=(2005-openruyi-temp-obs-repo.patch)
fi

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

# 3d. cmake feature set. Flip OFF->ON to enable a feature (or override the whole
#     set via CONFIGURE_ARGS). crimson is NOT here — driven by WITH_CRIMSON.
CONFIGURE_FLAGS=(
    -DWITH_SPDK=OFF
    -DWITH_NVMEOF_GATEWAY_MONITOR_CLIENT=OFF
    -DWITH_RADOSGW_AMQP_ENDPOINT=OFF
    -DWITH_RADOSGW_KAFKA_ENDPOINT=OFF
    -DWITH_JAEGER=OFF
    -DWITH_MGR_DASHBOARD_FRONTEND=OFF
    -DWITH_SYSTEM_CATCH2=ON
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
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

# 4a. Container networking for proxied hosts (only when GIT_PROXY set). Image build
#     uses netns=host (to reach a 127.0.0.1 proxy); run container keeps host *_proxy
#     out. Must come AFTER the host git clone/fetch.
if [ -n "${GIT_PROXY}" ]; then
    CI_CONF_OVERRIDE="$(mktemp -t ci-containers-XXXXXX.conf)"
    printf '[containers]\nnetns = "host"\n' > "${CI_CONF_OVERRIDE}"
    export CONTAINERS_CONF_OVERRIDE="${CI_CONF_OVERRIDE}"
    export http_proxy="${GIT_PROXY}" https_proxy="${GIT_PROXY}" no_proxy="${CI_NO_PROXY}"
    trap 'rm -f "${CI_CONF_OVERRIDE}"' EXIT
fi

# 4b. Prefetch helper for openRuyi's cmake-without-https gap: fetch superbuild
#     URL-download tarballs (boost, xsimd) on the host so cmake skips the download.
#     Returns 0 if it placed a new tarball (retry worth it), 1 if nothing left.
#     TODO: drop once openRuyi's cmake https backend ships.
prefetch_cmake_url_downloads() {
    local prefetched=1 f url dst sha host_dst
    while IFS= read -r f; do
        url="$(grep -oE 'https?://[^][:space:]"]+\.(tar\.(gz|bz2|xz)|tgz|zip)' "$f" | head -1)"
        dst="$(grep -oE "/ceph/[^'\"]+\.(tar\.(gz|bz2|xz)|tgz|zip)" "$f" | head -1)"
        sha="$(grep -oiE '[a-f0-9]{64}' "$f" | head -1)"
        [ -n "$url" ] && [ -n "$dst" ] || continue          # skip git-clone ExternalProjects
        host_dst="${CEPH_SRC}${dst#/ceph}"                   # /ceph/build/.. -> ${CEPH_SRC}/build/..
        if [ -s "$host_dst" ] && [ -n "$sha" ] && \
           echo "${sha}  ${host_dst}" | sha256sum -c --status 2>/dev/null; then
            continue                                         # already in place, hash ok
        fi
        echo "  prefetch: ${url}"
        mkdir -p "$(dirname "$host_dst")"
        curl -fSL ${GIT_PROXY:+-x "$GIT_PROXY"} --retry 3 --connect-timeout 20 \
             -o "$host_dst" "$url" || { echo "    download failed"; continue; }
        if [ -n "$sha" ] && ! echo "${sha}  ${host_dst}" | sha256sum -c --status; then
            echo "    sha256 mismatch, discarding"; rm -f "$host_dst"; continue
        fi
        prefetched=0
    done < <(find "${CEPH_SRC}/build" -name 'download-*.cmake' 2>/dev/null)
    return $prefetched
}

# 4c. run build + ctest via bwc. Env goes in via `--extra=` (the '=' form is required;
#     bwc's argparse rejects `-x -eFOO`).
declare -a EXEC=()
IFS=',' read -ra _steps <<< "${STEPS}"
for s in "${_steps[@]}"; do EXEC+=(-e "$s"); done

declare -a NET_ARGS=()
if [ -n "${GIT_PROXY}" ]; then
    NET_ARGS=(
        --extra="--network=host"         # run container uses host net (to reach GIT_PROXY)
        --extra="--http-proxy=false"      # but do NOT inherit host *_proxy (would hit cmake)
        --extra="-eGIT_CONFIG_COUNT=2"    # in-container git: github via proxy + trust bind-mount
        --extra="-eGIT_CONFIG_KEY_0=http.https://github.com/.proxy"
        --extra="-eGIT_CONFIG_VALUE_0=${GIT_PROXY}"
        --extra="-eGIT_CONFIG_KEY_1=safe.directory"
        --extra="-eGIT_CONFIG_VALUE_1=*"
        --extra="-eGOPROXY=https://goproxy.cn,direct"   # openRuyi go defaults to GOPROXY=""
    )
fi

declare -a SYSTEM_SITE_ARG=()
[ -n "${CEPH_PYTHON_SYSTEM_SITE}" ] && \
    SYSTEM_SITE_ARG=(--extra="-eCEPH_PYTHON_SYSTEM_SITE=${CEPH_PYTHON_SYSTEM_SITE}")

cd "${CEPH_SRC}"
set +e
RC=0
# Retry loop: heal cmake-without-https failures by prefetching tarballs, then retry.
# Nothing left to prefetch = real failure. The cap is a backstop.
for attempt in 1 2 3 4 5; do
    # A failed configure leaves build/ without a generator file, and run-make.sh's
    # configure refuses to reuse an existing build/. Clear the half-configured dir
    # so this attempt gets a fresh configure instead of an instant bail-out.
    if [ -d "${CEPH_SRC}/build" ] && [ ! -e "${CEPH_SRC}/build/build.ninja" ] && [ ! -e "${CEPH_SRC}/build/Makefile" ]; then
        echo "=== removing half-configured build/ (no generator file) ==="
        rm -rf "${CEPH_SRC}/build"
    fi
    python3 src/script/build-with-container.py \
        --distro openruyi \
        --container-engine "${ENGINE}" \
        "${NET_ARGS[@]}" \
        --extra="-eCHECK_MAKEOPTS=${CHECK_MAKEOPTS}" \
        --extra="-eCONFIGURE_ARGS=${CONFIGURE_ARGS}" \
        "${SYSTEM_SITE_ARG[@]}" \
        "${EXEC[@]}"
    RC=$?
    [ "$RC" -eq 0 ] && break
    echo "=== bwc rc=${RC} (attempt ${attempt}); checking for missing cmake URL-downloads ==="
    if prefetch_cmake_url_downloads; then
        echo "=== prefetched missing tarball(s); retrying ==="
        continue
    fi
    echo "=== nothing left to prefetch; treating rc=${RC} as a real failure ==="
    break
done
set -e

# 5. surface where ctest results landed (collected as artifacts by the workflow)
echo "=== ctest output dir (build/Testing) ==="
ls -d "${CEPH_SRC}"/build/Testing/* 2>/dev/null || echo "  (no build/Testing yet)"

echo "=== ceph-ci L2 run done: rc=${RC} ceph=${CEPH_SHA} ==="
exit ${RC}
