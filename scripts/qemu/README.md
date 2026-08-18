# The virtual machine harness

Two of this repository's three environments cannot run the interesting
tests. A macOS host has neither hugepages nor VFIO; a container shares the
host kernel, and the Docker Desktop and OrbStack kernels are built without
`hugetlbfs` and expose no IOMMU. What is left needs a kernel this repository
controls, which is what this directory provides.

The guest is a stock Debian cloud image with an emulated SMMUv3 and three
QEMU virtual PCI devices attached. Inside it, `hugetlbfs` works, an IOMMU
exists, `/dev/vfio` exists, and a device can be bound to `vfio-pci` without
taking anything important away from a running system.

## What it can and cannot tell you

It genuinely validates the IOMMU path: QEMU walks the emulated SMMU's page
tables when a device dereferences an address, so an IOVA this repository
programmed incorrectly produces a translation fault rather than quietly
working. That is the property most worth testing and the hardest to test
any other way.

It validates nothing about real hardware. There is no silicon behind these
devices: no errata, no bus timing, no write-combining, no MSI-X table with a
sparse-mmap hole, no 64-bit or multi-BAR layouts. A result from here is a
result about the binding, not about a device.

## Usage

```sh
scripts/qemu/run.sh up          # boot the guest, first run downloads an image
scripts/qemu/run.sh exec '...'  # run a command in the guest
scripts/qemu/run.sh test        # build the crates for Linux and run everything
scripts/qemu/run.sh down        # shut the guest down
```

Nothing here touches the host's own devices or drivers.
