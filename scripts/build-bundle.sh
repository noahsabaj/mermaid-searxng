#!/usr/bin/env bash
# Assemble a sovereign SearXNG bundle for one unix target: a portable CPython
# with SearXNG + Granian installed directly into it (no venv, so the tree stays
# relocatable), launched at runtime via `python -m granian`. Produces
# dist/mermaid-searxng-<TARGET>.tar.zst.
#
# Inputs (env):
#   TARGET      mermaid target string, e.g. linux-x86_64 / macos-aarch64
#   PBS_TRIPLE  python-build-standalone triple, e.g. x86_64-unknown-linux-gnu
# Pins are read from ../versions.env.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$root/versions.env"
: "${TARGET:?set TARGET}"
: "${PBS_TRIPLE:?set PBS_TRIPLE}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cpy_asset="cpython-${CPYTHON_VERSION}+${CPYTHON_TAG}-${PBS_TRIPLE}-install_only.tar.gz"
cpy_url="https://github.com/astral-sh/python-build-standalone/releases/download/${CPYTHON_TAG}/${cpy_asset}"

echo "==> portable CPython: ${cpy_asset}"
curl -fsSL -o "$work/cpython.tar.gz" "$cpy_url"
tar -C "$work" -xzf "$work/cpython.tar.gz"   # -> $work/python
py="$work/python/bin/python3"

echo "==> SearXNG @ ${SEARXNG_REF}"
# Fetch the source as a tarball and extract everything except utils/, which holds
# upstream paths containing ':' (e.g. searxng.conf:socket) that Windows/NTFS
# cannot create. `pip install .` needs searx/ + the root build files, not the
# utils/ deployment templates. (git checkout of those paths fails on Windows.)
mkdir -p "$work/src"
curl -fsSL -o "$work/searxng-src.tar.gz" \
  "https://codeload.github.com/searxng/searxng/tar.gz/${SEARXNG_REF}"
tar -C "$work/src" --strip-components=1 -xzf "$work/searxng-src.tar.gz" --exclude='*/utils/*'

echo "==> install into the standalone interpreter (relocatable, no venv)"
"$py" -m pip install --disable-pip-version-check -q -U pip setuptools wheel
"$py" -m pip install --disable-pip-version-check -q -r "$work/src/requirements.txt"
"$py" -m pip install --disable-pip-version-check -q "granian==${GRANIAN_VERSION}"
"$py" -m pip install --disable-pip-version-check -q --no-build-isolation "$work/src"

echo "==> smoke test: WSGI app imports (SearXNG refuses to load with the default secret_key)"
cat > "$work/smoke-settings.yml" <<'YAML'
use_default_settings: true
server:
  secret_key: "build-smoke-test-not-shipped"
  limiter: false
search:
  formats:
    - html
    - json
valkey:
  url: false
YAML
SEARXNG_SETTINGS_PATH="$work/smoke-settings.yml" \
  "$py" -c "import granian, searx.webapp as w; assert hasattr(w, 'application'), 'missing searx.webapp:application'"

echo "==> prune (test suite, GUI, build-only tools, static libs, caches)"
pylib="$work/python/lib/python${CPYTHON_VERSION%.*}"
rm -rf \
  "$pylib/test" "$pylib/tkinter" "$pylib/turtledemo" "$pylib/idlelib" \
  "$pylib/lib2to3" "$pylib/ensurepip" "$pylib/site-packages/pip" \
  "$pylib"/site-packages/pip-*.dist-info \
  "$work/python/include" "$work/python/share" 2>/dev/null || true
find "$work/python" -name '*.a' -delete 2>/dev/null || true
find "$work/python" -depth -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

echo "==> pack dist/mermaid-searxng-${TARGET}.tar.zst"
mkdir -p "$root/dist"
tar -C "$work" -cf - python | zstd -19 -T0 -q -o "$root/dist/mermaid-searxng-${TARGET}.tar.zst"
ls -lh "$root/dist/mermaid-searxng-${TARGET}.tar.zst"
