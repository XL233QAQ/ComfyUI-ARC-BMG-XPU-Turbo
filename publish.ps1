# ARC BMG XPU Turbo - publish to GitHub without git.
#
# Uses only the GitHub REST API, so it works on a machine with no git and no
# gh CLI installed. Uploads every tracked file, creates the repository if it
# does not exist yet, and sets the description + topics.
#
# Usage:
#   $env:GITHUB_TOKEN = "ghp_xxxxxxxxxxxxxxxx"   # a PAT with the "repo" scope
#   powershell -ExecutionPolicy Bypass -File publish.ps1
#
#   # or pass it explicitly:
#   powershell -ExecutionPolicy Bypass -File publish.ps1 -Token ghp_xxx
#
# Optional:
#   -RepoName   name of the repository (default: ComfyUI-ARC-BMG-XPU-Turbo)
#   -Private    create it private instead of public
#   -DryRun     show what would be uploaded, change nothing
#   -Update     repository already exists; just update the files

[CmdletBinding()]
param(
    [string]$Token = "",
    [string]$RepoName = "ComfyUI-ARC-BMG-XPU-Turbo",
    [string]$Owner = "",
    [switch]$Private,
    [switch]$DryRun,
    [switch]$Update
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ApiBase = "https://api.github.com"

# Files that must never be uploaded.
$SkipDirs = @(".git", "wheels", "__pycache__", ".venv", "venv", "node_modules", "examples")
$SkipFiles = @(".DS_Store", "Thumbs.db", "desktop.ini")
$SkipExt = @(".pyc", ".pyo", ".log", ".tmp", ".bak", ".zip", ".whl")


function Write-Step($m) { Write-Host "[publish] $m" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "[publish] $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "[publish] $m" -ForegroundColor Yellow }
function Stop-WithError($m) {
    Write-Host "[publish] ERROR: $m" -ForegroundColor Red
    exit 1
}


function Invoke-GitHub {
    <#
      One place for every API call: sets the headers, converts non-2xx into a
      readable message, and returns the parsed body (or $null for 204).
      With -Throw the error is raised instead of exiting, so callers can keep
      going and report the failure themselves.
    #>
    param(
        [string]$Method = "GET",
        [string]$Path,
        $Body = $null,
        [switch]$Allow404,
        [switch]$Throw
    )
    $uri = if ($Path -match '^https?://') { $Path } else { "$ApiBase$Path" }
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent"           = "arc-turbo-publish"
    }
    $params = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $headers
        ContentType = "application/json; charset=utf-8"
    }
    if ($null -ne $Body) {
        $params["Body"] = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404 -and $Allow404) { return $null }
        $detail = ""
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $detail = $reader.ReadToEnd()
                $reader.Close()
            }
        }
        catch { }
        $msg = "$Method $Path failed (HTTP $status)`n  $detail"
        if ($Throw) { throw $msg }
        Stop-WithError $msg
    }
}


# ---------------------------------------------------------------------------
# 0) Token
# ---------------------------------------------------------------------------

if (-not $Token) { $Token = $env:GITHUB_TOKEN }
if (-not $Token) { $Token = $env:GH_TOKEN }

if (-not $Token -and -not $DryRun) {
    Write-Host ""
    Write-Host "  A GitHub token is required." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Create one at: https://github.com/settings/tokens/new"
    Write-Host "    - Note:  ARC BMG XPU Turbo"
    Write-Host "    - Scope: check  [x] repo   (the whole box)"
    Write-Host "    - Expiration: 7 days is fine, you only need it once"
    Write-Host ""
    Write-Host "  Then run either of:" -ForegroundColor Cyan
    Write-Host '    $env:GITHUB_TOKEN = "ghp_xxx"; .\publish.ps1'
    Write-Host '    .\publish.ps1 -Token ghp_xxx'
    Write-Host ""
    Write-Host "  (Or add -DryRun to preview the file list without a token.)"
    Write-Host ""
    exit 1
}

$script:Token = $Token

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   ARC BMG XPU Turbo - publish to GitHub" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1) Who are we, and where is the project?
# ---------------------------------------------------------------------------

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
if (-not (Test-Path (Join-Path $root "pyproject.toml"))) {
    Stop-WithError "run this from the project folder (pyproject.toml not found in $root)"
}
Write-Step "project folder:   $root"

if ($Token) {
    $me = Invoke-GitHub -Path "/user"
    if (-not $Owner) { $Owner = $me.login }
    Write-Step "authenticated as: $($me.login)"
}
elseif (-not $Owner) {
    # Dry run without a token: we cannot ask GitHub who we are, so the
    # placeholder stays visible in the preview instead of being guessed.
    $Owner = "YOUR_NAME"
    Write-Warn2 "no token: assuming owner '$Owner' for the preview"
}
Write-Step "repository:       $Owner/$RepoName"

# ---------------------------------------------------------------------------
# 2) Fill in the placeholders, so the published copy has real URLs
# ---------------------------------------------------------------------------

$placeholderFiles = @(
    "README.md",
    "install.ps1",
    "pyproject.toml"
)
$patched = 0
foreach ($name in $placeholderFiles) {
    $path = Join-Path $root $name
    if (-not (Test-Path $path)) { continue }
    $text = Get-Content -Path $path -Raw -Encoding UTF8
    if ($text -notmatch 'YOUR_NAME') { continue }
    $patched++
    if ($DryRun) {
        $count = ([regex]::Matches($text, 'YOUR_NAME')).Count
        Write-Warn2 "would replace $count x YOUR_NAME -> $Owner in $name"
        continue
    }
    $newText = $text -replace 'YOUR_NAME', $Owner
    if ($newText -ne $text) {
        [System.IO.File]::WriteAllText($path, $newText, (New-Object System.Text.UTF8Encoding $false))
        Write-Ok "replaced YOUR_NAME -> $Owner in $name"
    }
}
if ($patched -eq 0) { Write-Step "no YOUR_NAME placeholders left" }

# ---------------------------------------------------------------------------
# 3) Collect the file list
# ---------------------------------------------------------------------------

function Get-TrackedFiles($base) {
    $out = @()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($base)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in (Get-ChildItem -Path $dir -Force -ErrorAction SilentlyContinue)) {
            if ($item.PSIsContainer) {
                if ($SkipDirs -contains $item.Name) { continue }
                $stack.Push($item.FullName)
                continue
            }
            if ($SkipFiles -contains $item.Name) { continue }
            if ($SkipExt -contains $item.Extension.ToLower()) { continue }
            $rel = $item.FullName.Substring($base.Length).TrimStart('\', '/')
            $rel = $rel -replace '\\', '/'
            $out += [pscustomobject]@{ Rel = $rel; Full = $item.FullName; Size = $item.Length }
        }
    }
    return $out | Sort-Object Rel
}

$files = Get-TrackedFiles $root
Write-Step "$($files.Count) files to upload:"
foreach ($f in $files) {
    Write-Host ("           {0,-52} {1,9:N0} B" -f $f.Rel, $f.Size)
}
Write-Host ""

if ($DryRun) {
    Write-Warn2 "dry run: nothing was uploaded"
    exit 0
}

# ---------------------------------------------------------------------------
# 4) Create the repository if needed
# ---------------------------------------------------------------------------

$repoPath = "/repos/$Owner/$RepoName"
$existing = Invoke-GitHub -Path $repoPath -Allow404

if ($existing) {
    if (-not $Update) {
        Write-Warn2 "repository already exists: $($existing.html_url)"
        Write-Warn2 "re-run with -Update to push the current files into it"
        exit 0
    }
    Write-Ok "repository exists, updating files"
    $defaultBranch = $existing.default_branch
    if (-not $defaultBranch) { $defaultBranch = "main" }
}
else {
    Write-Step "creating repository ..."
    $payload = @{
        name        = $RepoName
        description = "Qwen-Image 2.1 on Intel Arc Battlemage (B390/B580/B570/B770): 4x faster T2I, 158s -> 27s with 3 reference images, runs 2.0MP where stock ComfyUI OOMs."
        private     = [bool]$Private
        has_issues  = $true
        has_wiki    = $false
        auto_init   = $true          # gives us an initial commit + default branch
    }
    $created = Invoke-GitHub -Method POST -Path "/user/repos" -Body $payload
    Write-Ok "created: $($created.html_url)"
    $defaultBranch = $created.default_branch
    if (-not $defaultBranch) { $defaultBranch = "main" }
    Start-Sleep -Seconds 2
}

# ---------------------------------------------------------------------------
# 5) Upload every file through the contents API
# ---------------------------------------------------------------------------

function Get-RemoteSha($relPath) {
    $escaped = ($relPath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $r = Invoke-GitHub -Path "$repoPath/contents/$escaped`?ref=$defaultBranch" -Allow404
    if ($r -and $r.sha) { return $r.sha }
    return $null
}

$uploaded = 0
$skipped = 0
$failed = @()

foreach ($f in $files) {
    $escaped = ($f.Rel -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $bytes = [System.IO.File]::ReadAllBytes($f.Full)
    $b64 = [System.Convert]::ToBase64String($bytes)
    $remoteSha = Get-RemoteSha $f.Rel

    $body = @{
        message = "Add $($f.Rel)"
        content = $b64
        branch  = $defaultBranch
    }
    if ($remoteSha) {
        $body["sha"] = $remoteSha
        $body["message"] = "Update $($f.Rel)"
    }

    try {
        Invoke-GitHub -Method PUT -Path "$repoPath/contents/$escaped" -Body $body | Out-Null
        $uploaded++
        Write-Host ("  OK   {0}" -f $f.Rel) -ForegroundColor DarkGray
    }
    catch {
        $failed += $f.Rel
        Write-Warn2 "FAIL $($f.Rel): $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Ok "uploaded/updated $uploaded files, $($failed.Count) failed"
if ($failed.Count -gt 0) {
    Write-Warn2 "failed: $($failed -join ', ')"
}

# ---------------------------------------------------------------------------
# 6) Polish the repository page
# ---------------------------------------------------------------------------

Write-Step "setting description and topics ..."
try {
    Invoke-GitHub -Method PATCH -Path $repoPath -Body @{
        description = "Qwen-Image 2.1 on Intel Arc Battlemage (B390/B580/B570/B770): 4x faster T2I, 158s -> 27s with 3 reference images, runs 2.0MP where stock ComfyUI OOMs."
        homepage    = ""
    } | Out-Null
    Invoke-GitHub -Method PUT -Path "$repoPath/topics" -Body @{
        names = @(
            "comfyui", "intel-arc", "battlemage", "xpu", "int8",
            "qwen-image", "text-to-image", "windows", "pytorch", "comfyui-custom-node"
        )
    } | Out-Null
    Write-Ok "description and topics set"
}
catch {
    Write-Warn2 "could not set description/topics (harmless): $($_.Exception.Message)"
}

$repoUrl = if ($existing) { $existing.html_url } else { $created.html_url }
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Green
Write-Host "   Done" -ForegroundColor Green
Write-Host "  ============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  $repoUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Remaining manual steps:" -ForegroundColor Yellow
Write-Host "    1. Replace YOUR_NAME in README.md and pyproject.toml, then re-run with -Update"
Write-Host "    2. Add a repository social preview image (Settings -> Social preview)"
Write-Host "    3. Publish to the Comfy Registry:"
Write-Host "         pip install comfy-cli"
Write-Host "         comfy node publish --token <API_KEY>"
Write-Host ""
