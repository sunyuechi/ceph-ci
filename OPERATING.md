# Operating this CI

## Repo layout

| path | what |
|------|------|
| `scripts/fetch-openruyi-image.sh` | `podman pull` the openRuyi minimal OCI image from the registry and tag it `localhost/openruyi-oci:riscv64` (always pulls so upstream updates land; `OFFLINE=1` to reuse the local image) |
| `scripts/fetch-openruyi-image-obs.sh` | alt source: download the OBS rootfs tarball + `podman import` it as `localhost/openruyi-oci:riscv64` (conditional download; `OFFLINE=1` to re-import the cached tarball) |
| `scripts/run-build-check.sh` | **build-check** driver (upstream main): clone ceph @ ref, apply fork patches, run `build-with-container.py --distro openruyi -e tests`; bucket `${WORKDIR}/build-check/` |
| `scripts/openruyi/run-spec-build.sh` | **spec-openruyi** driver (`openruyi_spec` option): host side -- image, proxy, caches, ctest options -- then launch the container half; bucket `${WORKDIR}/spec-openruyi/` |
| `scripts/openruyi/spec-build-in-container.sh` | container half: `rpmdev-spectool -g` + `dnf builddep` + `rpmbuild -bb --nocheck --with make_check` on `openruyi/ceph.spec`, then build-check-style ctest on the spec's build tree |
| `openruyi/` | the openRuyi downstream `ceph.spec` + its `%patchlist`/source patches (validated by `run-spec-build.sh`) |
| `scripts/upstream-spec/run-spec-in-build.sh` | **spec-upstream** driver: validate the UPSTREAM `ceph.spec.in`: upstream checkout (pristine, or with `scripts/upstream-spec/*.patch` applied+committed to test a patch bound for upstream), host side (image, proxy, caches, ctest), then the container half; bucket `${WORKDIR}/spec-upstream/` |
| `scripts/upstream-spec/*.patch` | optional patches applied onto the upstream checkout before make-dist (e.g. one you're preparing to submit upstream); none present = a clean upstream build |
| `scripts/upstream-spec/spec-in-build-in-container.sh` | container half: upstream `make-dist` (`ceph.spec.in` -> `ceph.spec` + Source0 tarball; dashboard npm step skipped unless `MAKE_DIST_FULL=1`) + `dnf builddep`, then validate the spec via rpm short-circuit (`-bc` -> ctest on the tree -> `-bi --short-circuit` -> `-bl`), or a full `-bb` under `SKIP_CTEST=1` |
| `scripts/run-vstart-smoke.sh` | L3 (experimental): vstart single-node IO smoke on the build-check build tree |
| `fork-patches/` | patches teaching ceph about openRuyi + riscv64, rebased onto ceph `main` (`TREE_PATCHES` in `run-build-check.sh`) |
| `fork-patches/submodules/` | submodule patches; path mirrors the submodule's path in the ceph tree (e.g. `src/isa-l/`), applied via `SUBMODULE_PATCHES` |
| `.github/workflows/build-and-check.yml` | the three CIs (build-check / spec-openruyi / spec-upstream) on a `[self-hosted, linux, riscv64]` runner (push + manual dispatch) |
| `known-failures.json` | ctest excludes/flakes (tagged `exclude`/`flake`), consumed by `run-build-check.sh` |

## On-machine layout (which dir belongs to which CI)

Each of the three CIs owns ONE subdir under `${WORKDIR}` (on the runner,
`WORKDIR=/root/syc-test/ruyi-ci-test`). Nothing is shared or flat — to inspect a run,
`cd` into its bucket and everything there is that CI's:

```
${WORKDIR}/
  build-check/        # scripts/run-build-check.sh   (workflow: default, no spec toggle)
  spec-openruyi/      # scripts/openruyi/run-spec-build.sh        (openruyi_spec ticked)
  spec-upstream/      # scripts/upstream-spec/run-spec-in-build.sh (upstream_spec ticked)
```

Inside every bucket the same names recur (so the layout is identical across CIs):

| name | what |
|------|------|
| `run.log` | symlink to the newest run's log — `tail -f <bucket>/run.log` follows it live |
| `mem-usage.log` | symlink to the newest run's memory-sampler log |
| `ci-log/` | timestamped per-run logs (`<ts>-run.log`, `<ts>-mem.log`) — the history |
| `ceph/` | the ceph checkout + `build/` tree (build-check & spec-upstream; spec-openruyi builds inside its rpm `build/` instead) |
| `build/` | spec paths only: the persisted rpm `BUILD/` tree (cmake build + BUILDROOT) |
| `sources/` `rpms/` `artifacts/` `state/` | spec paths only: spectool/make-dist tarballs, built rpms, ctest `Testing/`+`CMakeCache`, generated spec |
| `sccache-cache/` | the per-CI sccache cache (kept separate so differing compile flags don't churn one shared cache) |
| `.image-fp` / `.deps-fp` / `.deps-pkghash` / `.deps-meta` | cached build/deps-image fingerprints |

## Running by hand (riscv64 host)

```bash
# host needs riscv64, podman >= 4, git. openRuyi is not required on the host;
# the build runs in the openRuyi container.
git clone <this repo> ceph-ci && cd ceph-ci
CEPH_REF=main ./scripts/run-build-check.sh
```

Validate the openRuyi downstream spec instead of upstream main (`rpmbuild` of
`openruyi/ceph.spec` in the container -- spec drives `%prep`/`%build`/`%install`,
no fork-patches -- then ctest on its build tree, with the spec's own downstream
config: `WITH_CRIMSON=OFF`, RelWithDebInfo, no ASan):

```bash
./scripts/openruyi/run-spec-build.sh
```

Via the GitHub UI once the runner is up: Actions → build-and-check → "Run workflow"
(tick `openruyi_spec` for the spec-validation path; it ignores `ceph_ref`).

Validate the **upstream** `ceph.spec.in` (not the `openruyi/` spec): an upstream
checkout, upstream `make-dist` turns `ceph.spec.in` into a real `ceph.spec` + Source0
tarball, then `rpmbuild` validates it and ctest runs on its build tree. Because the
spec's `%install` deletes the cmake tree (`rm -rf %{_vpath_builddir}`), the spec is
built via rpm short-circuit so the tree survives for ctest — no spec edits:

```bash
./scripts/upstream-spec/run-spec-in-build.sh
# CEPH_REF=<branch/tag/sha>   pick the upstream revision (default main)
# SKIP_CTEST=1                full `rpmbuild -bb` (real rpms, %install/%files), no ctest
# MAKE_DIST_FULL=1            run vanilla make-dist incl. the dashboard frontend npm build
```

To test a patch you intend to submit upstream, drop it in `scripts/upstream-spec/`
(`*.patch`): each is `git apply`'d and committed onto the checkout before make-dist
(committed so make-dist's `git archive HEAD` tarball picks up source changes too). A
patch that changes BuildRequires rebuilds the deps image automatically. With no
`*.patch` present the checkout is pristine upstream.

By default `make-dist`'s dashboard-frontend npm build is skipped: the spec's `%build`
sets `WITH_MGR_DASHBOARD_FRONTEND=OFF`, so that (heavy, riscv64-flaky) output is never
used by `rpmbuild`. `MAKE_DIST_FULL=1` runs make-dist verbatim.

## ctest tuning (known-failures.json)

ctest options are assembled in `run-build-check.sh` from `known-failures.json`
and forwarded as `CHECK_MAKEOPTS` — nothing is set by hand:

- `--timeout 6000` — riscv64-only (slow hardware), mirroring openRuyi's `%ctest` macro.
- `-E '^(...)$'` — `known-failures.json` entries tagged `exclude`.
- `--repeat until-pass:N` — added when any entry is tagged `flake` (`N`=`FLAKE_RETRIES`, default 2).

The cmake feature set is a separate axis — the `CONFIGURE_FLAGS` array in `run-build-check.sh`.
