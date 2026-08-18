#!/bin/sh
#  Generates this crate's API documentation into docs/api.
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
alr=$("$repo_root/scripts/find-alr.sh")

if ! command -v gnatdoc >/dev/null 2>&1; then
  installed_gnatdoc=${ALIRE_INSTALL_PREFIX:-"$HOME/.alire"}/bin/gnatdoc
  if [ ! -x "$installed_gnatdoc" ]; then
    printf '%s\n' \
      "gnatdoc not found; install it with: alr install gnatdoc_bin" >&2
    exit 1
  fi
  PATH=$(dirname "$installed_gnatdoc"):$PATH
  export PATH
fi

cd "$crate_root"
"$alr" -n build --stop-after=generation
"$alr" exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  -P flyology_vfio_qemu.gpr \
  -O docs/api

test -f docs/api/index.html
