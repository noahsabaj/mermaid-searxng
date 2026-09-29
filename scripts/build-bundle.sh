#!/usr/bin/env bash
# Assemble a sovereign SearXNG bundle for one target: a portable CPython
# with SearXNG + Granian installed directly into it (no venv, so the tree stays
# relocatable), launched at runtime via `python -m granian`. Produces
# dist/mermaid-searxng-<TARGET>.tar.zst.
#
# Reproducibility: every input is pinned and verified (CPython asset sha256,
# SearXNG git commit, hash-locked requirements.lock), wheel-build metadata and
# tar mtimes are clamped to SOURCE_DATE_EPOCH, and the tarball is packed
# deterministically — the same tree on the same runner layout yields a
# byte-identical artifact (CI's repro-check job enforces this).
#
# Inputs (env):
#   TARGET      mermaid target string, e.g. linux-x86_64 / macos-aarch64 /
#               windows-x86_64
#   PBS_TRIPLE  python-build-standalone triple, e.g. x86_64-unknown-linux-gnu
# Pins are read from ../versions.env.
#
# Windows targets build under Git Bash on a Windows runner. python-build-standalone
# lays the interpreter out differently there (python/python.exe, python/Lib,
# python/Scripts), and native Windows tools need native paths, not MSYS ones.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$root/versions.env"
: "${TARGET:?set TARGET}"
: "${PBS_TRIPLE:?set PBS_TRIPLE}"
: "${SOURCE_DATE_EPOCH:?versions.env must set SOURCE_DATE_EPOCH}"
export SOURCE_DATE_EPOCH

# Fixed work dir, not mktemp: pip writes the interpreter's absolute path into
# console-script shebangs and dist-info metadata, so a stable path is part of
# byte-stable rebuilds. /work/ is gitignored.
work="$root/work"
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

# Deterministic packing needs GNU tar (--sort/--mtime/--owner); macOS ships
# bsdtar, so prefer gtar (brew install gnu-tar) when present.
tar_bin=tar
command -v gtar >/dev/null 2>&1 && tar_bin=gtar
"$tar_bin" --version 2>/dev/null | grep -q 'GNU tar' \
  || { echo "error: GNU tar is required for deterministic packing (macOS: brew install gnu-tar)" >&2; exit 1; }

windows=0
case "$TARGET" in windows-*) windows=1 ;; esac

# Paths handed to the native interpreter: MSYS converts argv but not every
# environment variable, so convert explicitly on Windows.
native() {
  if [ "$windows" = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

sha256_check() { # <expected-hex> <file>
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$1  $2" | sha256sum --check --status -
  else
    echo "$1  $2" | shasum -a 256 --check --status -
  fi
}

sha_var="CPYTHON_SHA256_${PBS_TRIPLE//-/_}"
cpy_sha="${!sha_var:-}"
[ -n "$cpy_sha" ] || { echo "error: ${sha_var} is not set in versions.env" >&2; exit 1; }
cpy_asset="cpython-${CPYTHON_VERSION}+${CPYTHON_TAG}-${PBS_TRIPLE}-install_only_stripped.tar.gz"
cpy_url="https://github.com/astral-sh/python-build-standalone/releases/download/${CPYTHON_TAG}/${cpy_asset}"

echo "==> portable CPython: ${cpy_asset}"
curl -fsSL -o "$work/cpython.tar.gz" "$cpy_url"
sha256_check "$cpy_sha" "$work/cpython.tar.gz" \
  || { echo "error: sha256 mismatch for ${cpy_asset} (expected ${cpy_sha})" >&2; exit 1; }
tar -C "$work" -xzf "$work/cpython.tar.gz"   # -> $work/python
if [ "$windows" = 1 ]; then
  py="$work/python/python.exe"
  pylib="$work/python/Lib"
else
  py="$work/python/bin/python3"
  pylib="$work/python/lib/python${CPYTHON_VERSION%.*}"
fi

echo "==> SearXNG @ ${SEARXNG_REF}"
# Fetch via git so the bytes are verified against the pinned commit hash by git
# itself — no trust in archive tarballs that GitHub may regenerate.
git init -q "$work/src"
# The source bytes must not depend on the runner's git config (Windows runners
# default to core.autocrlf=true).
git -C "$work/src" config core.autocrlf false
if [ "$windows" = 1 ]; then
  # A few deployment templates under utils/ have ':' in their names, which
  # Windows cannot create. Nothing under utils/ is packaged, so leave it out.
  git -C "$work/src" config core.sparseCheckout true
  printf '/*\n!/utils/\n' > "$work/src/.git/info/sparse-checkout"
fi
git -C "$work/src" fetch -q --depth 1 https://github.com/searxng/searxng "$SEARXNG_REF"
git -C "$work/src" checkout -q FETCH_HEAD

echo "==> install into the standalone interpreter (relocatable, no venv)"
# Deps come exclusively from the hash-pinned lock (which also pins the
# setuptools/wheel that the --no-build-isolation searx build uses); the bundled
# pip is already pinned via the CPython asset hash, so it is not upgraded.
"$py" -m pip install --disable-pip-version-check -q --require-hashes -r "$(native "$root/requirements.lock")"
# Freeze the SearXNG version from the checkout (commit date + hash — works in a
# shallow clone and is deterministic for a pinned commit), so the runtime never
# shells out to git. The GHA vars are unset because SearXNG would read them as
# *its own* repo and mis-attribute its source to mermaid-searxng.
(cd "$work/src" && env -u GITHUB_REPOSITORY -u GITHUB_REF_NAME "$py" -m searx.version freeze)
if [ "$windows" = 1 ]; then
  # SearXNG's only Unix-only import: valkeydb.py imports `pwd` at module level,
  # yet uses it solely to log who failed to reach a configured Valkey. mermaid
  # always runs with Valkey off, so that path never runs; make the import
  # optional (after the version freeze, so the frozen version stays clean).
  # Fails loudly if a SearXNG bump moves the line.
  "$py" -B - "$(native "$work/src/searx/valkeydb.py")" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "\nimport pwd\n"
new = "\ntry:\n    import pwd\nexcept ImportError:  # Windows (mermaid-searxng patch)\n    pwd = None\n"
if text.count(old) != 1:
    sys.exit(f"error: expected one top-level `import pwd` in {path}")
path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")
PY
fi
"$py" -m pip install --disable-pip-version-check -q --no-build-isolation --no-deps "$(native "$work/src")"

echo "==> prune (tests, Tcl/Tk, build-only tooling, console scripts, caches)"
rm -rf \
  "$pylib/test" "$pylib/tkinter" "$pylib/turtledemo" "$pylib/idlelib" \
  "$pylib/lib2to3" "$pylib/ensurepip" \
  "$pylib/site-packages/pip" "$pylib"/site-packages/pip-*.dist-info \
  "$pylib/site-packages/setuptools" "$pylib"/site-packages/setuptools-*.dist-info \
  "$pylib/site-packages/wheel" "$pylib"/site-packages/wheel-*.dist-info \
  "$pylib/site-packages/pkg_resources" "$pylib/site-packages/_distutils_hack" \
  "$pylib/site-packages/distutils-precedence.pth" \
  "$work/python/include" 2>/dev/null || true
if [ "$windows" = 1 ]; then
  # Scripts/ holds only pip-written console-script launchers (build path baked
  # in); the runtime launches `python.exe -m granian`.
  rm -rf \
    "$work/python/DLLs"/_tkinter* "$work/python/DLLs"/tcl*.dll "$work/python/DLLs"/tk*.dll \
    "$work/python/tcl" "$work/python/libs" "$work/python/Scripts" 2>/dev/null || true
else
  rm -rf \
    "$pylib"/lib-dynload/_tkinter* \
    "$work/python/share" "$work/python/lib/pkgconfig" \
    "$work/python/lib"/libtcl* "$work/python/lib"/libtk* \
    "$work/python/lib"/tcl* "$work/python/lib"/tk* \
    "$work/python/lib"/itcl* "$work/python/lib"/thread* 2>/dev/null || true
  # bin/ keeps only the interpreters: the runtime launches `python -m granian`,
  # and pip-written console scripts embed the build path in their shebangs.
  find "$work/python/bin" -mindepth 1 ! -name 'python3*' -delete
  rm -f "$work/python/bin"/python3*-config
fi
# direct_url.json embeds the build path.
find "$pylib/site-packages" -name 'direct_url.json' -delete 2>/dev/null || true
find "$work/python" -name '*.a' -delete 2>/dev/null || true
# Drop RECORD lines for files the prune removed: the deleted console scripts'
# entries carry hashes of shebangs that embedded the build path, which was the
# last machine-dependent byte in the tree. With them gone, the same tree built
# under any root path is byte-identical (toolchain versions being equal).
"$py" -B - "$(native "$pylib/site-packages")" <<'PY'
import csv, io, pathlib, sys

site = pathlib.Path(sys.argv[1])
for record in sorted(site.glob('*.dist-info/RECORD')):
    # Explicit utf-8 and no newline translation: Windows would otherwise read
    # cp1252 and write CRLF.
    with open(record, encoding='utf-8', newline='') as f:
        rows = list(csv.reader(f))
    kept = [r for r in rows if r and (site / r[0]).resolve().exists()]
    if len(kept) != len(rows):
        out = io.StringIO()
        csv.writer(out, lineterminator='\n').writerows(kept)
        with open(record, 'w', encoding='utf-8', newline='') as f:
            f.write(out.getvalue())
PY

echo "==> smoke test the pruned tree (import + a real granian boot)"
# No bytecode during the smoke: .pyc files embed source mtimes and which
# modules get compiled varies run to run — both would break byte-stable packs.
export PYTHONDONTWRITEBYTECODE=1
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
smoke_settings="$(native "$work/smoke-settings.yml")"
SEARXNG_SETTINGS_PATH="$smoke_settings" \
  "$py" -c "import granian, searx.webapp as w; assert hasattr(w, 'application'), 'missing searx.webapp:application'"
port="$("$py" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
SEARXNG_SETTINGS_PATH="$smoke_settings" \
  "$py" -m granian --interface wsgi --host 127.0.0.1 --port "$port" searx.webapp:application &
gpid=$!
# Granian runs its worker in a child process. On Windows a plain kill of the
# MSYS pid leaves that worker running (and holding files under $work), so kill
# the whole tree by its Windows pid, as mermaid itself does (taskkill /T).
stop_smoke() {
  if [ "$windows" = 1 ]; then
    local winpid
    winpid="$(cat "/proc/$gpid/winpid" 2>/dev/null || true)"
    [ -n "$winpid" ] && taskkill //F //T //PID "$winpid" >/dev/null 2>&1 || true
  fi
  kill "$gpid" 2>/dev/null || true
}
trap 'stop_smoke; rm -rf "$work"' EXIT
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${port}/healthz" && break
  kill -0 "$gpid" 2>/dev/null || { echo "error: granian exited during the smoke test" >&2; exit 1; }
  sleep 0.5
done
curl -fsS -o /dev/null "http://127.0.0.1:${port}/healthz" \
  || { echo "error: /healthz never came up" >&2; exit 1; }
# The homepage render walks jinja2 + babel — catches anything the prune broke.
curl -fsS -o /dev/null "http://127.0.0.1:${port}/" \
  || { echo "error: homepage render failed on the pruned tree" >&2; exit 1; }
stop_smoke
wait "$gpid" 2>/dev/null || true
trap 'rm -rf "$work"' EXIT

echo "==> pack dist/mermaid-searxng-${TARGET}.tar.zst (deterministic)"
# Last: drop every __pycache__ (pip's install-time bytecode embeds mtimes; the
# runtime regenerates it lazily in the unpacked, writable tree).
find "$work/python" -depth -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$root/dist"
LC_ALL=C "$tar_bin" --sort=name --numeric-owner --owner=0 --group=0 \
  --mtime="@${SOURCE_DATE_EPOCH}" -C "$work" -cf - python \
  | zstd -19 -T0 -q -f -o "$root/dist/mermaid-searxng-${TARGET}.tar.zst"
ls -lh "$root/dist/mermaid-searxng-${TARGET}.tar.zst"
