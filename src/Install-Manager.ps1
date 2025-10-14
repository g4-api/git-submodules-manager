<#
.SYNOPSIS
    Install/update the Git Package Manager as a git submodule and expose the tool under tools/GitPackageManager.ps1.

.DESCRIPTION
    This script must be run from the **main repository git root**.
    - Adds (or updates) the package manager repository as a submodule at a user-specified path (e.g., "submodules/git-package-manager").
    - Exposes the tool as tools/GitPackageManager.ps1 by creating a **relative symbolic link**
      to the manager script inside the submodule (e.g., "src/script.ps1").
    - Uses PowerShell's SymbolicLink so it works on Windows/Linux/macOS.
    - Stages .gitmodules, the submodule path, and tools/GitPackageManager.ps1 for commit.

.PARAMETER ManagerRepoUrl
    Git URL of the package manager repository to add as a submodule.

.PARAMETER SubmodulePath
    Target path (within the main repo) for the submodule (e.g., "submodules/git-package-manager").

.PARAMETER ManagerScriptPath
    Path to the manager's script **inside** the submodule repository (e.g., "src/script.ps1").
#>

[CmdletBinding()]
param(
    [Parameter()] [string] $ManagerRepoUrl    = "https://github.com/g4-api/git-submodules-manager.git",
    [Parameter()] [string] $SubmodulePath     = "submodules/git-package-manager",
    [Parameter()] [string] $ManagerScriptPath = "src/GitPackageManager.ps1"
)

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# Basic guard: ensure we are at a git repo root
if (-not (Test-Path ".git")) {
    Write-Error "This script must be run from your main repository git root ('.git' folder not found)."
    exit 1
}

# Resolve paths
$toolsDir = "tools"
$linkPath = Join-Path $toolsDir "GitPackageManager.ps1"
$target   = (Join-Path $SubmodulePath $ManagerScriptPath)
$subGit   = Join-Path $SubmodulePath ".git"

# Ensure submodule exists (idempotent)
if (-not (Test-Path $subGit)) {
    Write-Step "Adding submodule: $ManagerRepoUrl > $SubmodulePath"
    git submodule add $ManagerRepoUrl $SubmodulePath
} else {
    Write-Step "Submodule already present at '$SubmodulePath' — syncing URL and paths"
    try {
        $currentUrl = (git -C $SubmodulePath remote get-url origin 2>$null)
        if ($currentUrl -and $ManagerRepoUrl -and ($currentUrl -ne $ManagerRepoUrl)) {
            Write-Warning "Submodule origin URL differs:
  current: $currentUrl
  desired: $ManagerRepoUrl
  (Run: git -C `"$SubmodulePath`" remote set-url origin `"$ManagerRepoUrl`" if you want to change it.)"
        }
    } catch { }
}

Write-Step "Initializing/updating submodule"
git submodule sync -- $SubmodulePath
git submodule update --init --recursive -- $SubmodulePath

# Validate that the manager script exists inside the submodule
$absoluteTarget = Join-Path $SubmodulePath $ManagerScriptPath
if (-not (Test-Path $absoluteTarget)) {
    Write-Error "Manager script not found inside submodule: '$absoluteTarget'
Check your -ManagerScriptPath (e.g., 'src/script.ps1')."
    exit 1
}

# Ensure tools directory
if (-not (Test-Path $toolsDir)) {
    Write-Step "Creating '$toolsDir' directory"
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
}

# Create/refresh relative symlink tools/GitPackageManager.ps1 -> ../<SubmodulePath>/<ManagerScriptPath>
if (Test-Path $linkPath -PathType Any) {
    $isLink = $false
    try {
        $item = Get-Item -LiteralPath $linkPath -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $isLink = $true }
    } catch { }

    if ($isLink) {
        Write-Step "Removing existing link '$linkPath'"
        Remove-Item -LiteralPath $linkPath -Force
    } else {
        Write-Step "Removing existing file at '$linkPath' (not a link)"
        Remove-Item -LiteralPath $linkPath -Force
    }
}

Write-Step "Creating symbolic link: $linkPath > $target"
# NOTE:
# - On Windows this requires Admin OR Developer Mode.
# - On Linux/macOS this maps to ln -s.
New-Item -ItemType SymbolicLink -Path $linkPath -Target $target | Out-Null

# Stage for commit
Write-Step "Staging submodule, link, and .gitmodules"
git add .gitmodules $SubmodulePath $linkPath

Write-Host ""
Write-Host "Done. You can commit with:" -ForegroundColor Green
Write-Host "  git commit -m 'Install Git Package Manager submodule and expose tools/GitPackageManager.ps1'" -ForegroundColor Green
Write-Host ""
Write-Host "Notes:" -ForegroundColor DarkGray
Write-Host "* Run this script from the **root of your main git repository**." -ForegroundColor DarkGray
Write-Host "* Windows requires Developer Mode or Administrator privileges to create symlinks." -ForegroundColor DarkGray
Write-Host "* The symlink is relative, so it remains valid if the repo root moves (with submodules/ and tools/)." -ForegroundColor DarkGray
