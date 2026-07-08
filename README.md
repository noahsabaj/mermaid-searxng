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
| macos-x86_64 | `macos-13` | `mermaid-searxng-macos-x86_64.tar.zst` |
| macos-aarch64 | `macos-14` | `mermaid-searxng-macos-aarch64.tar.zst` |
| windows-x86_64 | `windows-latest` | `mermaid-searxng-windows-x86_64.zip` |

Each release also publishes a `SHA256SUMS` manifest. Every input is pinned in
[`versions.env`](versions.env) so a rebuild of a tag is reproducible.

## Build locally

```sh
# unix (reads pins from versions.env)
TARGET=linux-x86_64 PBS_TRIPLE=x86_64-unknown-linux-gnu bash scripts/build-bundle.sh
# -> dist/mermaid-searxng-linux-x86_64.tar.zst
```

```powershell
# windows
pwsh scripts/build-bundle.ps1
# -> dist\mermaid-searxng-windows-x86_64.zip
```

## Releasing

Push a `vX.Y.Z` tag matching `BUNDLE_VERSION` in `versions.env`. CI builds all
five targets on native runners, generates `SHA256SUMS`, publishes a GitHub
Release, and (once `BUMP_TOKEN` is set) opens a PR against `mermaid-cli` pinning
the new version + checksums — the same muscle as mermaid's brew/scoop/winget
bumps.

## License

MIT OR Apache-2.0, matching mermaid-cli. SearXNG is AGPL-3.0; bundles redistribute
it unmodified under that license.
