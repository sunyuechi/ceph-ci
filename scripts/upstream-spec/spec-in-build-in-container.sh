#!/usr/bin/env bash
#
# Runs INSIDE the openRuyi container (invoked by run-spec-in-build.sh). Validates
# the UPSTREAM ceph.spec.in -- vanilla, no fork patches, no openruyi/ downstream
# spec. The spec.in is a template (only Source0, which is a make-dist tarball; no
# URL sources, no patches), so the official upstream `make-dist` is what turns it
# into a buildable ceph.spec + ceph-<ver>.tar.bz2. That is the ONLY faithful
# "upstream as-is" way to get a buildable spec -- we do not hand-roll the tarball.
#
# Two phases, selected by PHASE (same split as the openRuyi spec path):
#
#   PHASE=deps  (committed into the cached deps image by run-spec-in-build.sh):
#               install everything that does NOT change per build -- rpm tooling,
#               make-dist's own tools (git/wget/bzip2/python3), the OBS-base gcc-c++,
#               the sccache binary, the temp OBS repo, and `dnf builddep` of the
#               spec's BuildRequires -- then write the installed package hash to
#               /deps-meta so the host can decide whether to commit. builddep needs a
#               parseable spec, but the real spec only exists after make-dist; the
#               BuildRequires are version-independent, so a throwaway spec from a cheap
#               sed of ceph.spec.in (placeholder version) is enough here.
#
#   PHASE=build (default; runs from the deps image so the above is present):
#     1. run upstream make-dist in the bind-mounted ceph checkout -> ceph.spec +
#        ceph-<ver>.tar.bz2 (dashboard frontend npm step skipped by default; the
#        spec's %build sets WITH_MGR_DASHBOARD_FRONTEND=OFF so its output is unused)
#     2. stage the generated spec into ~/rpmbuild/SPECS, the tarball into SOURCES
#     3. validate the spec. The spec's %install ends with `rm -rf %{_vpath_builddir}`
#        (deletes the cmake tree), so a plain `rpmbuild -bb` would leave nothing for
#        ctest. Without editing the spec we use rpm short-circuit instead:
#          ctest mode (default): -bc (%prep+%build, tree kept) -> our build-check ctest on the
#            tree -> -bi --short-circuit (%install) -> -bl (%files vs BUILDROOT).
#          SKIP_CTEST=1: a full -bb (real rpms + %install/%files), tree deletion moot.
#
# Env in (set by run-spec-in-build.sh): PHASE, NPROC, CHECK_MAKEOPTS, TEMP_OBS_REPO,
#   RESUME, FILES_ONLY, SKIP_CTEST, MAKE_DIST_FULL (incremental knobs; see the host
#   header). The ceph checkout is bind-mounted rw at /ceph (make-dist writes into it).
set -euo pipefail

CEPH_SRC=/ceph                 # bind-mounted clean upstream checkout (rw: make-dist writes here)
RB="${HOME}/rpmbuild"          # SOURCES + RPMS + BUILD are bind-mounted for persistence
OUT=/out                       # bind-mounted artifacts dir
STATE=/state                   # bind-mounted: persists the generated spec for RESUME
PHASE="${PHASE:-build}"

SCCACHE_VERSION="${SCCACHE_VERSION:-v0.15.0}"
SCCACHE_REPO="${SCCACHE_REPO:-https://github.com/mozilla/sccache}"

# Cheap throwaway spec straight from ceph.spec.in, used ONLY by the deps phase so
# `dnf builddep` / the parse have a spec before make-dist exists. BuildRequires do not
# depend on the version, so the placeholder substitutions are irrelevant to deps.
stage_throwaway_spec() {
    rpmdev-setuptree
    sed -e 's/@PROJECT_VERSION@/0/g' \
        -e 's/@RPM_RELEASE@/0/g' \
        -e 's/@TARBALL_BASENAME@/ceph-0/g' \
        "${CEPH_SRC}/ceph.spec.in" > "${RB}/SPECS/ceph.spec"
}

# Fetch the pinned mozilla/sccache release binary into /usr/local/bin, the SAME way
# upstream ceph/Dockerfile.build does -- NOT `dnf install sccache` (openRuyi may not
# package it, and a distro build could be a different version, churning the cache).
# riscv64 -> the riscv64gc musl asset. Download goes through the inherited *_proxy.
install_sccache() {
    command -v sccache >/dev/null 2>&1 && return 0
    local sa surl
    sa="$(uname -m)"; [ "${sa}" = riscv64 ] && sa=riscv64gc
    surl="${SCCACHE_REPO}/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-${sa}-unknown-linux-musl.tar.gz"
    echo "  fetching ${surl}"
    if curl -sS -L "${surl}" | tar --no-anchored --strip-components=1 -C /usr/local/bin/ -xzf - sccache; then
        chmod +x /usr/local/bin/sccache
    else
        echo "  WARN: sccache download failed; deps image will build without cache"
    fi
}

# ============================================================================
# PHASE=deps: install the cacheable build environment. run-spec-in-build.sh commits
# the resulting container to the deps image; PHASE=build then reuses it as-is.
# ============================================================================
if [ "${PHASE}" = deps ]; then
    echo "=== deps phase: install rpm tooling + make-dist tools ==="
    # dnf5-plugins -> `dnf builddep` (openRuyi is dnf5). rpmdevtools -> rpmdev-setuptree.
    # cmake-rpm-macros + python-rpm-macros must be present BEFORE anything parses the
    # spec (builddep parses it). git/wget/bzip2/python3/findutils are make-dist's own
    # tools (git-archive-all + boost/liburing/pmdk downloads + the rook client gen).
    dnf install -y rpm-build rpmdevtools dnf5-plugins cmake-rpm-macros python-rpm-macros \
        curl tar git wget bzip2 python3 findutils

    # OBS default build base: OBS preinstalls gcc-c++ in every chroot, so the ceph spec
    # does not BuildRequire it -- install it to match (builddep gives gcc/make, not g++).
    echo "=== deps phase: install OBS-base compiler (gcc-c++) ==="
    dnf install -y gcc gcc-c++ make

    echo "=== deps phase: install sccache binary ==="
    install_sccache

    # Prefer the temporary OBS project home:sunyuechi:openruyi-test (priority=1) for any
    # package it publishes -- same toggle/mechanism as the build-check and openRuyi-spec paths.
    # gpgcheck=0: OBS RPMs are unsigned. skip_if_unavailable=1: an unreachable project
    # must not break CI. TEMP_OBS_REPO=0 disables it (stock openRuyi repos only).
    if [ "${TEMP_OBS_REPO:-1}" = 1 ]; then
        echo "=== deps phase: enable temp OBS repo home:sunyuechi:openruyi-test (priority=1) ==="
        cat > /etc/yum.repos.d/home_sunyuechi_openruyi-test.repo <<'REPO'
[home_sunyuechi_openruyi-test]
name=home:sunyuechi:openruyi-test (riscv64)
baseurl=https://repo.build.openruyi.cn/home:/sunyuechi:/openruyi-test/riscv64/
enabled=1
gpgcheck=0
priority=1
skip_if_unavailable=1
REPO
        # The %openruyi macro that drives ceph.spec.in's openRuyi BuildRequires branch
        # ships ONLY in the temp project's openruyi-release (2-10.x); the rva23 base image
        # carries the stock 2-5.2, which lacks it. builddep never upgrades an already-installed
        # package, so force the upgrade here -- without %openruyi the spec takes the Fedora
        # branch (libcurl-devel, python3-Cython, ...) and builddep dies on "No match".
        # (rva20/sg2042 runs TEMP_OBS_REPO=0 but its base image seeds macros.openruyi directly
        # via publish-openruyi-image.sh, so it does not need this.)
        echo "=== deps phase: upgrade openruyi-release from temp repo (pull in %openruyi macro) ==="
        dnf upgrade -y openruyi-release
    else
        echo "=== deps phase: TEMP_OBS_REPO=0, stock openRuyi repos only ==="
    fi

    echo "=== deps phase: dnf builddep (BuildRequires incl. make_check test deps) ==="
    # --allowerasing: the rpm tooling pulls libudev-zero, but rdma BuildRequires need
    # systemd-udev (conflicts with libudev-zero); let dnf swap, converging on OBS's set.
    # --define '_with_make_check 1': pull the make_check test BuildRequires too.
    stage_throwaway_spec
    dnf builddep -y --allowerasing --define '_with_make_check 1' "${RB}/SPECS/ceph.spec"

    dnf clean all >/dev/null 2>&1 || true

    # Record the installed package set so the host can skip the commit on a no-op refresh.
    if [ -d /deps-meta ]; then
        rpm -qa | sort | sha256sum | cut -d' ' -f1 > /deps-meta/pkghash
    fi
    echo "=== deps phase done: build environment ready (host decides whether to commit) ==="
    exit 0
fi

# ============================================================================
# PHASE=build: tooling, gcc-c++, sccache, the builddep'd BuildRequires are present
# from the deps image. Do NO dnf install here -- run make-dist, then rpmbuild.
# ============================================================================
rpmdev-setuptree

# ----------------------------------------------------------------------------
# 1. make-dist: turn ceph.spec.in -> ceph.spec + ceph-<ver>.tar.bz2 (Source0).
#    Skipped on RESUME / FILES_ONLY, which reuse a prior run's spec + tarball.
# ----------------------------------------------------------------------------
run_make_dist() {
    echo "=== build phase: make-dist (generate spec + Source0 tarball) ==="
    local script=./make-dist
    if [ "${MAKE_DIST_FULL:-0}" != 1 ]; then
        # Default: drop make-dist's dashboard-frontend npm build (npm ci + node 22 +
        # build:localize, the heaviest/flakiest step on riscv64). The spec's %build sets
        # -DWITH_MGR_DASHBOARD_FRONTEND:BOOL=OFF, so dashboard_frontend.tar is never used
        # by rpmbuild -> zero effect on %build/%install/%files. We do NOT touch the repo's
        # make-dist; we run a sed'd copy that also removes dashboard_frontend from the
        # final tar --concatenate list (else it fails on the missing tarball).
        echo "  (skipping dashboard frontend npm build; set MAKE_DIST_FULL=1 for vanilla make-dist)"
        script=/tmp/make-dist.run
        sed -e '/^build_dashboard_frontend$/d' \
            -e '/^[[:space:]]*dashboard_frontend[[:space:]]*\\$/d' \
            "${CEPH_SRC}/make-dist" > "${script}"
    else
        echo "  (MAKE_DIST_FULL=1: running vanilla upstream make-dist, dashboard frontend included)"
    fi
    # Pin the dist version to the release base -- strip git describe's "-N-gSHA" suffix
    # (21.3.0-504-g393edd99f14 -> 21.3.0). make-dist names the tarball + source dir
    # "ceph-<version>", and that source-dir name is the ONLY version-varying part of the
    # rpmbuild build path (%_builddir "ceph-21.3.0-build" and %_vpath_builddir
    # "riscv64-openruyi-linux" are stable). It lands in every -I/-isystem absolute path, so
    # with the full describe it changes every run (main advances + our patch commit bumps the
    # commit count) and sccache -- which hashes the preprocessed output incl. its `# line`
    # path markers -- misses ~100% run-to-run. Pinning the base makes the path identical
    # across runs so sccache actually hits. The RPM Version is static in ceph.spec.in
    # (packaging unaffected) and .git_version still records the exact HEAD sha. Override via
    # MAKE_DIST_VERSION (e.g. to reproduce a real downstream NEVR).
    local dist_ver="${MAKE_DIST_VERSION:-}"
    if [ -z "${dist_ver}" ]; then
        dist_ver="$(cd "${CEPH_SRC}" && git describe --long --match 'v*' 2>/dev/null \
            | sed 's/^v//; s/-g[0-9a-f]\+$//; s/-[0-9]\+$//')"
    fi
    [ -n "${dist_ver}" ] || { echo "ERROR: could not derive a dist version (git describe failed); set MAKE_DIST_VERSION" >&2; exit 1; }
    echo "  pinning dist version -> ${dist_ver} (stable build path so sccache hits; override via MAKE_DIST_VERSION)"
    # make-dist must run from the checkout root (it uses paths relative to CWD and needs
    # .git there); $0 living elsewhere is fine (only error messages use it).
    ( cd "${CEPH_SRC}" && bash "${script}" "${dist_ver}" )

    local tarball
    tarball="$(ls -t "${CEPH_SRC}"/ceph-*.tar.bz2 2>/dev/null | head -1)"
    [ -n "${tarball}" ] && [ -f "${tarball}" ] || {
        echo "ERROR: make-dist produced no ceph-*.tar.bz2 in ${CEPH_SRC}" >&2; exit 1; }
    [ -f "${CEPH_SRC}/ceph.spec" ] || {
        echo "ERROR: make-dist produced no ceph.spec in ${CEPH_SRC}" >&2; exit 1; }
    echo "  tarball: $(basename "${tarball}")  spec: ceph.spec"

    cp -f "${tarball}" "${RB}/SOURCES/"
    cp -f "${CEPH_SRC}/ceph.spec" "${RB}/SPECS/ceph.spec"
    # Persist the generated spec so RESUME (which skips make-dist) can restage it.
    [ -d "${STATE}" ] && cp -f "${CEPH_SRC}/ceph.spec" "${STATE}/ceph.spec"

    # Keep the host checkout tidy: drop make-dist's in-tree output (the host also git-cleans).
    rm -f "${tarball}" "${CEPH_SRC}/ceph.spec" 2>/dev/null || true
    rm -f "${CEPH_SRC}"/ceph-*[0-9] 2>/dev/null || true   # the `ln -s . ceph-<ver>` symlink
}

restage_persisted_spec() {
    # RESUME / FILES_ONLY: reuse the spec + tarball a prior full run left behind.
    if [ -f "${STATE}/ceph.spec" ]; then
        cp -f "${STATE}/ceph.spec" "${RB}/SPECS/ceph.spec"
    elif [ -f "${RB}/SPECS/ceph.spec" ]; then
        :   # already staged in a persisted SPECS (not our default), accept it
    else
        echo "ERROR: RESUME/FILES_ONLY but no persisted spec at ${STATE}/ceph.spec;" >&2
        echo "       run a full build (RESUME/FILES_ONLY unset) first." >&2
        exit 1
    fi
    ls "${RB}"/SOURCES/ceph-*.tar.bz2 >/dev/null 2>&1 || {
        echo "ERROR: RESUME/FILES_ONLY but no Source tarball in ${RB}/SOURCES;" >&2
        echo "       run a full build first." >&2; exit 1; }
}

SPEC="${RB}/SPECS/ceph.spec"
SMP_DEF=(--define "_smp_build_ncpus ${NPROC:-$(nproc)}")
# Disable LTO, mirroring the openRuyi downstream ceph.spec (which sets
# `%define _lto_cflags %{nil}`). openRuyi's RPM default optflags carry -flto=auto
# -ffat-lto-objects; with LTO on, linking the full make_check test suite dies on
# ceph_test_keyvaluedb_atomicity -- ld can't resolve the LTO-deferred symbols pulled
# from static-archive members (librocksdb.a env_mirror.cc.o, libextblkdev.a) and reports
# a flood of undefined references in .text/.debug_info. Upstream ceph.spec.in carries no
# LTO override, so override it here at rpmbuild time rather than patching the spec.
LTO_DEF=(--define "_lto_cflags %{nil}")

# FILES_ONLY: re-check %files against the BUILDROOT a prior run left under the persisted
# BUILD/ tree -- rpmbuild -bl parses %files and stat()s every listed path, no compile/
# install. The right tool for a %files mismatch (renamed/moved file). No make-dist, no
# Source needed beyond a parseable spec.
if [ "${FILES_ONLY:-0}" = 1 ]; then
    echo "=== build phase: FILES_ONLY -- rpmbuild -bl (%files vs persisted BUILDROOT) ==="
    restage_persisted_spec
    rpmbuild -bl --with make_check "${SMP_DEF[@]}" "${SPEC}"
    echo "=== build phase: FILES_ONLY done (rc=0) ==="
    exit 0
fi

if [ "${RESUME:-0}" = 1 ]; then
    echo "=== build phase: RESUME -- reuse persisted spec/tarball + BUILD/ tree ==="
    restage_persisted_spec
else
    run_make_dist
fi

# sccache: baked into the deps image. The spec's %build doesn't wire a launcher, so
# inject it via the CMAKE_<LANG>_COMPILER_LAUNCHER env CMake reads at configure time
# (Makefiles generator honors it too). Content-addressed -> hits despite a fresh BUILD/.
USE_SCCACHE=0
if command -v sccache >/dev/null 2>&1; then
    USE_SCCACHE=1
    export CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache
    sccache --start-server 2>/dev/null || true
    sccache --zero-stats >/dev/null 2>&1 || true
    echo "  sccache: ${SCCACHE_DIR:-?} (max ${SCCACHE_CACHE_SIZE:-?})"
else
    echo "  sccache not in image; building without cache"
fi

# ----------------------------------------------------------------------------
# SKIP_CTEST: full faithful packaging. -bb runs %prep/%build/%install/%files and
# emits real rpms; the spec's `rm -rf %{_vpath_builddir}` in %install is harmless
# because we are not running ctest afterwards. --noprep on RESUME reuses the tree.
# ----------------------------------------------------------------------------
if [ "${SKIP_CTEST:-0}" = 1 ]; then
    PREP_OPT=""; [ "${RESUME:-0}" = 1 ] && PREP_OPT="--noprep"
    echo "=== build phase: rpmbuild -bb ${PREP_OPT} --with make_check (full packaging, no ctest) ==="
    rpmbuild -bb ${PREP_OPT} --with make_check "${SMP_DEF[@]}" "${LTO_DEF[@]}" "${SPEC}"
    [ "${USE_SCCACHE}" = 1 ] && { echo "=== sccache stats ==="; sccache --show-stats 2>/dev/null || true; }
    echo "=== build phase: SKIP_CTEST -- packaging validated, rpms in RPMS/ (rc=0) ==="
    exit 0
fi

# ----------------------------------------------------------------------------
# ctest mode (default). The spec deletes the build tree in %install, so we cannot
# -bb then ctest. Instead, WITHOUT editing the spec, split via rpm short-circuit:
#   -bc            : %prep + %build, build tree kept (RESUME -> --short-circuit, skip prep)
#   <our ctest>    : on the kept tree (build-check tuning)
#   -bi --short-circuit : %install on the kept tree (validates %install; runs the spec's
#                         own `rm -rf vpath` at its end -- fine, ctest already ran)
#   -bl            : %files check against the BUILDROOT -bi populated
# (Final .rpm assembly is not run in this mode; use SKIP_CTEST=1 for real rpms.)
# ----------------------------------------------------------------------------
BC_OPT=""; [ "${RESUME:-0}" = 1 ] && BC_OPT="--short-circuit"
echo "=== build phase: rpmbuild -bc ${BC_OPT} --with make_check (%prep+%build, keep tree) ==="
rpmbuild -bc ${BC_OPT} --with make_check "${SMP_DEF[@]}" "${LTO_DEF[@]}" "${SPEC}"

echo "=== build phase: locate the spec's cmake build tree ==="
# %build builds in %{_vpath_builddir} (= %{_target_platform}, e.g. riscv64-openruyi-linux)
# under the extracted source dir. rpm 4.20 may nest under BUILD/ceph-<ver>-build/; find
# CMakeCache.txt to stay layout-agnostic.
BUILDDIR="$(dirname "$(find "${RB}/BUILD" -maxdepth 5 -name CMakeCache.txt 2>/dev/null | head -1)")"
[ -n "${BUILDDIR}" ] && [ -d "${BUILDDIR}" ] || {
    echo "ERROR: cannot find the cmake build tree under ${RB}/BUILD" >&2
    find "${RB}/BUILD" -maxdepth 5 -name CMakeCache.txt 2>/dev/null >&2 || true
    exit 1
}
echo "  build tree: ${BUILDDIR}"

echo "=== build phase: build the ctest 'tests' aggregate ==="
# Match build-check's per-test ctest timeout: add_ceph_test stamps each test with a TIMEOUT
# property (= CEPH_TEST_TIMEOUT, default 7200s) that OVERRIDES ctest --timeout.
# Reconfigure the built tree to 18000 for slow riscv64; only this cache var changes.
cmake -DCEPH_TEST_TIMEOUT=18000 "${BUILDDIR}" >/dev/null
# Most ceph unit tests are EXCLUDE_FROM_ALL (built by the 'tests' target, not `all`),
# so build it ourselves before ctest -- the same step the spec's %check would do.
cmake --build "${BUILDDIR}" --target tests -j"${NPROC:-$(nproc)}"

[ "${USE_SCCACHE}" = 1 ] && { echo "=== sccache stats ==="; sccache --show-stats 2>/dev/null || true; }

echo "=== build phase: run ctest (build-check tuning: ${CHECK_MAKEOPTS:-<none>}) ==="
# We bypass the spec's %check, so its CEPH_PYTHON_SYSTEM_SITE export never runs; set it
# here so test venvs use --system-site-packages and reuse the image's cryptography.
export CEPH_PYTHON_SYSTEM_SITE=true
# standalone tests put the BlueStore block file under build/td; on this host's NVMe ext4
# the O_DIRECT/libaio path intermittently stalls -> map td to tmpfs (bind-mounted), same
# as run-build-check.sh.
rm -rf "${BUILDDIR}/td"; ln -sfn /td-tmpfs "${BUILDDIR}/td"
set +e
( cd "${BUILDDIR}" && ctest ${CHECK_MAKEOPTS:-} )
RC=$?
set -e

echo "=== build phase: collect artifacts to ${OUT} ==="
cp -r "${BUILDDIR}/Testing" "${OUT}/" 2>/dev/null || true
cp "${BUILDDIR}/CMakeCache.txt" "${OUT}/" 2>/dev/null || true

# Validate %install + %files now that ctest is done -- short-circuit off the same %build.
echo "=== build phase: rpmbuild -bi --short-circuit --with make_check (validate %install) ==="
rpmbuild -bi --short-circuit --with make_check "${SMP_DEF[@]}" "${SPEC}"
echo "=== build phase: rpmbuild -bl --with make_check (validate %files vs BUILDROOT) ==="
rpmbuild -bl --with make_check "${SMP_DEF[@]}" "${SPEC}"

echo "=== spec.in validation done: rc=${RC} (ctest result; %build/%install/%files all passed) ==="
exit ${RC}
