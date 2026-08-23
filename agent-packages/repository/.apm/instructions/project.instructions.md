---
description: Preserve Flyology Device's project-specific repository rules and verification workflow.
---

# Repository agent instructions

This repository holds userspace device-access crates for Ada. The root is
not a crate: it carries shared tooling and documentation, and every crate
lives in its own subdirectory as a peer. No crate is privileged, and future
driver crates join as peers rather than as children of an existing one.

- Use `gh` outside the sandbox; it does not work inside the sandbox.
- Commit messages follow `Problem:` / `Solution:`.
- Do not add `Co-Authored-By` trailers, or any other tool or assistant
  attribution, to commit messages.

## Crates

- `flyology_dma` — DMA-capable host memory: hugepage-backed regions, IOVA
  address-space management, and fixed-size buffer pools. Knows nothing about
  any device, any bus, and in particular nothing about VFIO.
- `flyology_vfio` — the Linux VFIO userspace device interface: container,
  group and device lifecycle, PCI BAR mapping, MMIO register access, and
  interrupt delivery. Implements the `Mapper` interface that `flyology_dma`
  declares.
- `flyology_vfio_runtime` — waiting for a VFIO interrupt on a Flyology event
  loop. One waiter, in a crate of its own so that the runtime's licence and
  its custom Ada runtime stay out of the crate that binds an ioctl.
- `flyology_vfio_qemu` — a bring-up harness that drives QEMU's virtual PCI
  devices through the others. It is not a library anything should depend
  on: it exists to make the layers below it prove themselves against a
  device, which none of them can do alone.

The dependency runs one way — `flyology_vfio_qemu` and
`flyology_vfio_runtime` both onto `flyology_vfio`, and that onto
`flyology_dma` — and there is no cycle. `flyology_dma` sits at the bottom
and depends on nothing in this repository.

`flyology_vfio_runtime` is the only crate here that depends on the
`flyology` runtime, and that is deliberate rather than incidental: the
runtime brings a `GPL-3.0-or-later` component and a custom Ada runtime with
it, and confining both to one clearly named peer is what keeps the rest of
the repository free of them. If a second crate needs the runtime, that is a
decision to take openly, not one to discover after it has leaked.

If a change to `flyology_dma` seems to need VFIO, reshape the interface
instead. That interface is what lets other backends — VFIO no-IOMMU mode,
virtio-mmio on a platform bus, a pure-test identity mapper — take VFIO's
place without the region and pool code noticing.

## Boundaries

- Neither `flyology_dma` nor `flyology_vfio` contains a device driver, a
  descriptor format, or a packet. `flyology_vfio` gets you a mapped BAR, a
  working DMA mapping, and an interrupt, and stops. A device identifier in
  either crate's sources means the boundary has been breached.
- `flyology_vfio_qemu` is where device knowledge is allowed, and it is the
  only place. It holds register maps, descriptor rings and command sets for
  the devices it drives, because that is what driving them requires. It is
  a peer of the other two rather than a layer of them, and nothing depends
  on it.
- Descriptor rings are deliberately absent. They are device-shaped, and a
  generic ring designed before any real device exists would be wrong.
  Revisit only once two drivers exist and their needs can be compared.

## Naming

- Each crate uses a single underscored root package: `Flyology_DMA` with
  children such as `Flyology_DMA.Regions`, `Flyology_VFIO` with children
  such as `Flyology_VFIO.Thin`, and `Flyology_VFIO_QEMU` with one child per
  device it drives.
- Never introduce a `Flyology` parent unit in any crate here. A parent
  package collides when the crate is used alongside the Flyology runtime,
  which is why every standalone crate in this ecosystem uses a single
  underscored root. `flyology_iri`, `flyology_rdf`, and `flyology_simd` all
  follow this; only crates that depend on the `flyology` runtime crate
  itself, such as `flyology_http`, use `Flyology.X` child units.
- A crate may add children to another crate's root, and
  `flyology_vfio_runtime` does: it holds `Flyology_VFIO.Flyology_Runtime`.
  The test is which package owns the concept. That one implements
  `Flyology_VFIO.Interrupts.Waiter`, so it belongs in `Flyology_VFIO`'s
  namespace, and putting it under the runtime's root instead would have had
  the runtime claiming a VFIO concept it knows nothing about. A consequence
  worth knowing: such a child appears in neither the parent crate's
  documentation nor a standalone build of it.

## Platform

Both crates are Linux-only. `flyology_dma` calls `mmap` with `MAP_HUGETLB`
and `mlock`; `flyology_vfio` calls `ioctl` on `/dev/vfio`. Neither builds on
macOS, which is a common development host here, so the Linux toolchain is
provisioned by `scripts/linux/run.sh` rather than assumed present.

Three environments matter, and it is worth being explicit about what each
one can actually check:

- **Container** (`scripts/linux/run.sh`) builds both crates and runs every
  test that needs only ordinary anonymous memory. It cannot run hugepage
  tests: a container shares the host kernel, and the Docker Desktop and
  OrbStack kernels are built without `hugetlbfs`. It has no IOMMU and no
  `/dev/vfio`.
- **Virtual machine** (`scripts/qemu/`) runs a kernel this repository
  controls, so it can reserve hugepages and, with an emulated IOMMU, expose
  `/dev/vfio` and a device bound to `vfio-pci`.
- **Bare metal with a real device** is the only environment that validates
  the crate against hardware. Nothing in this repository claims a result it
  has not actually run there.

State which environment produced a result whenever a result is reported. A
passing test in the container says nothing about hugepages.

## Testing

- Keep tests under each crate's `tests/`, and maintained examples and
  benchmarks under its `showcases/`.
- Run `<crate>/scripts/test.sh` after changing that crate, or the repo-wide
  `./scripts/test.sh` to cover both. `./scripts/prove.sh` and
  `./scripts/docs.sh` dispatch the same way.
- Environment scripts report readiness; they do not mutate the host. A script
  in this repository never unbinds a device from a running kernel driver,
  never changes `vm.nr_hugepages` on a machine it does not own, and never
  raises a limit behind the operator's back. It says what is wrong and what
  command would fix it.
- Failure modes here are environmental: no hugepages reserved,
  `RLIMIT_MEMLOCK` too low, IOMMU disabled on the kernel command line, a
  stray device still bound in the IOMMU group. Every error names the specific
  condition and the specific fix. Nothing falls back silently.

## Correctness posture

- Confusing an IOVA with a host virtual address is the defining bug of this
  problem domain. They are distinct types, and no implicit conversion exists
  between them.
- Lifecycle ordering that fails far from its cause belongs in the type
  system, not in documentation. A group is attached to a container before the
  IOMMU is set because the types say so, not because a comment asks.
- Ioctl request numbers and argument-struct layouts are generated from the
  kernel header and checked against it, never transcribed from memory.

## Documentation

- Every public declaration carries a GNATdoc leading comment.
  `<crate>/scripts/docs.sh` must produce that crate's `docs/api/index.html`
  without errors.
- Prose is modest. Both crates are experimental. Do not imply production
  qualification, hardware coverage beyond what has actually been run, or
  portable performance results.

## Releases

- Each crate is tagged and released independently through an immutable
  annotated tag named `<crate>/v<version>`, for example `flyology_dma/v0.1.0`.
  `flyology_vfio_qemu` is a harness rather than a library and has no reason
  to be released at all unless something outside this repository comes to
  depend on it.
- Before tagging, set that crate's `alire.toml` to the exact stable version,
  replace development constraints and path pins with stable constraints, and
  run its required checks plus `alr show`. The manifest name and version must
  match the tag exactly.
- Create and push the tag only after committing the release-ready manifests:

  ```sh
  git tag -a <crate>/v<version> -m "Release <crate> <version>"
  git push origin refs/tags/<crate>/v<version>
  ```

- Never move, replace, or reuse a published release tag. Put the next
  development-version change in a later commit.
