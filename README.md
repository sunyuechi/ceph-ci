# ceph-ci — a riscv64 Ceph CI on openRuyi

A dedicated CI that builds Ceph and runs `make check` (ctest) on **riscv64
hardware**, inside an **openRuyi** container, by reusing Ceph's own containerized
PR job (`src/script/build-with-container.py`). The commands, flags and result
format match the existing `ceph-pull-requests-*` jobs, so it lines up with a
`ceph-pull-requests-riscv64` job rather than its own ad-hoc setup.

## How it works

You run **one command** — `scripts/run-build-check.sh` (also the body of the
GitHub Actions workflow). It is self-contained; the three stages below are what
that single script does internally, not separate steps to invoke:

1. Clone `ceph/ceph` at `CEPH_REF` (default `main`; any branch / tag / sha).
2. Apply the openRuyi + riscv64 fork-patches onto the clean tree, auto-skipping
   any already merged upstream.
3. Run `build-with-container.py --distro openruyi -e tests`, which configures,
   builds and runs ctest **inside the openRuyi container**. The cmake flags and
   the ctest command come from Ceph's own `run-make.sh` / `run-make-check.sh`.

See [`OPERATING.md`](./OPERATING.md) for the exact invocation.

## Fork patches

[`fork-patches/`](./fork-patches) carries the changes that teach `ceph/ceph` to
build on openRuyi + riscv64. The four-digit prefix marks intent, the same way
openRuyi numbers its spec `%patchlist`:

- **1xxx — bound for upstream**: either ours or carried from openRuyi's ceph
  spec; each comment links the PR/commit, or marks `TODO` if not yet submitted.
- **2xxx — openRuyi downstream**, not intended for upstream.

Submodule patches go under `fork-patches/submodules/`, mirroring the submodule's
path in the Ceph tree (e.g. `submodules/src/isa-l/`).

## Scope

The **build-check** CI (`make check` / ctest — test level **L2**) is the main target,
the same scope as upstream's containerized PR job. **L3** (vstart single-node IO smoke)
is an optional follow-up. **L4/L5** (teuthology, multi-machine) stay with upstream's
Sepia lab.

## The three CIs

One workflow (`build-and-check.yml`), three mutually-exclusive paths, each with its own
driver script and its own `${WORKDIR}/<bucket>/` subdir on the runner so their logs,
checkouts and caches never interleave:

| CI | what it does | driver | bucket |
|----|--------------|--------|--------|
| **build-check** | clone ceph + apply fork-patches + build + ctest (the PR-style job) | `scripts/run-build-check.sh` | `${WORKDIR}/build-check/` |
| **spec-openruyi** | rpmbuild the **downstream** `openruyi/ceph.spec` + ctest | `scripts/openruyi/run-spec-build.sh` | `${WORKDIR}/spec-openruyi/` |
| **spec-upstream** | make-dist the **upstream** `ceph.spec.in` → rpmbuild + ctest | `scripts/upstream-spec/run-spec-in-build.sh` | `${WORKDIR}/spec-upstream/` |

Inside every bucket the same names recur: `run.log` (symlink to the newest run),
`ci-log/` (timestamped run + mem logs), `ceph/` (the checkout, build-check & spec-upstream),
`build/` `sources/` `rpms/` `artifacts/` `state/` (spec paths), `sccache-cache/`,
`ccache-cache/` (build-check).

## More

How to run and operate this CI: [`OPERATING.md`](./OPERATING.md).
