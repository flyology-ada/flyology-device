#!/bin/sh
#  Fails when a build has written outside the directories set aside for it.
#
#  This exists because it has already happened twice. Raw gnatmake writes its
#  objects and its generated binder sources into the current directory unless
#  a project file tells it otherwise, so a build launched from the repository
#  root scatters .ali, .o and b~*.ad[bs] files across the tree — and two of
#  those are Ada source by extension, so nothing that filters by file type
#  catches them.
#
#  Every build in this repository goes through a project file that declares
#  Object_Dir and Exec_Dir. This script is what notices when one does not.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

#  Artefacts are legitimate inside a crate's own obj/, lib/ and bin/, and
#  inside build/. Anywhere else they are a build that escaped.
strays=$(find . \
  -type d \( -name .git -o -name obj -o -name lib -o -name bin \
             -o -name build -o -name alire -o -name config \) -prune -o \
  -type f \( -name '*.ali' -o -name '*.o' -o -name '*.a' \
             -o -name 'b~*.ads' -o -name 'b~*.adb' \) -print)

if [ -z "$strays" ]; then
  printf '%s\n' "no build artefacts outside obj/, lib/, bin/ and build/"
  exit 0
fi

printf '%s\n' "" "Build artefacts were written outside the directories set" \
  "aside for them:" "" >&2
printf '%s\n' "$strays" >&2
printf '%s\n' "" \
  "Something built without a project file, or with one that does not set" \
  "Object_Dir and Exec_Dir. Find it and fix it rather than deleting these:" \
  "they will come back on the next build." >&2
exit 1
