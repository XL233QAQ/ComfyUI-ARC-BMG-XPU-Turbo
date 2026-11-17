# ARC BMG XPU Turbo - one-click bootstrap for Windows.
#
# Gets the repository onto disk without requiring git, then hands over to
# install.py. Designed to be run straight from a browser download or with:
#
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# Nothing here needs administrator rights.

[CmdletBinding()]
param(
    [string]$TargetDir = "",
    [switch]$DryRun,
    [switch]$SkipTorch,
    [switch]$NoDownload
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Where the repository lives. Change this if you fork the project.
$RepoSlug = "XL233QAQ/ComfyUI-ARC-BMG-XPU-Turbo"
$RepoName = "ComfyUI-ARC-BMG-XPU-Turbo"
$Branch = "main"

# github.com is slow or blocked in some regions; try the mirrors in order.
$Proxies = @("", "https://gh-proxy.com/", "https://ghfast.top/")


function Write-Step($msg) { Write-Host "[ARC-Turbo] $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "[ARC-Turbo] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[ARC-Turbo] $msg" -ForegroundColor Yellow }
function Stop-WithError($msg) {
    Write-Host "[ARC-Turbo] ERROR: $msg" -ForegroundColor Red
    exit 1
}


function Find-ComfyRoot {
    <#
      Locate a ComfyUI install. Checks, in order:
        1. $env:COMFYUI_PATH
        2. this script's own folder and its parents (works when already inside custom_nodes)
        3. Comfy Desktop's install directories
    #>
    if ($env:COMFYUI_PATH) {
        if (Test-Path (Join-Path $env:COMFYUI_PATH "main.py")) {
            return (Resolve-Path $env:COMFYUI_PATH).Path
        }
    }

    $here = $PSScriptRoot
    if (-not $here) { $here = (Get-Location).Path }
    $probe = $here
    while ($probe) {
        if ((Test-Path (Join-Path $probe "main.py")) -and (Test-Path (Join-Path $probe "comfy"))) {
            return $probe
        }
        $parent = Split-Path $probe -Parent
        if ($parent -eq $probe -or -not $parent) { break }
        $probe = $parent
    }

    $local = $env:LOCALAPPDATA
    if ($local) {
        $patterns = @(
            (Join-Path $local "Comfy-Desktop\ComfyUI-Installs\*\ComfyUI"),
            (Join-Path $local "Programs\@comfyorgcomfyui-electron\resources\ComfyUI")
        )
        foreach ($pattern in $patterns) {
            foreach ($cand in (Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path (Join-Path $cand.FullName "main.py")) {
                    return $cand.FullName
                }
            }
        }
    }

    return $null
}


function Get-RepoArchive($destZip) {
    <#
      Download the branch archive. Falls back through the proxy list so users
      behind a flaky connection still get through.
    #>
    $path = "$RepoSlug/archive/refs/heads/$Branch.zip"
    $lastError = $null
    foreach ($proxy in $Proxies) {
        $url = "${proxy}https://github.com/$path"
        $label = if ($proxy) { "mirror $proxy" } else { "github.com" }
        Write-Step "downloading repository via $label ..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $destZip -UseBasicParsing -TimeoutSec 300
            if ((Get-Item $destZip).Length -gt 1024) {
                Write-Ok "downloaded $([math]::Round((Get-Item $destZip).Length / 1MB, 2)) MB"
                return $true
            }
            Write-Warn2 "file too small, trying next source"
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Warn2 "failed: $lastError"
        }
    }
    return $false
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   ARC BMG XPU Turbo - one-click installer" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Stop-WithError "this installer targets Windows; Linux needs the manual steps in README.md"
}

# 1) Where does the repo go?
$comfyRoot = Find-ComfyRoot
if ($TargetDir) {
    $repoRoot = $TargetDir
}
elseif ($comfyRoot) {
    $repoRoot = Join-Path $comfyRoot "custom_nodes\$RepoName"
}
else {
    $repoRoot = Join-Path (Get-Location).Path $RepoName
}

# If we are already sitting in the repo (script run from a checkout), just use it.
$scriptDir = $PSScriptRoot
if ($scriptDir -and (Test-Path (Join-Path $scriptDir "install.py")) -and (Test-Path (Join-Path $scriptDir "pyproject.toml"))) {
    $repoRoot = $scriptDir
    Write-Ok "using the existing checkout at $repoRoot"
}
elseif (Test-Path (Join-Path $repoRoot "install.py")) {
    Write-Ok "repository already present at $repoRoot"
}
else {
    Write-Step "repository will be placed at $repoRoot"

    $parent = Split-Path $repoRoot -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $tmpZip = Join-Path $env:TEMP "arc-turbo-$([guid]::NewGuid().ToString('N').Substring(0,8)).zip"
    if (-not (Get-RepoArchive $tmpZip)) {
        Stop-WithError @"
could not download the repository from any source.
  Download it manually: https://github.com/$RepoSlug/archive/refs/heads/$Branch.zip
  Extract it so that install.py sits at: $repoRoot
  Then re-run this script.
"@
    }

    Write-Step "extracting ..."
    $tmpDir = Join-Path $env:TEMP "arc-turbo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
        $inner = Get-ChildItem -Path $tmpDir -Directory | Select-Object -First 1
        if (-not $inner) { Stop-WithError "the downloaded archive was empty" }
        if (Test-Path $repoRoot) { Remove-Item $repoRoot -Recurse -Force }
        Move-Item -Path $inner.FullName -Destination $repoRoot
        Write-Ok "extracted to $repoRoot"
    }
    finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 2) Find a Python to run install.py with. It only needs 3.8+, because the
#    version that actually matters is inside ComfyUI's venv and install.py
#    checks that itself.
$python = $null
$candidates = @()
if ($comfyRoot) {
    $candidates += (Join-Path $comfyRoot ".venv\Scripts\python.exe")
}
$candidates += @(
    (Join-Path $repoRoot ".venv\Scripts\python.exe"),
    "python",
    "py"
)
foreach ($cand in $candidates) {
    if (-not $cand) { continue }
    if ($cand -eq "python" -or $cand -eq "py") {
        $found = Get-Command $cand -ErrorAction SilentlyContinue
        if ($found) { $python = $found.Source; break }
    }
    elseif (Test-Path $cand) {
        $python = $cand
        break
    }
}
if (-not $python) {
    Stop-WithError @"
no Python found. Install one of:
  - ComfyUI Desktop (bundles its own Python 3.13), or
  - Python 3.13 from https://www.python.org/downloads/
"@
}
Write-Step "using python: $python"

# 3) Hand over to install.py.
$installArgs = @((Join-Path $repoRoot "install.py"))
if ($DryRun) { $installArgs += "--dry-run" }
if ($SkipTorch) { $installArgs += "--skip-torch" }
if ($NoDownload) { $installArgs += "--no-download" }

Write-Host ""
& $python @installArgs
$code = $LASTEXITCODE
Write-Host ""

if ($code -eq 0) {
    Write-Ok "all done."
    Write-Host ""
    Write-Host "  Next:" -ForegroundColor Cyan
    Write-Host "    1. Restart ComfyUI (close it completely, then start it again)"
    Write-Host "    2. Open the workflow: Qwen-Image-2.1-MultiRef-BMG-XPU"
    Write-Host "    3. Run it once and look at the 'OmniXPU status' node:"
    Write-Host "       it should say  Attention calls: cute=... torch=0"
    Write-Host ""
}
else {
    Write-Warn2 "install.py exited with code $code - see the messages above."
}

exit $code
