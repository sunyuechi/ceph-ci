# Fork patch list for run-build-check.sh (sourced, not executed); expects
# TEMP_OBS_REPO to be set by the caller. Patches apply in listed order.
# Comment a line out to skip it. Numbering: 1xxx = upstream-bound (comment
# links the PR), 2xxx = openRuyi downstream. An already-present patch is
# auto-skipped.
TREE_PATCHES=(
    # -- 1xxx: upstream-bound --
	# https://github.com/ceph/ceph/pull/69783
    1002-openruyi-build-tooling.patch
	# https://github.com/ceph/ceph/pull/69448
    1004-pmdk-riscv64-use-daos-stack.patch
	# https://github.com/ceph/ceph/pull/69519
	1024-pybind-rbd-rgw-place-nogil-after-the-exception-speci.patch

	# https://github.com/ceph/ceph/pull/69643
	1039-open_image-fix.patch
	1040-internal-api-test_Encryption.cc.patch
	1041-test_DiffIterate.cc.patch

	# todo
	1046-test-crimson-onode-shrink-synthetic-pool-under-ASan.patch
	1047-test-transaction_manager-shrink-working-set-under-AS.patch

	# todo
	1060-osd-fix-misspelled-inject-ec-clear-command-names.patch
	1064-osd-avoid-inserting-empty-OI_ATTR-in-rollback_setatt.patch

	# todo
	1085-mgr-DaemonServer-fix-order-dependent-ok-to-stop-fals.patch

	# todo
	1089-ceph_dedup-avoid-divide-by-zero-in-EstimateResult-du.patch
	1090-ceph_dedup-write-chunk-data-at-offset-0-in-make_dedu.patch
	1091-ceph_dedup-validate-sampling-ratio-range-in-daemon.patch
	1092-cephfs-data-scan-increment-progress-in-scan_frags.patch
	1093-cephfs-bench-reject-a-block-size-of-0.patch
	1094-cephfs-bench-fix-invalid-short-option-name-for-files.patch
	1095-kv-rocksdb_cache-fix-BinnedLRUCache-l_elems-counter-.patch

	1097-test-add-RISC-V-architecture-probe-tests.patch

	# https://github.com/ceph/ceph/pull/69898
	1099-librbd-cache-pwl-fix-deadlock-in-AbstractWriteLog-de.patch
	1100-librbd-cache-pwl-join-tp_pwl-workers-before-derived-.patch
	1101-librbd-cache-pwl-cancel-periodic-stats-timer-in-dest.patch

	# todo
	1103-rbd-mirror-fix-self-deadlock-in-ImageDeleter-on-bloc.patch

	# todo
	1105-rbd-mirror-avoid-deadlock-removing-local-journal-lis.patch

	# todo
	1107-rbd-mirror-reset-pagination-cursor-before-listing-mi.patch
	1108-rbd-mirror-release-granted-sync-slot-when-canceled-a.patch
	1109-rbd-mirror-start-queued-ops-after-draining-a-namespa.patch
	1110-rbd-mirror-honor-deferred-trash-refresh-once-list-co.patch
	1111-rbd-mirror-complete-init-on-remote-fsid-retrieval-fa.patch
	1112-rbd-mirror-don-t-pollute-replay-stats-on-skipped-dem.patch
	1113-rbd-mirror-guard-m_image_map-init-with-m_lock.patch
	1114-rbd-mirror-keep-peer-config-key-resolution-callout.patch

	# todo
	1118-rgw-keystone-guard-against-empty-secret-file-in-read.patch
	1119-rgw-d4n-pass-next_cursor-by-reference-in-BucketDirec.patch
	1120-rgw-d4n-fix-operator-precedence-in-LFUDA-sync-error-.patch
	1121-rgw-amqp-avoid-dereferencing-end-in-multiple-ack-loo.patch
	1122-rgw-s3-guard-against-empty-key_or_value-in-update_at.patch

	# https://github.com/ceph/ceph/pull/70007
	1123-rgw-es-require-both-major-and-minor-in-ES-version-pa.patch

	1124-rgw-preserve-endpoint-base-path-prefix-in-REST-clien.patch

	1125-rgw-fix-use-after-free-of-meta_sync_cr-in-RGWRemoteM.patch
	1126-rgw-reserve-allocated_acls-to-avoid-dangling-ACL-poi.patch
	1127-rgw-posix-fix-list_buckets-pagination-and-unchecked-.patch
	1128-rgw-keystone-check-barbican-401-before-generic-error.patch
	1129-rgw-posix-do-not-update-quota-stats-when-object-remo.patch

	# https://github.com/ceph/ceph/pull/70149/changes
	1131-osd-PeeringState-avoid-dereferencing-olog-end-in-pro.patch
	1132-osd-PeeringState-fix-proc_master_log-divergence-chec.patch
	1133-test-osd-add-unittest-for-proc_master_log-wind-forwa.patch

	# https://github.com/ceph/ceph/pull/70207
	1134-osdc-fix-ReplicaSplitOp-chunk-distribution-and-reass.patch
	1135-osdc-handle-reads-below-the-min-split-size-in-multi-.patch
	1136-test-librados-cover-ReplicaSplitOp-reassembly-and-mu.patch
	1137-osdc-avoid-divide-by-zero-in-prepare_single_op-on-re.patch

	# https://github.com/ceph/ceph/pull/70211
	1140-src-common-optimize-Zvbc-CRC32C-for-riscv64.patch

	# todo
	# 1141-cmake-run-make-check-reserve-exclusive-cpus-for-crim.patch
	1142-test-common-run-unittest_throttle-serially.patch
	1143-test-mds-run-unittest_mds_quiesce_db-serially.patch

    # -- 2xxx: openRuyi downstream, not for upstream --
    # bump pylint 2.6.0 -> 2.17.7 for py3.13 / wrapt compat
    2001-monitoring-ceph-mixin-bump-pylint.patch
    # bump cephadm pyfakefs pin to >=5.7,<6 for py3.13
    2002-cephadm-tox-pyfakefs-py313.patch

	2006-common-cohort_lru-clear-active-flag-when-object-retu.patch
	2007-rgw-posix-insert-recycled-bucket-cache-entry-under-t.patch

	# DIAGNOSTIC (temporary): capture the sporadic run-rbd-unit-tests-N teardown
	# exit. All 1502 tests pass, then unittest_librbd dies with a nonzero exit in
	# the exit-handler/dtor phase (no core, truncated stdout). This preloads a tiny
	# catcher into unittest_librbd that, on any nonzero/non-main exit, drops a
	# symbolized backtrace under build/exit7-catch/catch-<pid>-*.log. Harmless on
	# clean runs (no dump on exit(0)). Remove once the culprit stack is captured.
	# See notes/rbd-teardown-exit7.md.
	2050-diag-capture-rbd-teardown-exit7.patch

)
# 2005: prefer the temporary OBS project home:sunyuechi:openruyi-test (priority=1)
# for deps, falling back to stock openRuyi repos for packages it doesn't publish.
# Conditional: TEMP_OBS_REPO=0 leaves the patch out entirely.
if [ "${TEMP_OBS_REPO}" = 1 ]; then
    TREE_PATCHES+=(2005-build-prefer-home-sunyuechi-openruyi-test-OBS-repo-f.patch)
fi
