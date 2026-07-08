# Assemble a sovereign SearXNG bundle for windows-x86_64: a portable CPython with
# SearXNG + Granian installed directly into it, launched at runtime via
# `python.exe -m granian`. Produces dist\mermaid-searxng-windows-x86_64.zip.
$ErrorActionPreference = "Stop"
function Assert-Ok($what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" } }

$root = (Resolve-Path "$PSScriptRoot\..").Path
# Read pins from versions.env into the environment.
Get-Content "$root\versions.env" | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        Set-Item -Path "env:$($Matches[1])" -Value $Matches[2].Trim()
    }
}
$TARGET = "windows-x86_64"
$PBS_TRIPLE = "x86_64-pc-windows-msvc"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $work | Out-Null

$asset = "cpython-$($env:CPYTHON_VERSION)+$($env:CPYTHON_TAG)-$PBS_TRIPLE-install_only.tar.gz"
$url = "https://github.com/astral-sh/python-build-standalone/releases/download/$($env:CPYTHON_TAG)/$asset"
Write-Host "==> portable CPython: $asset"
curl.exe -fsSL -o "$work\cpython.tar.gz" $url; Assert-Ok "download CPython"
tar.exe -C "$work" -xzf "$work\cpython.tar.gz"; Assert-Ok "extract CPython"   # -> $work\python (python.exe at root)
$py = "$work\python\python.exe"

Write-Host "==> SearXNG @ $($env:SEARXNG_REF)"
git clone --filter=blob:none --no-checkout https://github.com/searxng/searxng.git "$work\src"; Assert-Ok "clone searxng"
git -C "$work\src" checkout --detach $env:SEARXNG_REF; Assert-Ok "checkout searxng ref"

Write-Host "==> install into the standalone interpreter"
& $py -m pip install --disable-pip-version-check -q -U pip setuptools wheel; Assert-Ok "pip bootstrap"
& $py -m pip install --disable-pip-version-check -q -r "$work\src\requirements.txt"; Assert-Ok "pip requirements"
& $py -m pip install --disable-pip-version-check -q --no-build-isolation "$work\src"; Assert-Ok "pip searx"

Write-Host "==> smoke test: WSGI app imports"
& $py -c "import granian, searx.webapp as w; assert hasattr(w, 'application')"; Assert-Ok "smoke import"

Write-Host "==> prune"
$pylib = "$work\python\Lib"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    "$pylib\test", "$pylib\tkinter", "$pylib\turtledemo", "$pylib\idlelib", "$pylib\ensurepip"
Get-ChildItem -Path "$work\python" -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "==> pack dist\mermaid-searxng-$TARGET.zip"
New-Item -ItemType Directory -Force -Path "$root\dist" | Out-Null
$dest = "$root\dist\mermaid-searxng-$TARGET.zip"
if (Test-Path $dest) { Remove-Item $dest }
Push-Location $work
# 7z (present on GitHub windows runners) stores `python\...` at the archive root.
7z a -tzip -mx=9 "$dest" "python" | Out-Null; Assert-Ok "zip"
Pop-Location
Get-Item $dest | Select-Object Name, Length
