#!/usr/bin/env zsh
# Cross-builds arena for each release target into dist/: a tarball and its checksum apiece.
set -euo pipefail
cd "${0:A:h}/.."

version=$(git describe --always --dirty)
targets=(x86_64-linux aarch64-linux x86_64-macos aarch64-macos)

rm -rf dist
mkdir -p dist
for target in $targets; do
  name=arena-$version-$target
  zig build -Doptimize=ReleaseSafe -Dtarget=$target -p dist/stage/$name
  mkdir dist/$name
  cp dist/stage/$name/bin/arena dist/$name/arena
  tar -C dist -czf dist/$name.tar.gz $name
  (cd dist && sha256sum $name.tar.gz > $name.tar.gz.sha256)
  rm -rf dist/$name
done
rm -rf dist/stage
ls -l dist
