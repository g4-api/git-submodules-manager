#!/usr/bin/env pwsh
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('Install', 'Restore', 'Update', 'Remove', 'Help')]
    [string]$Command = 'Install',

    [string]$Name,

    [string]$ManifestPath = "./config-specification.json",

    [string]$LockPath = "./config-specification.lock.json"
)

$ErrorActionPreference = 'Continue'

function Copy-Files {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Module
    )

    $m = $Module

    if (
        [string]::IsNullOrWhiteSpace($m.binaryPath) -or
        [string]::IsNullOrWhiteSpace($m.binaryLocalPath)
    ) {
        return   # skip binary handling
    }
    
    # Resolve module root (submodule vs normal clone)
    $moduleRoot = if ([bool]$m.submodule) {
        Get-Submodule-Path -RepoRoot $repoRoot -RelPath $m.name
    }
    else {
        Join-Path -Path (Get-Location) -ChildPath $m.name
    }
    
    $src = Join-Path $moduleRoot $m.binaryPath
    $dst = Join-Path (Get-Location) $m.binaryLocalPath
    
    if (-not (Test-Path $src -PathType Leaf)) {
        Write-Host "Binary not found for '$($m.name)': $src" -ForegroundColor Yellow
        continue
    }
    
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path $dstDir)) {
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    }
    
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "Copied binary for '$($m.name)': $($m.binaryPath) -> $($m.binaryLocalPath)" -ForegroundColor Green
}

function Is-Submodule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][string]$RelPath
    )
    $res = Try-Git -WorkingDirectory $RepoRoot -Args @('submodule','status','--', $RelPath)
    return ($res.code -eq 0)
}

function Ensure-Submodule {
    <#
      Ensures a submodule exists at RepoRoot\RelPath and points to Repo URL.
      If not present, runs: git submodule add <repo> <RelPath>
      Always runs: git submodule update --init --recursive -- <RelPath>
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][string]$RelPath,
        [Parameter(Mandatory=$true)][string]$Repo
    )

    if (-not (Is-Submodule -RepoRoot $RepoRoot -RelPath $RelPath)) {
        Write-Host "Adding submodule '$RelPath' from $Repo" -ForegroundColor Cyan
        $r = Try-Git -WorkingDirectory $RepoRoot -Args @('submodule','add','--force', $Repo, $RelPath)
        if ($r.code -ne 0) { throw "Failed to add submodule $RelPath ($Repo)." }
    }

    $r2 = Try-Git -WorkingDirectory $RepoRoot -Args @('submodule','update','--init','--recursive','--', $RelPath)
    if ($r2.code -ne 0) { throw "Failed to init/update submodule $RelPath." }
}

function Get-RepoRoot {
    # Superproject root (assumes you run script from repo root)
    return (Get-Location).Path
}

function Get-Submodule-Path {
    param([Parameter(Mandatory=$true)][string]$RepoRoot,
          [Parameter(Mandatory=$true)][string]$RelPath)
    return (Join-Path $RepoRoot $RelPath)
}

function Invoke-Git {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory
    )

    if (-not (Test-Path $WorkingDirectory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $WorkingDirectory | Out-Null
    }

    Write-Host ">> git $($Args -join ' ') (in '$WorkingDirectory')" -ForegroundColor DarkCyan

    Push-Location $WorkingDirectory
    try {
        # Route stderr to stdout so PowerShell doesn't treat it as an error,
        # then check $LASTEXITCODE to decide success/failure ourselves.
        $output = & git @Args 2>&1
        $exit = $LASTEXITCODE

        if ($null -ne $output) { $output | ForEach-Object { Write-Host $_ } }

        if ($exit -ne 0) {
            throw "git exited with code $exit for: git $($Args -join ' ')"
        }

        return $output
    }
    finally {
        Pop-Location
    }
}

function Try-Git {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory
    )
    Push-Location $WorkingDirectory
    try {
        $out = & git @Args 2>$null
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return @{ code = $code; out = $out }
}

function Read-Manifest {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json
}

function Read-Lock {
    [CmdletBinding()]
    param(
        [string]$Path
    )
    
    if (Test-Path $Path) {
        (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json
    }
    else {
        [pscustomobject]@{ modules = @() }
    }
}

function Write-Lock {
    [CmdletBinding()]
    param(
        $Lock,
        [string]$Path
    )

    $Lock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Update-LockEntry {
    [CmdletBinding()]
    param(
        $Lock,
        [string]$ModuleName,
        [string]$Repo,
        [string]$TargetDir,
        [string]$LocalPath,
        [string]$ResolvedCommit
    )

    $existing = $Lock.modules | Where-Object { $_.name -eq $ModuleName } | Select-Object -First 1
    
    if ($existing) {
        $existing.repo = $Repo
        $existing.targetDir = $TargetDir
        $existing.localPath = $LocalPath
        $existing.resolvedCommit = $ResolvedCommit
        $existing.updatedAtUtc = (Get-Date).ToUniversalTime().ToString("s") + "Z"
    }
    else {
        $Lock.modules += [pscustomobject]@{
            name           = $ModuleName
            repo           = $Repo
            targetDir      = $TargetDir
            localPath      = $LocalPath
            resolvedCommit = $ResolvedCommit
            updatedAtUtc   = (Get-Date).ToUniversalTime().ToString("s") + "Z"
        }
    }
}

function Ensure-Clone-And-Fetch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$TargetDir
    )

    if (-not (Test-Path (Join-Path $TargetDir ".git"))) {
        $parent = Split-Path -Parent $TargetDir
        
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        
        Write-Host "Cloning $Repo -> $TargetDir (no checkout)"
        
        & git clone --no-checkout $Repo $TargetDir | Out-Null
    }
    else {
        Write-Host "Repository exists at $TargetDir" -ForegroundColor DarkGray
    }

    Invoke-Git -WorkingDirectory $TargetDir -Args @('fetch','--all','--tags','--prune')
}

function Ensure-Sparse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [Parameter(Mandatory = $true)][string]$RepoRelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RepoRelativePath) -or $RepoRelativePath -eq '.' -or $RepoRelativePath -eq './') {
        Invoke-Git -WorkingDirectory $TargetDir -Args @('sparse-checkout','init','--cone')
        Invoke-Git -WorkingDirectory $TargetDir -Args @('sparse-checkout','set','.')
    }
    else {
        Invoke-Git -WorkingDirectory $TargetDir -Args @('sparse-checkout', 'init', '--cone')
        # Normalize to forward slashes; git sparse-checkout expects Unix-like paths
        $p = $RepoRelativePath -replace '\\', '/'
        Invoke-Git -WorkingDirectory $TargetDir -Args @('sparse-checkout','set', $p)
    }
}

function Resolve-Desired-Ref {
    [CmdletBinding()]
    param(
        [string]$Version,
        [string]$Tag,
        [Parameter(Mandatory = $true)][string]$TargetDir
    )

    if ($Version -and $Version.Trim().Length -gt 0) {
        return $Version.Trim()
    }
    if ($Tag -and $Tag.Trim().Length -gt 0) {
        return "refs/tags/$($Tag.Trim())"
    }

    # Derive default branch from origin/HEAD
    $headRef = (Invoke-Git -WorkingDirectory $TargetDir -Args @('rev-parse', '--abbrev-ref', 'origin/HEAD')) 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $headRef) {
        # Fallback (rare): parse remote show origin
        $remoteInfo = Invoke-Git -WorkingDirectory $TargetDir -Args @('remote', 'show', 'origin')
        $line = $remoteInfo | Where-Object { $_ -match 'HEAD branch:' } | Select-Object -First 1
        if ($line) {
            $branch = ($line -split 'HEAD branch:\s*')[1].Trim()
            return "origin/$branch"
        }

        # Last resort: main, then master
        return "origin/main"
    }
    else {
        # origin/HEAD often returns e.g. "origin/main"
        return $headRef.Trim()
    }
}

function Checkout-Ref {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [Parameter(Mandatory = $true)][string]$RefToCheckout
    )

    Invoke-Git -WorkingDirectory $TargetDir -Args @('checkout','--detach') | Out-Null
    Invoke-Git -WorkingDirectory $TargetDir -Args @('checkout', $RefToCheckout)
}

function Resolve-HEAD {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )
    
    $sha = Invoke-Git -WorkingDirectory $TargetDir -Args @('rev-parse','HEAD')
    
    return $sha.Trim()
}

function Ensure-Submodules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir,
        [bool]$Enable
    )

    if ($Enable) {
        Invoke-Git -WorkingDirectory $TargetDir -Args @('submodule','update','--init','--recursive')
    }
}

function Ensure-Commit-Available {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TargetDir,
        [Parameter(Mandatory=$true)][string]$Commit
    )

    $exists = Invoke-Git -WorkingDirectory $TargetDir -Args @('cat-file','-e',"$Commit^{commit}") 2>$null
    if ($LASTEXITCODE -eq 0) { return }

    Invoke-Git -WorkingDirectory $TargetDir -Args @('fetch','--all','--tags','--prune')

    $exists = Invoke-Git -WorkingDirectory $TargetDir -Args @('cat-file','-e',"$Commit^{commit}") 2>$null
    if ($LASTEXITCODE -eq 0) { return }

    Invoke-Git -WorkingDirectory $TargetDir -Args @('fetch','origin','+refs/*:refs/remotes/origin/*')

    $exists = Invoke-Git -WorkingDirectory $TargetDir -Args @('cat-file','-e',"$Commit^{commit}") 2>$null
    if ($LASTEXITCODE -eq 0) { return }

    throw "Commit $Commit not found in $TargetDir even after fetch. Verify the lockfile SHA belongs to this repo."
}

function Ensure-Full-Fetch {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$TargetDir)

    if (Test-Path (Join-Path $TargetDir ".git/shallow")) {
        # Get full history
        $null = Try-Git -WorkingDirectory $TargetDir -Args @('fetch','--unshallow','--prune')
    }

    # Mirror all branches and tags locally; prune stale
    $null = Try-Git -WorkingDirectory $TargetDir -Args @('fetch','origin','+refs/heads/*:refs/remotes/origin/*','--prune')
    $null = Try-Git -WorkingDirectory $TargetDir -Args @('fetch','origin','--tags','--prune')

    # Make origin/HEAD sane for default-branch discovery (no-op if unchanged)
    $null = Try-Git -WorkingDirectory $TargetDir -Args @('remote','set-head','origin','-a')
}

function Resolve-Commit {
    <#
      Input: $Ref can be full SHA, short SHA, branch, origin/<branch>, or tag
      Output: full 40-char commit SHA
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TargetDir,
        [Parameter(Mandatory=$true)][string]$Ref
    )

    Ensure-Full-Fetch -TargetDir $TargetDir

    function _tryParse([string]$r) {
        if ([string]::IsNullOrWhiteSpace($r)) { return $null }
        $rp = Try-Git -WorkingDirectory $TargetDir -Args @('rev-parse','--verify','--quiet',"$r^{commit}")
        if ($rp.code -eq 0 -and $rp.out) { return ($rp.out | Select-Object -First 1).Trim() }
        return $null
    }

    # 1) As provided
    $sha = _tryParse $Ref
    if ($sha) { return $sha }

    # 2) origin/<branch>
    $sha = _tryParse ("origin/$Ref")
    if ($sha) { return $sha }

    # 3) refs/tags/<tag>
    $sha = _tryParse ("refs/tags/$Ref")
    if ($sha) { return $sha }

    # 4) Abbrev SHA expansion: search all commits and expand deterministically
    if ($Ref -match '^[0-9a-fA-F]{4,39}$') {
        $all = Try-Git -WorkingDirectory $TargetDir -Args @('rev-list','--all')
        if ($all.code -eq 0 -and $all.out) {
            $candidates = @($all.out | Where-Object { $_ -like "$Ref*" })
            if ($candidates.Count -eq 1) {
                return $candidates[0].Trim()
            } elseif ($candidates.Count -gt 1) {
                throw "Reference '$Ref' is ambiguous ($($candidates.Count) matches). Use a longer prefix or full SHA."
            }
        }
    }

    throw "Cannot resolve ref '$Ref' to a commit in '$TargetDir' (after full fetch). Verify the ref/SHA and repository."
}

function Remove-DirectorySafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    if (Test-Path $Path) {
        Write-Host "Removing '$Path'..." -ForegroundColor Yellow
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Invoke-Install {
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$LockPath,
        [string]$Name
    )

    $manifest = Read-Manifest -Path $ManifestPath
    $lock = Read-Lock -Path $LockPath
    $repoRoot = Get-RepoRoot

    foreach ($m in $manifest.modules) {
        if ($Name -and $m.name -ne $Name) { continue }

        if ([bool]$m.submodule) {
            $relPath   = $m.name
            $subPath   = Get-Submodule-Path -RepoRoot $repoRoot -RelPath $relPath

            Ensure-Submodule -RepoRoot $repoRoot -RelPath $relPath -Repo $m.repo
            Ensure-Full-Fetch -TargetDir $subPath

            $ref    = Resolve-Desired-Ref -Version $m.version -Tag $m.tag -TargetDir $subPath
            $commit = Resolve-Commit     -TargetDir $subPath -Ref $ref

            Invoke-Git -WorkingDirectory $subPath -Args @('checkout','--detach') | Out-Null
            Invoke-Git -WorkingDirectory $subPath -Args @('-c','advice.detachedHead=false','checkout',$commit)

            Ensure-Submodules -TargetDir $subPath -Enable $true

            Update-LockEntry -Lock $lock -ModuleName $m.name -Repo $m.repo -TargetDir $subPath -LocalPath '.' -ResolvedCommit $commit
            Write-Lock -Lock $lock -Path $LockPath

            Write-Host "Installed submodule '$($m.name)' at $commit" -ForegroundColor Green
        }
        else {
            $targetDir = Join-Path -Path (Get-Location) -ChildPath $m.name

            Ensure-Clone-And-Fetch -Repo $m.repo -TargetDir $targetDir
            Ensure-Sparse -TargetDir $targetDir -RepoRelativePath $m.localPath

            $ref    = Resolve-Desired-Ref -Version $m.version -Tag $m.tag -TargetDir $targetDir
            $commit = Resolve-Commit     -TargetDir $targetDir -Ref $ref

            Invoke-Git -WorkingDirectory $targetDir -Args @('checkout','--detach') | Out-Null
            Invoke-Git -WorkingDirectory $targetDir -Args @('-c','advice.detachedHead=false','checkout',$commit)

            Ensure-Submodules -TargetDir $targetDir -Enable ([bool]$m.submodule)

            Update-LockEntry -Lock $lock -ModuleName $m.name -Repo $m.repo -TargetDir $targetDir -LocalPath $m.localPath -ResolvedCommit $commit
            Write-Lock -Lock $lock -Path $LockPath

            Write-Host "Installed '$($m.name)' at $commit" -ForegroundColor Green
        }

        # Handle binary files
        Copy-Files -Module $m
    }

    Write-Host "Install completed." -ForegroundColor Green
}

function Invoke-Restore {
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$LockPath,
        [string]$Name
    )

    $manifest = Read-Manifest -Path $ManifestPath
    $lock     = Read-Lock    -Path $LockPath
    $repoRoot = Get-RepoRoot

    foreach ($lm in $lock.modules) {
        if ($Name -and $lm.name -ne $Name) { continue }

        $m = $manifest.modules | Where-Object { $_.name -eq $lm.name } | Select-Object -First 1
        if (-not $m) { throw "Module '$($lm.name)' not found in manifest." }
        if (-not $lm.resolvedCommit) { throw "Lockfile missing resolvedCommit for '$($lm.name)'." }

        if ([bool]$m.submodule) {
            $relPath = $m.name
            $subPath = Get-Submodule-Path -RepoRoot $repoRoot -RelPath $relPath

            Ensure-Submodule  -RepoRoot $repoRoot -RelPath $relPath -Repo $m.repo
            Ensure-Full-Fetch -TargetDir $subPath

            $commit = Resolve-Commit -TargetDir $subPath -Ref $lm.resolvedCommit

            Invoke-Git -WorkingDirectory $subPath -Args @('checkout','--detach') | Out-Null
            Invoke-Git -WorkingDirectory $subPath -Args @('-c','advice.detachedHead=false','checkout',$commit)

            Ensure-Submodules -TargetDir $subPath -Enable $true

            Write-Host "Restored submodule '$($lm.name)' at $commit" -ForegroundColor Green
        }
        else {
            $targetDir = Join-Path -Path (Get-Location) -ChildPath $m.name

            Ensure-Clone-And-Fetch -Repo $m.repo -TargetDir $targetDir
            Ensure-Sparse -TargetDir $targetDir -RepoRelativePath $lm.localPath

            Ensure-Full-Fetch -TargetDir $targetDir
            $commit = Resolve-Commit -TargetDir $targetDir -Ref $lm.resolvedCommit

            Invoke-Git -WorkingDirectory $targetDir -Args @('checkout','--detach') | Out-Null
            Invoke-Git -WorkingDirectory $targetDir -Args @('-c','advice.detachedHead=false','checkout',$commit)

            Ensure-Submodules -TargetDir $targetDir -Enable $false

            Write-Host "Restored '$($lm.name)' at $commit" -ForegroundColor Green
        }

        # Handle binary files
        Copy-Files -Module $m
    }

    Write-Host "Restore completed." -ForegroundColor Green
}

function Invoke-Update {
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$LockPath,
        [string]$Name
    )

    $manifest = Read-Manifest -Path $ManifestPath
    $lock     = Read-Lock    -Path $LockPath
    $repoRoot = Get-RepoRoot

    foreach ($m in $manifest.modules) {
        if ($Name -and $m.name -ne $Name) { continue }

        if ([bool]$m.submodule) {
            $relPath = $m.name
            $subPath = Get-Submodule-Path -RepoRoot $repoRoot -RelPath $relPath

            Ensure-Submodule  -RepoRoot $repoRoot -RelPath $relPath -Repo $m.repo
            Ensure-Full-Fetch -TargetDir $subPath

            $ref    = Resolve-Desired-Ref -Version $m.version -Tag $m.tag -TargetDir $subPath
            $commit = Resolve-Commit     -TargetDir $subPath -Ref $ref

            Invoke-Git -WorkingDirectory $subPath -Args @('checkout','--detach') | Out-Null
            Invoke-Git -WorkingDirectory $subPath -Args @('-c','advice.detachedHead=false','checkout',$commit)

            Ensure-Submodules -TargetDir $subPath -Enable $true

            Update-LockEntry -Lock $lock -ModuleName $m.name -Repo $m.repo -TargetDir $subPath -LocalPath '.' -ResolvedCommit $commit
            Write-Lock -Lock $lock -Path $LockPath

            Write-Host "Updated submodule '$($m.name)' to $commit" -ForegroundColor Green
        }
        else {
            $targetDir = Join-Path -Path (Get-Location) -ChildPath $m.name

            Ensure-Clone-And-Fetch -Repo $m.repo -TargetDir $targetDir
            Ensure-Sparse -TargetDir $targetDir -RepoRelativePath $m.localPath

            $ref    = Resolve-Desired-Ref -Version $m.version -Tag $m.tag -TargetDir $targetDir
            $commit = Resolve-Commit     -TargetDir $targetDir -Ref $ref

            Invoke-Git -WorkingDirectory $targetDir -Args @('checkout','--detach') | Out-Null
            Invoke-Git -WorkingDirectory $targetDir -Args @('-c','advice.detachedHead=false','checkout',$commit)

            Ensure-Submodules -TargetDir $targetDir -Enable $false

            Update-LockEntry -Lock $lock -ModuleName $m.name -Repo $m.repo -TargetDir $targetDir -LocalPath $m.localPath -ResolvedCommit $commit
            Write-Lock -Lock $lock -Path $LockPath

            Write-Host "Updated '$($m.name)' to $commit" -ForegroundColor Green
        }

        # Handle binary files
        Copy-Files -Module $m
    }

    Write-Host "Update completed." -ForegroundColor Green
}

function Invoke-Remove {
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$LockPath,
        [string]$Name
    )

    $manifest = Read-Manifest -Path $ManifestPath
    $lock     = Read-Lock    -Path $LockPath
    $repoRoot = Get-RepoRoot

    # Build list from manifest (respect -Name filter)
    $modules = @()
    foreach ($m in $manifest.modules) {
        if ($Name -and $m.name -ne $Name) { continue }
        $modules += $m
    }

    if (-not $modules -or $modules.Count -eq 0) {
        Write-Host "No modules matched for removal." -ForegroundColor Yellow
        return
    }

    foreach ($m in $modules) {
        if ([bool]$m.submodule) {
            # ---------- SUBMODULE FLOW ----------
            # We use the same convention as Install/Update: submodule path == module name.
            $relPath = $m.name
            $subPath = Join-Path $repoRoot $relPath

            if (Is-Submodule -RepoRoot $repoRoot -RelPath $relPath) {
                Write-Host "Removing submodule '$($m.name)'..." -ForegroundColor Yellow

                # 1) Deinit to clear local config
                $r1 = Try-Git -WorkingDirectory $repoRoot -Args @('submodule','deinit','-f','--', $relPath)
                if ($r1.code -ne 0) { Write-Host "Warning: submodule deinit failed for $relPath" -ForegroundColor DarkYellow }

                # 2) Remove from index (and stage .gitmodules change)
                $r2 = Try-Git -WorkingDirectory $repoRoot -Args @('rm','-f','--cached','--', $relPath)
                if ($r2.code -ne 0) {
                    # Fallback: if staged removal fails (e.g., not tracked), continue cleanup
                    Write-Host "Warning: 'git rm --cached' failed for $relPath" -ForegroundColor DarkYellow
                }

                # 3) Clean up .gitmodules and .git/config sections (best effort)
                $null = Try-Git -WorkingDirectory $repoRoot -Args @('config','-f','.gitmodules','--remove-section',("submodule.$relPath"))
                $null = Try-Git -WorkingDirectory $repoRoot -Args @('config','--remove-section',("submodule.$relPath"))

                # 4) Physically delete the folder (if still present)
                Remove-DirectorySafe -Path $subPath

                Write-Host "Submodule '$($m.name)' removed." -ForegroundColor Green
            }
            else {
                # Not a registered submodule — just delete the folder if present
                Remove-DirectorySafe -Path $subPath
                Write-Host "Deleted folder for (non-registered) submodule '$($m.name)'." -ForegroundColor Green
            }
        }
        else {
            # ---------- NON-SUBMODULE FLOW ----------
            $targetDir = Join-Path -Path (Get-Location) -ChildPath $m.name
            Write-Host "Removing folder '$targetDir'..." -ForegroundColor Yellow
            Remove-DirectorySafe -Path $targetDir
            Write-Host "Removed '$($m.name)'." -ForegroundColor Green
        }

        # Remove lock entry (if present)
        $lock.modules = @($lock.modules | Where-Object { $_.name -ne $m.name })
    }

    # Persist updated lockfile
    Write-Lock -Lock $lock -Path $LockPath

    Write-Host "Remove operation completed." -ForegroundColor Green
}

function Show-Help {
    @"
Usage:
  pwsh ./gitmodules.ps1 -Command install  [-Name <module>] -ManifestPath ./packages.json -LockPath ./packages.lock.json
  pwsh ./gitmodules.ps1 -Command restore  [-Name <module>] -ManifestPath ./packages.json -LockPath ./packages.lock.json
  pwsh ./gitmodules.ps1 -Command update   [-Name <module>] -ManifestPath ./packages.json -LockPath ./packages.lock.json
  pwsh ./gitmodules.ps1 -Command remove   [-Name <module>] -ManifestPath ./packages.json -LockPath ./packages.lock.json

Manifest schema (per module):
  name (string, required)
  repo (string, required)            # git url
  localPath (string, required)       # repo-relative path (sparse checkout)
  version (string, optional)         # branch/ref/sha  [priority 1]
  tag (string, optional)             # tag name        [priority 2]
  submodule (bool, optional)         # if true, init & update submodules recursively

Lockfile stores:
  name, repo, targetDir, localPath, resolvedCommit, updatedAtUtc

Behavior:
  - Sparse checkout pins working tree to 'localPath' only ('.' means whole repo).
  - Priority: version > tag > origin/HEAD default branch.
"@ | Write-Host
}

# -------------------------
# Dispatcher
# -------------------------
switch ($Command.ToLower()) {
    'install' { Invoke-Install -ManifestPath $ManifestPath -LockPath $LockPath -Name $Name }
    'restore' { Invoke-Restore -ManifestPath $ManifestPath -LockPath $LockPath -Name $Name }
    'update' { Invoke-Update  -ManifestPath $ManifestPath -LockPath $LockPath -Name $Name }
    'remove' { Invoke-Remove  -ManifestPath $ManifestPath -LockPath $LockPath -Name $Name }
    default { Show-Help }
}
