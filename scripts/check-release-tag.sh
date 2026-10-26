#!/bin/bash
# Check that a release tag matches App/project.yml.
#   scripts/check-release-tag.sh mac-v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>
# Exits 0 and prints "<marketing> <build>" on a match; exits 1 otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
if [ -z "$TAG" ]; then
    echo "usage: $0 mac-v<marketing>-<build>   (e.g. mac-v1.0-19)" >&2
    exit 1
fi

RE='^mac-v([0-9]+(\.[0-9]+)*)-([0-9]+)$'
if [[ ! "$TAG" =~ $RE ]]; then
    echo "error: tag '$TAG' does not match mac-v<marketing>-<build> (e.g. mac-v1.0-19)" >&2
    exit 1
fi
TAG_MARKETING="${BASH_REMATCH[1]}"
TAG_BUILD="${BASH_REMATCH[3]}"

# First top-level-settings occurrence; the targets only reference the variables.
MARKETING=$(sed -nE 's/^[[:space:]]+MARKETING_VERSION:[[:space:]]*"?([0-9][0-9.]*)"?[[:space:]]*$/\1/p' App/project.yml | head -n1)
BUILD=$(sed -nE 's/^[[:space:]]+CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?[[:space:]]*$/\1/p' App/project.yml | head -n1)
if [ -z "$MARKETING" ] || [ -z "$BUILD" ]; then
    echo "error: could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from App/project.yml" >&2
    exit 1
fi

if [ "$TAG_MARKETING" != "$MARKETING" ] || [ "$TAG_BUILD" != "$BUILD" ]; then
    echo "error: tag '$TAG' says version $TAG_MARKETING build $TAG_BUILD, but App/project.yml has version $MARKETING build $BUILD (expected tag mac-v$MARKETING-$BUILD)" >&2
    exit 1
fi
echo "$MARKETING $BUILD"
