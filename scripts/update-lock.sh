#!/usr/bin/env bash
# Regenerate requirements.lock: the hash-pinned, cross-platform resolution of
# every Python package the bundle build installs (SearXNG's pinned deps and
# their transitives, Granian, plus setuptools/wheel for the source build of
# searx itself). Rerun after bumping SEARXNG_REF or GRANIAN_VERSION in
# versions.env, and commit the result.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$root/versions.env"

command -v uv >/dev/null 2>&1 \
  || { echo "error: uv is required (https://docs.astral.sh/uv/)" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> requirements.txt @ SearXNG ${SEARXNG_REF}"
curl -fsSL -o "$work/requirements.in" \
  "https://raw.githubusercontent.com/searxng/searxng/${SEARXNG_REF}/requirements.txt"
{
  echo ''
  echo '# -- appended by scripts/update-lock.sh (not in SearXNG requirements.txt) --'
  echo "granian==${GRANIAN_VERSION}"
  echo 'setuptools  # build-time: --no-build-isolation install of searx'
  echo 'wheel       # build-time: wheel build of searx'
} >> "$work/requirements.in"

echo "==> uv pip compile --universal --generate-hashes"
# --universal resolves for every platform at once (one lock for the linux and
# macos build legs); --python-version targets the bundled interpreter, not
# whatever python runs this script. Run from $work with a relative input path
# so the lock's "via" annotations don't embed a random temp dir.
(cd "$work" && uv pip compile --universal --generate-hashes \
  --python-version "${CPYTHON_VERSION%.*}" \
  --custom-compile-command "scripts/update-lock.sh" \
  -o "$root/requirements.lock" requirements.in)

echo "wrote $root/requirements.lock"
