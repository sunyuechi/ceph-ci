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
	# https://github.com/ceph/ceph/pull/69455
    1012-test-crimson-messenger-thrash-bump-memory.patch
	# https://github.com/ceph/ceph/pull/69520
	1023-crimson-cmake-restrict-Wno-non-virtual-dtor-to-C-sou.patch
	# https://github.com/ceph/ceph/pull/69519
	1024-pybind-rbd-rgw-place-nogil-after-the-exception-speci.patch

	# https://github.com/ceph/ceph/pull/69604
	1032-mgr-MMgrReport-default-initialize-PerfCounterType-un.patch

	# https://github.com/ceph/ceph/pull/69623
	1038-tools-immutable_object_cache-don-t-leak-in-flight-re.patch

	# https://github.com/ceph/ceph/pull/69643
	1039-open_image-fix.patch
	1040-internal-api-test_Encryption.cc.patch
	1041-test_DiffIterate.cc.patch

	# https://github.com/ceph/ceph/pull/69680
	# ASan-guarded test shrinks (__has_feature(address_sanitizer)); no-ops without
	# ASan, so applied unconditionally. ASan itself is opt-in via WITH_ASAN in
	# run-build-check.sh (-DWITH_ASAN=ON), which replaces former patch 1048.
	1045-test-crimson-omap-enlarge-values-under-ASan-to-shrin.patch
	# todo
	1046-test-crimson-onode-shrink-synthetic-pool-under-ASan.patch
	1047-test-transaction_manager-shrink-working-set-under-AS.patch

	# todo
	1052-osd-ECBackend-fix-iterator-invalidation-in-omap_get.patch
	1053-osd-ECOmapJournal-bind-by-reference-when-clearing-om.patch
	1054-osd-PeeringState-avoid-dereferencing-olog-end-in-pro.patch
	# https://github.com/ceph/ceph/pull/69743
	1055-osd-scheduler-add-missing-breaks-in-PGRecoveryMsg-ru.patch
	1056-osd-ECUtil-fix-offset-accumulation-in-slice_map.patch
	1057-osd-scrubber-send-real-reservation-nonce-in-scrub-gr.patch

	#todo
	1058-osd-guard-max_element-end-deref-in-get_health_metric.patch
	# https://github.com/ceph/ceph/pull/69746
	1059-osd-fix-osd_reqid_t-comparison-strict-weak-ordering.patch
	1060-osd-fix-misspelled-inject-ec-clear-command-names.patch
	1061-osd-dump_osd_network-min-section-now-reports-min-not.patch
	# https://github.com/ceph/ceph/pull/69865
	1062-osd-report-EINVAL-to-on_finish-in-asok_route_to_pg-c.patch
	1063-osd-drop-bogus-snaps-key-in-rollback_extents-dump.patch
	1064-osd-avoid-inserting-empty-OI_ATTR-in-rollback_setatt.patch

	# https://github.com/ceph/ceph/pull/69758
	1065-seastar-bump.patch

	# https://github.com/ceph/ceph/pull/69823
	1066-mon-MgrMonitor-reply-to-client-on-invalid-mgr-set-co.patch
	# https://github.com/ceph/ceph/pull/69835
	1067-mds-Server-return-after-responding-on-error-paths.patch
	# https://github.com/ceph/ceph/pull/69822
	1068-common-pick_address-match-against-the-current-iface-.patch
	# https://github.com/ceph/ceph/pull/69821
	1070-rgw-fix-inverted-MFA-check-in-DeleteMultiObj-for-ver.patch
	1071-rgw-posix-fix-inverted-If-None-Match-check-allowing-.patch
	1072-rgw-sts-fix-inverted-tokenCode-length-validation.patch
	# https://github.com/ceph/ceph/pull/69819
	1074-blk-spdk-call-spdk_env_opts_init-before-setting-pci-.patch

	# https://github.com/ceph/ceph/pull/69863
	1075-crimson-osd-replicated_recovery_backend-fix-use-afte.patch
	# todo
	1076-crimson-osd-pg_recovery-fix-exception-handler-scope-.patch

	# https://github.com/ceph/ceph/pull/69862
	1077-crimson-mon-MonClient-fix-use-after-free-in-run_comm.patch

	# https://github.com/ceph/ceph/pull/69855
	1078-fix-crimson-osd-ec_backend.patch

	# todo
	1080-cmake-keep-seastar-s-Seastar_SANITIZE-in-lockstep-wi.patch

	# todo
	1081-client-fix-double-unlock-of-client_lock-in-mount.patch
	1082-client-fix-_wrap_name-reporting-success-on-encryptio.patch
	1083-client-don-t-use-uninitialized-keyid-in-fscrypt_dumm.patch
	1084-osdc-fix-ReplicaSplitOp-picking-an-invalid-acting-in.patch
	1085-mgr-DaemonServer-fix-order-dependent-ok-to-stop-fals.patch
	1086-rados-do-not-close-stdin-after-put-append-from.patch
	1087-rados-fix-leaked-unflushed-output-stream-in-ls.patch
	1088-rados-do-not-close-stdout-after-export-to.patch
	1089-ceph_dedup-avoid-divide-by-zero-in-EstimateResult-du.patch
	1090-ceph_dedup-write-chunk-data-at-offset-0-in-make_dedu.patch
	1091-ceph_dedup-validate-sampling-ratio-range-in-daemon.patch
	1092-cephfs-data-scan-increment-progress-in-scan_frags.patch
	1093-cephfs-bench-reject-a-block-size-of-0.patch
	1094-cephfs-bench-fix-invalid-short-option-name-for-files.patch
	1095-kv-rocksdb_cache-fix-BinnedLRUCache-l_elems-counter-.patch

    # -- 2xxx: openRuyi downstream, not for upstream --
    # bump pylint 2.6.0 -> 2.17.7 for py3.13 / wrapt compat
    2001-monitoring-ceph-mixin-bump-pylint.patch
    # bump cephadm pyfakefs pin to >=5.7,<6 for py3.13
    2002-cephadm-tox-pyfakefs-py313.patch

	2006-common-cohort_lru-clear-active-flag-when-object-retu.patch
	2007-rgw-posix-insert-recycled-bucket-cache-entry-under-t.patch

)
# 2005: prefer the temporary OBS project home:sunyuechi:openruyi-test (priority=1)
# for deps, falling back to stock openRuyi repos for packages it doesn't publish.
# Conditional: TEMP_OBS_REPO=0 leaves the patch out entirely.
if [ "${TEMP_OBS_REPO}" = 1 ]; then
    TREE_PATCHES+=(2005-openruyi-temp-obs-repo.patch)
fi
