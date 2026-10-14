#!/usr/bin/env bash
# Run an R script with an optional local verification library.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p dev/state/tmp/Rlib
export R_LIBS="$PWD/dev/state/tmp/Rlib"
exec Rscript "$@"
