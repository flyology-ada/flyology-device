#  Linux build and test environment for the flyology-device crates.
#
#  Both crates target Linux: flyology_dma calls mmap with MAP_HUGETLB and
#  mlock, and flyology_vfio calls ioctl on /dev/vfio. Neither builds on
#  macOS, which is a common development host here, so the Linux compiler
#  lives in a container rather than being assumed present.
#
#  What this image can and cannot do is worth stating plainly. It builds
#  both crates and runs every test that needs only ordinary anonymous
#  memory. It cannot run hugepage tests, because a container shares the
#  host kernel and Docker Desktop and OrbStack kernels are built without
#  hugetlbfs, and it cannot run VFIO tests, because there is no IOMMU and
#  no /dev/vfio. Those need a virtual machine; see scripts/qemu/.
FROM debian:bookworm-slim

RUN apt-get -qq update \
 && apt-get -qq install -y --no-install-recommends \
      ca-certificates curl unzip git gcc libc6-dev make xz-utils \
      linux-libc-dev python3 \
 && rm -rf /var/lib/apt/lists/*

ARG ALIRE_VERSION=2.1.1
ARG TARGET_ARCH=aarch64
RUN curl -fsSL -o /tmp/alr.zip \
      "https://github.com/alire-project/alire/releases/download/v${ALIRE_VERSION}/alr-${ALIRE_VERSION}-bin-${TARGET_ARCH}-linux.zip" \
 && unzip -q /tmp/alr.zip -d /tmp/alr \
 && install -m755 /tmp/alr/bin/alr /usr/local/bin/alr \
 && rm -rf /tmp/alr /tmp/alr.zip \
 && alr version

ARG GNAT_VERSION=15.3.1
ARG GPRBUILD_VERSION=25.0.1
RUN alr -n toolchain --select "gnat_native=${GNAT_VERSION}" \
                              "gprbuild=${GPRBUILD_VERSION}" \
 && alr -n toolchain

#  Alire stores the selected toolchain under a directory whose name carries
#  a content hash, so the path is resolved at run time rather than baked in.
#  Crate scripts reach the compiler through `alr exec --` in any case.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'for d in /root/.local/share/alire/toolchains/*/bin; do' \
      '  if [ -d "$d" ]; then PATH="$d:$PATH"; fi' \
      'done' \
      'export PATH' \
      'exec "$@"' \
    > /usr/local/bin/with-toolchain \
 && chmod +x /usr/local/bin/with-toolchain \
 && with-toolchain gnatmake --version | head -1

WORKDIR /repo
ENTRYPOINT ["/usr/local/bin/with-toolchain"]
CMD ["sh"]
