# mermaid-searxng

Prebuilt, self-contained [SearXNG](https://github.com/searxng/searxng) bundles for
[mermaid](https://github.com/noahsabaj/mermaid-cli)'s zero-config `web_search`.

Each bundle pairs a pinned SearXNG with a portable
[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
CPython and the [Granian](https://github.com/emmett-framework/granian) server,
installed directly into the interpreter tree (no venv, so it stays relocatable).
On the first managed `web_search`, mermaid downloads the sha256-verified bundle
for the host platform, unpacks it under its data dir, and runs:

```
<bundle>/python/bin/python3 -m granian --interface wsgi \
    --host 127.0.0.1 --port <port> searx.webapp:application
```

bound to loopback, with `SEARXNG_SETTINGS_PATH` pointing at mermaid's generated
`settings.yml` (JSON API on, bot limiter off, Valkey off). **No Docker, no
Podman, no VM.**

## Platforms

| Target | Runner | Asset |
| --- | --- | --- |
| linux-x86_64 | `ubuntu-latest` | `mermaid-searxng-linux-x86_64.tar.zst` |
| linux-aarch64 | `ubuntu-24.04-arm` | `mermaid-searxng-linux-aarch64.tar.zst` |
| macos-aarch64 | `macos-14` | `mermaid-searxng-macos-aarch64.tar.zst` |

No bundle is published for **Windows** (SearXNG imports Unix-only modules like
`pwd`, so it can't run on native Windows) or **Intel macOS** (feasible, but
GitHub's macos-13 runners are too scarce to build reliably). Those users point
`search_backend = "searxng"` at their own `searxng_url` (a WSL, Linux, or remote
instance), or set `OLLAMA_API_KEY`.

Each release also publishes a `SHA256SUMS` manifest.

## Reproducibility

Rebuilding a tag yields a byte-identical bundle (given the same runner image),
and CI enforces it: the `repro-check` job builds `linux-x86_64` twice and fails
the release on any difference. The inputs that make this hold:

- **CPython**: exact python-build-standalone asset, sha256-verified against the
  per-triple pins in [`versions.env`](versions.env).
- **SearXNG**: fetched via git at an exact commit — the hash *is* the content
  pin, verified by git itself.
- **Python deps**: installed with `pip --require-hashes` from
  [`requirements.lock`](requirements.lock), a universal (cross-platform) lock
  covering every transitive dependency. Regenerate it with
  `scripts/update-lock.sh` (needs [uv](https://docs.astral.sh/uv/)) after
  bumping `SEARXNG_REF` or `GRANIAN_VERSION`.
- **Timestamps & metadata**: wheel builds and tar mtimes are clamped to the
  `SOURCE_DATE_EPOCH` pin, and the tarball is packed with GNU tar's
  deterministic flags (`--sort=name`, fixed owner/group).

## Build locally

```sh
# reads pins from versions.env; needs GNU tar (macOS: brew install gnu-tar)
TARGET=linux-x86_64 PBS_TRIPLE=x86_64-unknown-linux-gnu bash scripts/build-bundle.sh
# -> dist/mermaid-searxng-linux-x86_64.tar.zst
```

## Releasing

Push a `vX.Y.Z` tag matching `BUNDLE_VERSION` in `versions.env`. CI builds all
three targets on native runners, verifies reproducibility, generates
`SHA256SUMS`, publishes a GitHub Release, and (once `BUMP_TOKEN` is set) opens a
PR against `mermaid-cli` pinning the new version + checksums — the same muscle
as mermaid's brew/scoop/winget bumps.

## License

MIT OR Apache-2.0, matching mermaid-cli. SearXNG is AGPL-3.0; bundles redistribute
it unmodified under that license.
