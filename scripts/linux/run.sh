#!/bin/sh
#  Runs a command inside the Linux build and test container.
#
#  Usage: scripts/linux/run.sh ./scripts/test.sh
#         scripts/linux/run.sh sh -c 'cd flyology_dma && alr build'
#
#  The repository is bind-mounted at /repo, so builds write into the working
#  tree and their artefacts are the gitignored obj/, lib/, and bin/ trees the
#  crate scripts already produce. Build products from the container and from
#  a macOS host therefore overwrite each other; that is deliberate, because
#  keeping two object trees in one directory produces stale-object failures
#  that are far more confusing than a rebuild.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
image=${FLYOLOGY_DEVICE_LINUX_IMAGE:-flyology-device-linux:latest}
platform=${FLYOLOGY_DEVICE_LINUX_PLATFORM:-linux/$(uname -m | sed 's/^arm64$/arm64/;s/^x86_64$/amd64/')}

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' \
    "docker was not found; it provides the Linux toolchain this repository" \
    "builds with. Install Docker, OrbStack, or Podman with a docker alias." >&2
  exit 2
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
  printf '%s\n' "Building $image (first run only)" >&2
  target_arch=$(printf '%s' "$platform" | sed 's#linux/arm64#aarch64#;s#linux/amd64#x86_64#')
  docker build \
    --platform "$platform" \
    --build-arg "TARGET_ARCH=$target_arch" \
    -t "$image" \
    "$repo_root/scripts/linux"
fi

exec docker run --rm \
  --platform "$platform" \
  -v "$repo_root:/repo" \
  -w /repo \
  "$image" \
  "$@"
