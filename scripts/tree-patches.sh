# Fork patch list for run-build-check.sh (sourced, not executed); expects
# TEMP_OBS_REPO to be set by the caller. Patches apply in listed order.
# Comment a line out to skip it. Numbering: 1xxx = upstream-bound (comment
# links the PR), 2xxx = openRuyi downstream. An already-present patch is
# auto-skipped.
TREE_PATCHES=(
    # -- 1xxx: upstream-bound --
    # TODO: not submitted yet; planned ceph PR (openRuyi as a build target)
    1002-openruyi-build-tooling.patch
    # TODO: not submitted yet; same ceph PR as 1002 (ceph.spec.in openruyi support)
    1003-openruyi-spec.patch
	# https://github.com/ceph/ceph/pull/69448
    1004-pmdk-riscv64-use-daos-stack.patch
    # https://github.com/ceph/ceph/pull/69157
    1005-test-mds-quiesce-agent-await-idle.patch
	# https://github.com/ceph/ceph/pull/69449
    1006-cmake-protobuf-config-mode.patch
    # https://github.com/ceph/ceph/pull/69156
    1007-monitoring-jsonnet-bundler-v0.6.0.patch
	# https://github.com/ceph/ceph/pull/69316
    1008-tests-venv-system-site-packages.patch
    1009-mypy-skip-follow_imports-for-prettytable.patch
	# https://github.com/ceph/ceph/pull/69455
    1012-test-crimson-messenger-thrash-bump-memory.patch
    # ours -- print sccache --show-stats after build so CI sees the cache hit rate
    1016-run-make-print-sccache-stats.patch
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
