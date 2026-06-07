# Operating this CI

## Repo layout

| path | what |
|------|------|
| `scripts/fetch-openruyi-image.sh` | `podman pull` the openRuyi minimal OCI image from the registry and tag it `localhost/openruyi-oci:riscv64` (always pulls so upstream updates land; `OFFLINE=1` to reuse the local image) |
| `scripts/fetch-openruyi-image-obs.sh` | alt source: download the OBS rootfs tarball + `podman import` it as `localhost/openruyi-oci:riscv64` (conditional download; `OFFLINE=1` to re-import the cached tarball) |
| `scripts/run-build-check.sh` | L2 driver: clone ceph @ ref, apply fork patches, run `build-with-container.py --distro openruyi -e tests` |
| `scripts/run-vstart-smoke.sh` | L3 (experimental): vstart single-node IO smoke on the L2 build tree |
| `fork-patches/` | patches teaching ceph about openRuyi + riscv64, rebased onto ceph `main` (`TREE_PATCHES` in `run-build-check.sh`) |
| `fork-patches/submodules/` | submodule patches; path mirrors the submodule's path in the ceph tree (e.g. `src/isa-l/`), applied via `SUBMODULE_PATCHES` |
| `.github/workflows/build-and-check.yml` | L2 on a `[self-hosted, linux, riscv64]` runner (push + manual dispatch) |
| `known-failures.json` | ctest excludes/flakes (tagged `exclude`/`flake`), consumed by `run-build-check.sh` |

## Running by hand (riscv64 host)

```bash
# host needs riscv64, podman >= 4, git. openRuyi is not required on the host;
# the build runs in the openRuyi container.
git clone <this repo> ceph-ci && cd ceph-ci
CEPH_REF=main ./scripts/run-build-check.sh
```

Via the GitHub UI once the runner is up: Actions → build-and-check → "Run workflow".

## ctest tuning (known-failures.json)

ctest options are assembled in `run-build-check.sh` from `known-failures.json`
and forwarded as `CHECK_MAKEOPTS` — nothing is set by hand:

- `--timeout 6000` — riscv64-only (slow hardware), mirroring openRuyi's `%ctest` macro.
- `-E '^(...)$'` — `known-failures.json` entries tagged `exclude`.
- `--repeat until-pass:N` — added when any entry is tagged `flake` (`N`=`FLAKE_RETRIES`, default 2).

The cmake feature set is a separate axis — the `CONFIGURE_FLAGS` array in `run-build-check.sh`.
