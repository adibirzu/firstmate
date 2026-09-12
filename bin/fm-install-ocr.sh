#!/usr/bin/env bash
# fm-install-ocr.sh - install Alibaba's Open Code Review (`ocr`) CLI, the
# deterministic-first review engine bin/fm-review.sh depends on
# (https://github.com/alibaba/open-code-review).
#
# ocr is npm-distributed, not a pinned GitHub release binary like this repo's
# other bin/fm-install-<tool>.sh scripts, so there is no per-platform checksum
# to pin here. Installs into a throwaway npm prefix under the destination
# directory with no sudo, then symlinks the resulting `ocr` binary at
# <destination>/ocr so callers use it exactly like every other
# fm-install-<tool>.sh output. A symlink (not a copy) is required: npm's bin
# shim resolves its package relative to its own real location, so copying it
# out of the npm prefix would break that resolution.
#
# Usage:
#   fm-install-ocr.sh <destination-directory>
set -eu

OCR_NPM_PACKAGE=@alibaba-group/open-code-review

die() {
  printf 'fm-install-ocr.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-ocr.sh <destination-directory>}

command -v npm >/dev/null 2>&1 || die "npm is required to install $OCR_NPM_PACKAGE"

mkdir -p "$DESTINATION"
PREFIX="$DESTINATION/.ocr-npm-prefix"
mkdir -p "$PREFIX"

npm install --global --prefix "$PREFIX" "$OCR_NPM_PACKAGE" \
  || die "npm install --global --prefix $PREFIX $OCR_NPM_PACKAGE failed"

INSTALLED_BIN="$PREFIX/bin/ocr"
[ -e "$INSTALLED_BIN" ] || die "npm install completed but $INSTALLED_BIN was not produced"

ln -sf "$INSTALLED_BIN" "$DESTINATION/ocr"
"$DESTINATION/ocr" --version
