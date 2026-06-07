#!/usr/bin/env bash
#
# Runs INSIDE the openRuyi container (invoked by run-spec-build.sh). Reproduces
# what an OBS worker does for the ceph package, minus the OBS scheduling layer.
# Two phases, selected by PHASE:
#
#   PHASE=deps  (committed into the cached deps image by run-spec-build.sh): install
#               everything that does NOT change per build -- rpm tooling, the OBS-base
#               gcc-c++, the sccache binary, the temp OBS repo, and `dnf builddep` of the
#               spec's BuildRequires -- then write the installed package hash to /deps-meta
#               so the host can decide whether to commit. This is the slow, network-heavy
#               half; baking it into an image is what lets the build half below skip it on
#               every subsequent run (the container is --rm, so a fresh base image would
#               otherwise reinstall all of this every time). The host runs this FROM the
#               base image (full install) or FROM the existing deps image (REBUILD_DEPS
#               refresh: dnf just upgrades already-installed pkgs to pick up rolling
#               updates); the same dnf commands cover both since `dnf install`/`builddep`
#               upgrade to latest, and commit happens only if the package hash changed.
#
#   PHASE=build (default; runs from the deps image so the above is already present):
#     1. stage openruyi/ (spec + patches) into ~/rpmbuild
#     2. rpmdev-spectool -g the Source0..33 tarballs (cached across runs via the bind mount)
#     3. rpmbuild -bb --nocheck --with make_check  (spec drives %prep/%build/%install)
#     4. then run *our* ctest (known-failures excludes + tmpfs td) on the spec's own
#        build tree -- the spec's %check is a bare ctest, we want the build-check tuning.
#
# So the spec itself does all of %prep (submodule tarballs, isa-l v2.32.0 swap,
# %autopatch) -- no hand-rolled reproduction. The build is the spec's real
# downstream config (WITH_CRIMSON=OFF, RelWithDebInfo, no ASan), which is the point.
#
# Env in (set by run-spec-build.sh): PHASE, NPROC, CHECK_MAKEOPTS, TEMP_OBS_REPO,
#   RESUME, FILES_ONLY, SKIP_CTEST (incremental knobs; see run-spec-build.sh header).
set -euo pipefail

SPEC_DIR=/spec                 # bind-mounted openruyi/ (ro)
RB="${HOME}/rpmbuild"          # SOURCES + RPMS are bind-mounted for persistence
OUT=/out                       # bind-mounted artifacts dir
PHASE="${PHASE:-build}"

SCCACHE_VERSION="${SCCACHE_VERSION:-v0.15.0}"
SCCACHE_REPO="${SCCACHE_REPO:-https://github.com/mozilla/sccache}"

# Stage the spec into ~/rpmbuild/SPECS with Release pinned. Release: %autorelease is
# resolved by an OBS service before the chroot ever sees the spec (OBS rewrites it to a
# concrete N%{?dist}); off-OBS there is no such service, so pin it to 0 here. Only the
# Release line changes -- %prep/%build/%check and the patch set are untouched -- so this
# does not affect what we validate. Both phases need a parseable spec: builddep parses
# it for BuildRequires, rpmbuild builds from it.
stage_spec() {
    rpmdev-setuptree
    sed 's/^Release:.*%autorelease.*/Release:        0/' \
        "${SPEC_DIR}/ceph.spec" > "${RB}/SPECS/ceph.spec"
}

# Fetch the pinned mozilla/sccache release binary into /usr/local/bin, the SAME way
# upstream ceph/Dockerfile.build does -- NOT `dnf install sccache`: openRuyi may not
# package it (whole cache lost), and a distro build could be a different version than
# the build-check path uses (which comes from this same Dockerfile), churning a shared-by-content
# cache. riscv64 -> the riscv64gc musl asset. Download goes through the *_proxy this
# container inherited. Optional: degrade to an uncached build if the fetch fails.
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
# PHASE=deps: install the cacheable build environment. run-spec-build.sh commits
# the resulting container to the deps image; PHASE=build then reuses it as-is.
# ============================================================================
if [ "${PHASE}" = deps ]; then
    echo "=== deps phase: install rpm tooling ==="
    # dnf5-plugins provides `dnf builddep` -- openRuyi is dnf5, where the dnf4
    # 'dnf-command(builddep)' virtual provide / dnf-plugins-core do not exist (verified
    # in the image). rpmdevtools gives rpmdev-spectool + rpmdev-setuptree (the bare
    # `spectool` name is gone on this rpmdevtools).
    #
    # cmake-rpm-macros + python-rpm-macros must be in BEFORE anything parses the spec:
    # rpmdev-spectool AND dnf builddep both parse it, and the spec fails to parse
    # without these macros -- cmake-rpm-macros for its `BuildSystem: cmake` line
    # ("Unknown buildsystem: cmake"), python-rpm-macros for `%python_provide`
    # ("Unknown tag"). builddep can't supply them since it parses first. Verified the
    # full spec parses (rpmspec -P) with exactly this set; add the next macro pkg here
    # if a new parse-time macro shows up. patch/gawk/cmake/ninja come from BuildRequires.
    dnf install -y rpm-build rpmdevtools dnf5-plugins cmake-rpm-macros python-rpm-macros curl tar

    # OBS default build base. OBS preinstalls a compiler toolchain in every build chroot
    # (gcc-c++ is preinstall=1 there, confirmed via `osc buildinfo`), so the ceph spec
    # does NOT BuildRequire gcc/gcc-c++ -- it assumes the base env provides them. Our
    # from-scratch container only has what builddep pulls, which gives gcc/make but NOT
    # gcc-c++ (g++), so %cmake fails "Could not find compiler ... g++". Install it to
    # match OBS's base. gcc/make are already pulled by builddep; listed for clarity.
    echo "=== deps phase: install OBS-base compiler (gcc-c++) ==="
    dnf install -y gcc gcc-c++ make

    echo "=== deps phase: install sccache binary ==="
    install_sccache

    # Prefer the temporary OBS project home:sunyuechi:openruyi-test (priority=1 beats the
    # stock repos' default 99) for any package it publishes; everything else still comes
    # from the stock openRuyi repos. Same mechanism as the build-check path's fork patch 2005 --
    # needed here because the spec's `BuildRequires: promtool` is carried only by the temp
    # project's `prometheus` pkg (/usr/bin/promtool), not the stock repos. gpgcheck=0: OBS
    # RPMs are unsigned. skip_if_unavailable=1: an unpublished/unreachable project must not
    # break CI. (No openruyi-release upgrade unlike build-check: this spec uses no %openruyi macro
    # guard -- verified it parses without it.) TEMP_OBS_REPO=0 disables (stock only). This
    # repo file is committed into the deps image; PHASE=build does no dnf so never reads it.
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
    else
        echo "=== deps phase: TEMP_OBS_REPO=0, stock openRuyi repos only ==="
    fi

    echo "=== deps phase: dnf builddep (BuildRequires incl. make_check test deps) ==="
    # --allowerasing: the rpm tooling install above pulls libudev-zero as the libudev
    # provider, but the spec's rdma BuildRequires (rdma-core-devel -> rdma-core) need
    # udev = systemd-udev, which CONFLICTS with libudev-zero. OBS never hits this -- its
    # fresh chroot preinstalls systemd-udev and has no libudev-zero (confirmed via
    # `osc buildinfo`); our reuse of the runtime OCI image (which prefers libudev-zero)
    # is the only reason. --allowerasing lets dnf swap libudev-zero -> systemd-udev,
    # converging on OBS's set. Verified it resolves cleanly in the image.
    stage_spec
    dnf builddep -y --allowerasing --define '_with_make_check 1' "${RB}/SPECS/ceph.spec"

    # Drop the dnf metadata/package cache so it is not committed into the deps image.
    dnf clean all >/dev/null 2>&1 || true

    # Record the installed package set (sorted NEVRA hash) so the host can skip the
    # CPU-heavy layer commit when a REBUILD_DEPS refresh resolved to exactly the same
    # packages as the cached image. /deps-meta is a small rw bind mount for this.
    if [ -d /deps-meta ]; then
        rpm -qa | sort | sha256sum | cut -d' ' -f1 > /deps-meta/pkghash
    fi
    echo "=== deps phase done: build environment ready (host decides whether to commit) ==="
    exit 0
fi

# ============================================================================
# PHASE=build: tooling, gcc-c++, sccache, and the builddep'd BuildRequires are all
# already present from the deps image. Do NO dnf install here -- just stage and build.
# ============================================================================
echo "=== build phase: stage spec into ${RB} ==="
stage_spec

# FILES_ONLY: re-check %files against the BUILDROOT a prior full run left under the
# persisted BUILD/ tree -- rpmbuild -bl parses %files and stat()s every listed path, no
# %prep/compile/install/package. The right tool for a %files mismatch on a version bump:
# %install already succeeded last run (the "File not found" fires in the packaging stage,
# AFTER install), so the BUILDROOT is complete and only the file list is stale. -bl needs
# only the staged spec -- no Source tarballs, no sccache -- so exit before fetching them.
if [ "${FILES_ONLY:-0}" = 1 ]; then
    echo "=== build phase: FILES_ONLY -- rpmbuild -bl (%files check vs persisted BUILDROOT) ==="
    rpmbuild -bl --nocheck --with make_check \
        --define "_smp_build_ncpus ${NPROC:-$(nproc)}" \
        "${RB}/SPECS/ceph.spec"
    echo "=== build phase: FILES_ONLY done (rc=0) ==="
    exit 0
fi

echo "=== build phase: stage patches + fetch Source tarballs ==="
# patchlist patches + the isa-l aliasing patch (Source2) are local files (no URL);
# copy them so %prep finds them. rpmdev-spectool below fetches only the URL Sources.
cp -f "${SPEC_DIR}"/*.patch "${RB}/SOURCES/"
# rpmdev-spectool draws a progressbar2 download bar and has no quiet flag; it does
# not check isatty, so over our non-tty logging pipe every refresh becomes a full
# line and floods run.log. Capture its output and only surface it on failure -- the
# sources are bind-mount cached across runs, so this is normally quick, and the mem
# sampler keeps stamping the log meanwhile.
_spectool_log=/tmp/spectool.log
if rpmdev-spectool -g -C "${RB}/SOURCES" "${RB}/SPECS/ceph.spec" >"${_spectool_log}" 2>&1; then
    echo "  sources ready in ${RB}/SOURCES"
else
    echo "ERROR: rpmdev-spectool failed; output follows:" >&2
    cat "${_spectool_log}" >&2
    exit 1
fi

# sccache: the binary is baked into the deps image. The spec's %cmake doesn't wire a
# compiler launcher (that's run-make.sh's job on the build-check path, which rpmbuild bypasses),
# so inject it via the CMAKE_<LANG>_COMPILER_LAUNCHER env vars CMake reads at configure
# time. Content-addressed, so it hits across rpmbuild's fresh-BUILD/-every-run.
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

# RESUME: reuse the persisted BUILD/ tree -- rpmbuild --noprep skips %prep (no tarball
# re-extract, no isa-l swap, no %autopatch), %build is then a ninja incremental (a no-op
# when sources are untouched; sccache covers any recompiles), and %install + packaging
# re-run so %files is re-validated. For spec-only / small source edits; run without
# RESUME after touching patches or Sources so %prep re-stages the tree.
PREP_OPT=""
if [ "${RESUME:-0}" = 1 ]; then
    echo "=== build phase: RESUME -- reuse persisted BUILD/ tree, skip %prep (--noprep) ==="
    PREP_OPT="--noprep"
fi

echo "=== build phase: rpmbuild -bb --nocheck --noclean ${PREP_OPT} --with make_check ==="
# --with make_check: install the %check BuildRequires + keep the tests wiring, so
#   our ctest below has its deps. --nocheck: skip the spec's own %check stage (we
#   run ctest ourselves with the build-check tuning). -bb: build + %install + package, so
#   %files/packaging is validated too.
# --noclean is REQUIRED: rpm 4.20's declarative BuildSystem runs an Executing(rmbuild)
#   step on a successful -bb that `rm -rf`s BUILD/<name>-<ver>-build -- which is the
#   very cmake build tree our ctest below needs. --noclean suppresses that removal so
#   the tree survives (verified: with it BUILD/ stays, without it the tree is gone).
# _smp_build_ncpus caps the %cmake_build / BOOST_J parallelism at NPROC (rpm
# otherwise uses all cores -> OOM risk on this box, same reason as build-check's NPROC).
# --undefine _smp_ncpus_max would uncap; we cap instead. Env launcher reaches the
# %build cmake via the inherited environment.
rpmbuild -bb --nocheck --noclean ${PREP_OPT} --with make_check \
    --define "_smp_build_ncpus ${NPROC:-$(nproc)}" \
    "${RB}/SPECS/ceph.spec"

# SKIP_CTEST: packaging is what we wanted to validate (e.g. a %files fix); the rpms are
# already on the host via the bind-mounted RPMS/. Stop before the build-check ctest, which is
# unrelated to a packaging change and is the slow half.
if [ "${SKIP_CTEST:-0}" = 1 ]; then
    [ "${USE_SCCACHE}" = 1 ] && { echo "=== sccache stats ==="; sccache --show-stats 2>/dev/null || true; }
    echo "=== build phase: SKIP_CTEST -- packaging validated, skipping ctest (rc=0) ==="
    exit 0
fi

echo "=== build phase: locate the spec's cmake build tree ==="
# rpm 4.20 BuildSystem layout: BUILD/<name>-<ver>-build/<name>-<ver>/<vpath>,
# vpath is the %cmake out-of-source dir (riscv64-openruyi-linux on riscv64).
BUILDDIR="$(ls -d "${RB}"/BUILD/ceph-*-build/ceph-*/*-openruyi-linux 2>/dev/null | head -1)"
[ -n "${BUILDDIR}" ] && [ -d "${BUILDDIR}" ] || {
    echo "ERROR: cannot find the cmake build tree under ${RB}/BUILD" >&2
    find "${RB}/BUILD" -maxdepth 3 -name 'CMakeCache.txt' 2>/dev/null >&2 || true
    exit 1
}
echo "  build tree: ${BUILDDIR}"

echo "=== build phase: build the ctest 'tests' aggregate (EXCLUDE_FROM_ALL) ==="
# Match build-check's per-test ctest timeout: add_ceph_test stamps each test with a TIMEOUT
# property = the CEPH_TEST_TIMEOUT cache var (default 7200s) which OVERRIDES ctest's
# --timeout. The spec's %cmake leaves it at the default; reconfigure the already-
# built tree to 18000 (same value run-build-check.sh sets at configure) for slow
# riscv64. rpmbuild already packaged the rpm, so this affects only our ctest, not
# the spec output. cmake reads the rest from CMakeCache.txt -- only this var changes.
# Use the cmake rpm's %cmake uses (/usr/bin/cmake). A bare `cmake` resolves via PATH
# to /usr/sbin/cmake, flipping CMAKE_COMMAND in the reused cache vs rpmbuild's %cmake
# -> cmake regenerates build.ninja -> the Boost ExternalProject reconfigures + rebuilds
# from scratch (boost ends up built twice per run). Pin the path to avoid that.
/usr/bin/cmake -DCEPH_TEST_TIMEOUT=18000 "${BUILDDIR}" >/dev/null
# %check normally builds the tests aggregate; we skipped %check, so do it ourselves.
/usr/bin/cmake --build "${BUILDDIR}" --target tests -j"${NPROC:-$(nproc)}"

# sccache hit rate -> run.log (compile + the tests build above). Watch it across
# runs to confirm the cache is actually warming, same as the build-check path.
[ "${USE_SCCACHE}" = 1 ] && { echo "=== sccache stats ==="; sccache --show-stats 2>/dev/null || true; }

echo "=== build phase: run ctest (build-check tuning: ${CHECK_MAKEOPTS:-<none>}) ==="
# We bypass the spec's %check, so its `export CEPH_PYTHON_SYSTEM_SITE=true` never
# runs. Set it here so test venvs use --system-site-packages and reuse the image's
# cryptography (no PyPI sdist -> no Rust toolchain needed).
export CEPH_PYTHON_SYSTEM_SITE=true
# standalone tests put their BlueStore block file under build/td; on this host's
# NVMe ext4 that O_DIRECT/libaio path intermittently stalls -> map td to tmpfs
# (bind-mounted /td-tmpfs) exactly as run-build-check.sh does.
rm -rf "${BUILDDIR}/td"; ln -sfn /td-tmpfs "${BUILDDIR}/td"
set +e
( cd "${BUILDDIR}" && ctest ${CHECK_MAKEOPTS:-} )
RC=$?
set -e

echo "=== build phase: collect artifacts to ${OUT} ==="
cp -r "${BUILDDIR}/Testing" "${OUT}/" 2>/dev/null || true
cp "${BUILDDIR}/CMakeCache.txt" "${OUT}/" 2>/dev/null || true
# built rpms are already on the host via the bind-mounted RPMS/.

echo "=== spec build done: rc=${RC} ==="
exit ${RC}
