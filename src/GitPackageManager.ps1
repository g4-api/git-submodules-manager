#!/usr/bin/env pwsh
<#
.SYNOPSIS
    TFVC Package Manager (happy flow, minimal).

.DESCRIPTION
    Provides four operations over TFVC-mapped modules defined in a JSON manifest:
      - install : map & get by version/label (resolved to a changeset) and write lockfile
      - restore : get by exact changeset from the lockfile (deterministic)
      - update  : re-resolve version/label, get, and update lockfile
      - remove  : unmap & delete local folder
    Version priority: module.version > module.label > latest (T).
    Notes:
      - `version` may be a TFVC version spec: C123, 123, L<label>, T, Dyyyy-mm-dd, etc.
      - The lockfile stores `resolvedChangeset` (int) for reproducible restore.

.PARAMETER Command
    Operation to perform. One of: Install, Restore, Update, Remove, Help.

.PARAMETER Name
    Optional module name filter (supported by all commands).

.PARAMETER ManifestPath
    Path to the manifest JSON. Defaults to ./config-specification.json.

.PARAMETER LockPath
    Path to the lockfile JSON. Defaults to ./config-specification.lock.json.

.PARAMETER Mode
    Execution mode:
      - Auto  : detect (CI when running in pipeline, else Local)
      - Local : shared (persistent) workspace
      - CI    : ephemeral workspaces; remove on completion

.EXAMPLE
    pwsh ./tools/tfmodules.ps1 -Command Install -ManifestPath .\config.json -LockPath .\lock.json

.EXAMPLE
    pwsh ./tools/tfmodules.ps1 -Command Restore -Name common-lib

.EXAMPLE
    pwsh ./tools/tfmodules.ps1 -Command Update -Mode CI

.EXAMPLE
    pwsh ./tools/tfmodules.ps1 -Command Remove -Name common-lib

.NOTES
    Dependencies (invoked elsewhere in the script):
    - Invoke-InstallCommand
    - Invoke-RestoreCommand
    - Invoke-UpdateCommand
    - Invoke-RemoveCommand
    - Show-Help
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    # Operation to perform (case-insensitive).
    [ValidateSet('Install','Restore','Update','Remove','Help')]
    [string]$Command = 'Help',

    # Optional module filter (applies to all commands).
    [string]$Name,

    # Path to the manifest JSON.
    [string]$ManifestPath = "./config-specification.json",

    # Path to the lockfile JSON.
    [string]$LockPath     = "./config-specification.lock.json",

    # Mode: Auto (default), Local (shared workspace), CI (ephemeral, delete on exit).
    [ValidateSet('Auto','Local','CI')]
    [string]$Mode = 'Auto'
)

# Fail fast on errors so callers (and CI) can detect failures reliably.
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Detects whether the script is running in a Continuous Integration (CI) environment.

.DESCRIPTION
    Checks common environment variables that indicate CI/CD pipelines are running:
    - TF_BUILD (Azure DevOps Pipelines)
    - GITHUB_ACTIONS (GitHub Actions)
    - CI (Generic CI indicator used by multiple systems)

    Returns `$true` if any of these variables are set, otherwise `$false`.

.EXAMPLE
    if (Assert-Mode) {
        Write-Host "Running inside a CI environment."
    } else {
        Write-Host "Running locally."
    }
#>
function Assert-Mode {
    # Return a Boolean indicating whether any known CI environment variable is present.
    return [bool](
        $env:TF_BUILD -or         # Azure DevOps Pipelines
        $env:GITHUB_ACTIONS -or   # GitHub Actions
        $env:CI                   # Generic CI variable (used by many CI systems)
    )
}

<#
.SYNOPSIS
    Ensures a TFS/ADO workspace mapping exists between a server path and local path.

.DESCRIPTION
    - Creates the local directory (if it doesn’t already exist).  
    - Runs the `tf workfold /map` command to map the TFS server path to the local path 
      under the specified workspace.

.PARAMETER CollectionUrl
    The TFS/ADO collection URL.

.PARAMETER WorkspaceName
    The name of the workspace to update with the mapping.

.PARAMETER ServerPath
    The server path in TFS/ADO source control (e.g., "$/Project/Repo").

.PARAMETER LocalPath
    The local file system path where the server path should be mapped.

.EXAMPLE
    Confirm-Mapping `
        -CollectionUrl "http://tfs.local:8080/tfs/DefaultCollection" `
        -WorkspaceName "PkgMgr_jdoe_MYPC_abc123" `
        -ServerPath "$/common-code" `
        -LocalPath "C:\src\common-code"

    # Ensures "C:\src\common-code" exists and maps it to "$/common-code" in the given workspace.

.NOTES
    Depends on: Invoke-TeamFoundationCommand (wrapper for tf.exe).
#>
function Confirm-Mapping {
    [CmdletBinding()]
    param(
        # The TFS/ADO collection URL (e.g., http://tfs.local:8080/tfs/DefaultCollection)
        [string]$CollectionUrl,

        # The name of the workspace to apply the mapping to
        [string]$WorkspaceName,

        # The server-side path in TFS/ADO (e.g., "$/Project/Repo")
        [string]$ServerPath,

        # The local directory path where the mapping should be applied
        [string]$LocalPath
    )

    # Ensure the local directory exists (creates it if missing).
    New-Item -ItemType Directory -Force -Path $LocalPath | Out-Null
    
    # Map the server path to the local path inside the specified workspace.
    Invoke-TeamFoundationCommand `
        -Arguments "workfold /collection:`"$CollectionUrl`" /workspace:`"$WorkspaceName`" /map `"$ServerPath`" `"$LocalPath`"" | Out-Null
}

<#
.SYNOPSIS
    Ensures a TFVC workspace name is determined and creates the workspace.

.DESCRIPTION
    Derives a deterministic workspace name (via Get-WorkspaceName) for a given
    collection URL and operating mode (e.g., "CI" or "DEV"), then invokes the
    TF command-line client to (1) list existing workspaces and (2) create a new
    workspace with that name.

    NOTE: This implementation always attempts to create a new workspace. If a
    workspace with the same name already exists, TF will error. Consider adding
    an existence check or using /collection + /computer filters if you want to
    avoid errors on re-runs.

.PARAMETER CollectionUrl
    The TFS/Azure DevOps Server collection URL (e.g., http://server:8080/tfs/DefaultCollection).

.PARAMETER Mode
    A mode hint passed to Get-WorkspaceName (e.g., "CI" vs anything else), used
    to vary the naming scheme.

.OUTPUTS
    System.String
    Returns the computed workspace name.

.EXAMPLE
    Confirm-Workspace -CollectionUrl "http://tfs:8080/tfs/DefaultCollection" -Mode "CI"

    Computes a CI-style workspace name, lists workspaces for visibility, and
    then creates a new workspace with that name.

.NOTES
    - Requires tf.exe to be available on PATH (e.g., via Visual Studio Developer Command Prompt).
    - Uses Invoke-TeamFoundationCommand which shells through $Env:ComSpec (cmd.exe).
    - Get-WorkspaceName must exist in scope and return a single string.
#>
function Confirm-Workspace {
    [CmdletBinding()]
    param(
        [string]$CollectionUrl,
        [string]$Mode,
        [string]$WorkingDirectory = (Join-Path -Path (Get-Location) -ChildPath "workspaces")
    )

    # Compute a consistent workspace name based on collection + mode.
    # Get-WorkspaceName is expected to return a unique/stable name (e.g., includes user/machine or CI build id).
    $workspaceName = Get-WorkspaceName -CollectionUrl $CollectionUrl -Mode $Mode

    # (Visibility only) List workspaces for the collection. This helps with diagnostics/logs.
    # Output is discarded to keep the pipeline clean; remove Out-Null if you want to see it.
    Invoke-TeamFoundationCommand `
        -Arguments "workspaces /collection:`"$CollectionUrl`" /owner:*" `
        -WorkingDirectory $WorkingDirectory | Out-Null

    # Create a new workspace with a short comment ("pkgmgr"). /noprompt suppresses interactive UI.
    # If the workspace already exists, TF will return an error; consider handling that upstream if needed.
    Invoke-TeamFoundationCommand `
        -Arguments "workspace /new /collection:`"$CollectionUrl`" /comment:`"pkgmgr`" /noprompt `"$workspaceName`"" `
        -WorkingDirectory $WorkingDirectory

    # Return the name for callers that need to map/get against this workspace next.
    return $workspaceName
}

<#
.SYNOPSIS
    Generates a short SHA-1 hash from a given string.

.DESCRIPTION
    This function computes the SHA-1 hash of the provided text input
    and returns the first 8 characters of the resulting hex string.
    Useful for creating short, deterministic identifiers (e.g., commit-like hashes).

.PARAMETER Text
    The input string to hash.

.EXAMPLE
    ConvertTo-ShortHash -Text "Hello World"
    # Returns something like: "2ef7bde6"

.EXAMPLE
    "MyString" | ConvertTo-ShortHash
    # Returns a short hash of the string "MyString".

.NOTES
    Author: Your Name
    Algorithm: SHA-1 (truncated to 8 hex characters)
    Warning: SHA-1 is considered cryptographically weak.  
             Use only for identifiers, not for security-sensitive purposes.
#>
function ConvertTo-ShortHash {
    [CmdletBinding()]
    param(
        # The input string to be hashed
        [string]$Text
    )

    # Convert the input string into a byte array using UTF8 encoding
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)

    # Create a SHA1 hasher instance
    $sha1  = [System.Security.Cryptography.SHA1]::Create()

    # Compute the SHA1 hash and convert each byte to a 2-digit hex string, then join them
    $hex   = ($sha1.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    
    # Return only the first 8 characters of the hex string (short hash)
    return $hex.Substring(0,8)
}

<#
.SYNOPSIS
    Normalizes version or label input into a standardized string.

.DESCRIPTION
    This function ensures version identifiers are expressed consistently:
    - Pure numeric input → prefixed with "C" (treated as a changeset).
    - Non-numeric input (already prefixed or formatted) → returned as-is.
    - If version is null/empty → falls back to label.
        - Non-empty label → prefixed with "L".
        - If both are null/empty → defaults to "T".

.PARAMETER Version
    The version string to normalize.  
    Examples: "123", "C123", "Lmylabel", "D2025-09-01".

.PARAMETER Label
    A label string to use if no version is provided.  
    Will be normalized with "L" prefix.

.EXAMPLE
    Format-Version -Version "123"
    # Returns "C123"

.EXAMPLE
    Format-Version -Label "release-1.0"
    # Returns "Lrelease-1.0"

.EXAMPLE
    Format-Version
    # Returns "T" (default when both inputs are empty).

.NOTES
    Use for consistent handling of TFS/ADO changesets, labels, and dates.
#>
function Format-Version {
    [CmdletBinding()]
    param(
        # The version string (numeric, prefixed, or custom)
        [string]$Version,

        # The label string (used when version is empty)
        [string]$Label
    )

    if ($Version -and $Version.Trim().Length -gt 0) {
        # Clean up whitespace
        $Version = $Version.Trim()

        # If purely numeric → prefix with "C" (changeset)
        if ($Version -match '^[0-9]+$') {
            return "C$($Version)"
        }

        # Otherwise return as-is (already has a prefix like C, L, D, T, etc.)
        return $Version
    }

    # No version given, fall back to label
    $Label = $Label.Trim()

    if ($Label -and $Label.Length -gt 0) {
        # Normalize label with "L" prefix
        return "L$($Label)"
    }

    # Default to "T" (tip/latest)
    return 'T'
}

<#
.SYNOPSIS
    Determines the current execution mode (explicit, CI, or Local).

.DESCRIPTION
    This function inspects the `$Mode` variable to decide how the script is running:
    - If `$Mode` is explicitly set to something other than `"AUTO"`, that value is returned.
    - If `$Mode` is `"AUTO"`, the function checks if the script is running in a CI/CD pipeline
      using `Assert-Mode`:
        - If true, returns `"CI"`.
        - Otherwise, returns `"Local"`.

.EXAMPLE
    $Mode = "AUTO"
    Get-Mode
    # Returns "CI" if inside a CI/CD pipeline, otherwise "Local".

.EXAMPLE
    $Mode = "Local"
    Get-Mode
    # Always returns "Local".
#>
function Get-Mode {
    # If $Mode is explicitly set (not "AUTO"), return it directly.
    if ($Mode.ToUpper() -ne 'AUTO') { 
        return $Mode
    }
    
    # Otherwise, infer mode automatically:
    if (Assert-Mode) {
        return 'CI'      # Running inside a CI/CD environment
    } else {
        return 'Local'   # Running locally on a developer machine
    }
}

<#
.SYNOPSIS
    Generates a unique workspace name for TFS/ADO based on mode and environment.

.DESCRIPTION
    Constructs a deterministic workspace name depending on the execution mode:
    - CI Mode:
        Uses the build ID if available, otherwise falls back to a short hash
        of the process ID and a random number.  
        Prefix: "PkgMgr_CI"
    - Local Mode:
        Uses the current Windows username and machine name.  
        Prefix: "PkgMgr"
    In both cases, a short hash of the collection URL is appended for uniqueness.

.PARAMETER CollectionUrl
    The TFS/ADO collection URL (used to generate a unique hash).

.PARAMETER Mode
    The execution mode:  
        - "CI" → CI/CD pipeline mode  
        - Any other value → Local mode

.EXAMPLE
    Get-WorkspaceName -CollectionUrl "http://tfs.local:8080/tfs/DefaultCollection" -Mode "CI"
    # Returns something like: PkgMgr_CI_12345_ab12cd34

.EXAMPLE
    Get-WorkspaceName -CollectionUrl "http://tfs.local:8080/tfs/DefaultCollection" -Mode "Local"
    # Returns something like: PkgMgr_jdoe_MYPC_ab12cd34
#>
function Get-WorkspaceName {
    [CmdletBinding()]
    param(
        # The TFS/ADO collection URL (used to generate part of the workspace name)
        [string]$CollectionUrl,

        # Mode of execution: "CI" for pipelines, anything else for Local
        [string]$Mode
    )

    # Extract the collection name from the URL (last segment after '/')
    $collectionName = ($CollectionUrl.TrimEnd('/') -split '/')[-1]

    if ($Mode.ToUpper() -eq 'CI') {
        # In CI mode → prefer build ID as suffix
        $suffix = $env:BUILD_BUILDID

        # If no build ID is available, use a short hash of PID + random number
        if (-not $suffix) { 
            $suffix = ConvertTo-ShortHash "$PID-$(Get-Random)" 
        }

        # Workspace format: PkgMgr_CI_<suffix>_<collectionName>
        return "PkgMgr_CI_${suffix}_${collectionName}"
    } else {
        # In Local mode → include user and machine name
        $user    = $env:USERNAME
        $machine = $env:COMPUTERNAME

        # Workspace format: PkgMgr_<user>_<machine>_<collectionName>
        return "PkgMgr_${user}_${machine}_${collectionName}"
    }
}

<#
.SYNOPSIS
    Invokes a Team Foundation Server (TFS) / Azure DevOps "tf.exe" command.

.DESCRIPTION
    Wraps calls to the TFS command-line client (tf.exe) by launching them through
    the Windows command interpreter ($Env:ComSpec, typically cmd.exe). The function
    echoes the command for visibility and streams all output back to the caller.
    It ensures the working directory exists (creating it if necessary), changes
    to it before execution, and restores the original location afterwards.

.PARAMETER Arguments
    The full arguments string to pass to the tf command (without the leading "tf").
    Example: 'get "$/MyProject/Path" /version:T'

.PARAMETER WorkingDirectory
    The working directory from which the command should be executed.
    Default: "<current directory>\workspaces".
    If the directory does not exist, it will be created automatically.

.EXAMPLE
    Invoke-TeamFoundationCommand -Arguments 'workspaces /collection:"http://tfs:8080/tfs/DefaultCollection"'

.EXAMPLE
    Invoke-TeamFoundationCommand -Arguments 'get "$/Proj/File.txt" /version:LMyLabel'

.OUTPUTS
    Writes the tf.exe output to the pipeline as strings (one line per output line).

.NOTES
    - Requires tf.exe to be available on PATH.
    - $Env:ComSpec ensures execution goes through cmd.exe, which can avoid some quoting
      issues compared to invoking tf.exe directly from PowerShell.
    - Exit code: check $LASTEXITCODE after calling this function if you need to assert success.
#>
function Invoke-TeamFoundationCommand {
    [CmdletBinding()]
    param(
        # The raw arguments to pass to "tf".
        [string]$Arguments,

        # The working folder to execute the command from (created if missing).
        [string]$WorkingDirectory = (Join-Path -Path (Get-Location) -ChildPath "workspaces")
    )

    # Ensure the working directory exists, create if missing.
    if (-not (Test-Path -Path $WorkingDirectory -PathType Container)) {
        New-Item -Path $WorkingDirectory -ItemType Directory -Force | Out-Null
    }

    # Log the command for visibility (mirrors what will be executed).
    Write-Host ">> tf $Arguments (in '$WorkingDirectory')" -ForegroundColor DarkCyan

    # Save the current location so we can restore it after running the command.
    Push-Location -Path $WorkingDirectory
    try {
        # Invoke via the system shell ($Env:ComSpec = cmd.exe).
        # /c runs the command and then terminates the shell.
        #
        # Output is piped line-by-line so it can be captured, logged, or further processed.
        & $Env:ComSpec /c "tf $Arguments" | ForEach-Object { $_ }
    }
    finally {
        # Always restore the original location even if the command fails.
        Pop-Location
    }
}

<#
.SYNOPSIS
    Reads a manifest lock file if it exists, otherwise returns an empty default object.

.DESCRIPTION
    This function attempts to read a lock manifest JSON file from the provided path.
    - If the file exists, it loads and converts the JSON into a PowerShell object.
    - If the file does not exist, it returns a default PSCustomObject with an empty `modules` array.
    This ensures downstream code can always work with a consistent object structure.

.PARAMETER Path
    The file path of the manifest lock file (e.g., "./config-specification.lock.json").

.EXAMPLE
    $lock = Read-ManifestLock -Path "./config-specification.lock.json"
    # Reads the lock file if it exists, otherwise returns @{ modules = @() }

.EXAMPLE
    $lock.modules.Count
    # Safe to call even if the lock file does not exist, since `modules` will be an empty array.

.NOTES
    Returns a PSCustomObject, ensuring consistent structure even when no lock file is found.
#>
function Read-ManifestLock {
    [CmdletBinding()]
    param(
        # Path to the manifest lock file
        [string]$Path
    )
    
    # If the lock file exists, read and parse it as JSON
    if (Test-Path $Path) {
        return Get-Content $Path -Raw | ConvertFrom-Json
    } 
    else {
        # If no lock file exists, return a default object with an empty modules array
        return [pscustomobject]@{ modules = @() }
    }
}

<#
.SYNOPSIS
    Deletes a TFS/ADO workspace.

.DESCRIPTION
    Runs the `tf workspace /delete` command against the specified 
    collection and workspace name.  
    This permanently removes the workspace from TFS/ADO.

.PARAMETER CollectionUrl
    The URL of the TFS/ADO collection containing the workspace.

.PARAMETER WorkspaceName
    The name of the workspace to delete.

.EXAMPLE
    Remove-Workspace -CollectionUrl "http://tfs.local:8080/tfs/DefaultCollection" -WorkspaceName "PkgMgr_jdoe_MYPC_abc123"
    # Deletes the specified workspace from the collection.

.NOTES
    Author: Your Name
    Depends on: Invoke-TeamFoundationCommand (wrapper for `tf.exe`).
    Warning: Workspace deletion is permanent and cannot be undone.
#>
function Remove-Workspace {
    [CmdletBinding()]
    param(
        # The TFS/ADO collection URL (e.g., http://tfs.local:8080/tfs/DefaultCollection)
        [string]$CollectionUrl,

        # The name of the workspace to delete
        [string]$WorkspaceName
    )
    
    # Execute `tf workspace /delete` against the given collection/workspace
    Invoke-TeamFoundationCommand `
        -Arguments "workspace /delete /collection:`"$CollectionUrl`" /noprompt `"$WorkspaceName`""
}

<#
.SYNOPSIS
    Resolves a TFVC version spec to a concrete changeset ID.

.DESCRIPTION
    Given a TFVC version spec (e.g., "C123", "Llabel", "T", "Dyyyy-mm-dd"),
    this function queries TFS history to determine the actual numeric changeset ID.
    It runs `tf history` with:
      - The specified server path
      - /version:<spec>
      - /stopafter:1
      - /format:brief
    The first numeric value found in the history output is returned as [int].

.PARAMETER CollectionUrl
    The TFS/ADO collection URL to query against.

.PARAMETER ServerPath
    The TFVC server path (e.g., "$/Project/Repo/Folder") to query history for.

.PARAMETER Version
    The version specifier to resolve.  
    Examples:
      - "C123" → specific changeset
      - "LMyLabel" → label
      - "T" → latest tip
      - "D2025-09-01" → date-based lookup

.EXAMPLE
    Resolve-VersionChangeset `
        -CollectionUrl "http://tfs:8080/tfs/DefaultCollection" `
        -ServerPath "$/Project/Main" `
        -Version "Lrelease-1.0"
    # Returns the changeset ID corresponding to the label "release-1.0".

.EXAMPLE
    Resolve-VersionChangeset `
        -CollectionUrl "http://tfs:8080/tfs/DefaultCollection" `
        -ServerPath "$/Project/Main" `
        -Version "T"
    # Returns the latest changeset ID for the path.

.NOTES
    Depends on: Invoke-TeamFoundationCommand (wrapper for `tf.exe`).
    Throws an error if no changeset ID can be resolved.
#>
function Resolve-VersionChangeset {
    [CmdletBinding()]
    param(
        # The TFS/ADO collection URL
        [string]$CollectionUrl,

        # The TFVC server path to query
        [string]$ServerPath,

        # The version specifier ("C123", "Llabel", "T", "Dyyyy-mm-dd")
        [string]$Version
    )

    # Run tf.exe history to resolve the version spec to an actual changeset ID
    $out = Invoke-TeamFoundationCommand `
        -Arguments "history `"$ServerPath`" /collection:`"$CollectionUrl`" /recursive /noprompt /stopafter:1 /version:$Version /format:brief"

    # Join multiline output into one string for easier parsing
    $joined = ($out -join "`n")

    # Extract all digit-only sequences (candidate changeset numbers)
    $numbers = $joined -replace '[^\d]',' ' -split '\s+' | Where-Object { $_ -match '^\d+$' }

    # Take the first number, which should be the changeset ID
    $first = $numbers | Select-Object -First 1

    # If no number found, throw an error
    if (-not $first) {
        throw "Failed to resolve version '$Version' for $ServerPath"
    }
    
    # Return the changeset ID as an integer
    return [int]$first
}

<#
.SYNOPSIS
    Updates or adds a module entry in the manifest lock object.

.DESCRIPTION
    This function ensures the given module has an up-to-date entry in the 
    manifest lock (`$Lock.modules`).  
    - If the module already exists (matched by `name`), its fields are updated.  
    - If it does not exist, a new entry is appended.  

    Useful for keeping the lock manifest consistent with the current 
    mapping state (collection, paths, and resolved changeset).

.PARAMETER Lock
    The manifest lock object containing a `modules` property (array).

.PARAMETER ModuleName
    The name of the module to update or insert.

.PARAMETER CollectionUrl
    The TFS/ADO collection URL associated with the module.

.PARAMETER ServerPath
    The TFS/ADO server path for the module.

.PARAMETER LocalPath
    The local file system path mapped for the module.

.PARAMETER Changeset
    The resolved changeset number for the module.

.EXAMPLE
    Update-LockEntry -Lock $lock -ModuleName "common-file" `
                     -CollectionUrl "http://tfs:8080/tfs/DefaultCollection" `
                     -ServerPath "$/common-code/common-file.md" `
                     -LocalPath "E:\src\common\common-file" `
                     -Changeset 1234

    # Updates the existing "common-file" entry or inserts it if missing.
#>
function Update-LockEntry {
    [CmdletBinding()]
    param(
        # The lock object (must contain a .modules array)
        $Lock,

        # Module name to update or insert
        [string]$ModuleName,

        # Collection URL (TFS/ADO collection)
        [string]$CollectionUrl,

        # Server path in source control
        [string]$ServerPath,

        # Local mapped path
        [string]$LocalPath,

        # Resolved changeset number
        [int]$Changeset
    )

    # Find existing module entry (if any) by name
    $existing = $Lock.modules | Where-Object { $_.name -eq $ModuleName } | Select-Object -First 1
    
    if ($existing) {
        # Update existing entry
        $existing.collection        = $CollectionUrl
        $existing.serverPath        = $ServerPath
        $existing.localPath         = $LocalPath
        $existing.resolvedChangeset = $Changeset
    } 
    else {
        # Add new entry to the modules array
        $Lock.modules += [pscustomobject]@{
            name              = $ModuleName
            collection        = $CollectionUrl
            serverPath        = $ServerPath
            localPath         = $LocalPath
            resolvedChangeset = $Changeset
        }
    }
}

# ---------------- Package Management Commands ----------------
# Each command (install, restore, update, remove) processes the manifest
# and performs the necessary TFVC operations, updating the lock file as needed.
# They all respect the -Name filter and -Mode setting.
# -------------------------------------------------------------

<#
.SYNOPSIS
    Installs one or more modules from a manifest file into a TFS workspace.
.DESCRIPTION
    Reads a JSON manifest file describing modules, maps them into a TFS workspace,
    performs a `tf get` to fetch the correct version (changeset or label),
    updates the lockfile with the resolved changeset, and optionally removes
    temporary workspaces when running in CI mode.
.PARAMETER ManifestPath
    Path to the manifest JSON file containing the list of modules.
.PARAMETER LockPath
    Path to the lockfile JSON where resolved changesets are recorded.
.PARAMETER Name
    Optional. If provided, only the module matching this name is installed.
    Otherwise, all modules in the manifest are processed.
.PARAMETER Mode
    Execution mode (e.g., "DEV" or "CI"). 
    In CI mode, temporary workspaces are removed after installation.
.EXAMPLE
    Invoke-InstallCommand -ManifestPath ".\manifest.json" -LockPath ".\lock.json" -Mode "DEV"
    Installs all modules from manifest.json, updates lock.json, and leaves workspaces intact.
.EXAMPLE
    Invoke-InstallCommand -ManifestPath ".\manifest.json" -LockPath ".\lock.json" -Name "common-lib" -Mode "CI"
    Installs only the "common-lib" module in CI mode and removes the workspace afterwards.
.NOTES
    Requires supporting functions:
        - Get-Mode
        - Confirm-Workspace
        - Confirm-Mapping
        - Format-Version
        - Invoke-TeamFoundationCommand
        - Resolve-VersionChangeset
        - Read-ManifestLock
        - Update-LockEntry
        - Get-WorkspaceName
        - Remove-Workspace
#>
function Invoke-InstallCommand {
    [CmdletBinding()]
    param(
        # Path to the manifest JSON file
        [string]$ManifestPath,

        # Path to the lockfile JSON
        [string]$LockPath,
        
        # Optional module name filter
        [string]$Name,
        
        # Execution mode (e.g., "DEV" or "CI")
        [string]$Mode
    )

    # Load and parse the manifest JSON
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
   
    # Respect explicit -Mode if provided; otherwise detect dynamically.
    $mode = if ($PSBoundParameters.ContainsKey('Mode') -and $Mode) { $Mode } else { Get-Mode }

    # Track all touched TFS collections for cleanup in CI mode
    $touchedCollections = @()

    # Process each module in the manifest
    foreach ($module in $manifest.modules) {
        # If -Name was provided, skip modules that do not match
        if ($Name -and $module.name -ne $Name) { 
            continue
        }

        # Resolve the TFS collection: use module.collection if present, otherwise manifest.defaultCollection
        $collection = if ($module.PSObject.Properties.Name -contains 'collection' -and $module.collection) {
            [string]$module.collection
        } else {
            [string]$manifest.defaultCollection
        }

        # Extract collection name from the collection URL for workspace naming
        $collectionName = ($collection.TrimEnd('/') -split '/')[-1]

        # Set up the local workspace path
        $localPath = ([System.IO.Path]::Combine($manifest.defaultWorkspace, $collectionName, $module.localPath))

        # Ensure a workspace exists for this collection and mode
        $workspace = Confirm-Workspace `
            -CollectionUrl $collection `
            -Mode $mode `
            -WorkingDirectory (Join-Path -Path $manifest.defaultWorkspace -ChildPath $collectionName)

        # Map the server path to the local path inside the workspace
        Confirm-Mapping `
            -CollectionUrl $collection `
            -WorkspaceName $workspace `
            -ServerPath $module.serverPath `
            -LocalPath $localPath

        # Resolve module version (by version string or label)
        $version = Format-Version -Version $module.version -Label $module.label

        # Perform a TFS "get" to fetch the specified version to the local path
        Invoke-TeamFoundationCommand `
            -Arguments "get `"$($localPath)`" /recursive /version:$version /overwrite" `
            -WorkingDirectory $manifest.defaultWorkspace

        # Resolve the actual changeset ID for the version spec (needed for lockfile)
        $resolvedChangeset = Resolve-VersionChangeset `
            -CollectionUrl $collection `
            -ServerPath $module.serverPath `
            -Version $version

        # Load the existing lockfile or create a new one
        $lock = Read-ManifestLock -Path $LockPath

        # Update the lockfile entry for this module with the resolved changeset
        Update-LockEntry `
            -Lock $lock `
            -ModuleName $module.name `
            -CollectionUrl $collection `
            -ServerPath $module.serverPath `
            -LocalPath $module.localPath `
            -Changeset $resolvedChangeset

        # Persist the updated lockfile to disk
        $lock | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $LockPath

        # Record the touched collection for possible cleanup
        $touchedCollections += $collection
    }

    # In CI mode, remove any temporary workspaces created
    if ($mode.ToUpper() -eq 'CI') {
        $touchedCollections = $touchedCollections | Select-Object -Unique

        # Remove any temporary workspaces created
        foreach ($collectionUrl in $touchedCollections) {
            $workspaceName = Get-WorkspaceName `
                -CollectionUrl $collectionUrl `
                -Mode $mode
            
            Remove-Workspace `
                -CollectionUrl $collectionUrl `
                -WorkspaceName $workspaceName
        }
    }

    # Final success message
    Write-Host "Install operation completed successfully for all specified modules" -ForegroundColor Green
}

<#
.SYNOPSIS
    Restores TFVC modules to the exact versions recorded in a lockfile.

.DESCRIPTION
    Reads a manifest (for defaults like the collection URL) and a lockfile that
    contains resolved module metadata (e.g., serverPath, localPath, resolvedChangeset).
    For each module (optionally filtered by -Name), this function:
      1) Ensures a workspace exists (Confirm-Workspace),
      2) Ensures a server→local mapping exists (Confirm-Mapping),
      3) Performs a `tf get` to the specified changeset (exact version restore).

    In CI mode, it deletes the temporary workspace(s) it created at the end.

.PARAMETER ManifestPath
    Path to the modules manifest JSON (provides defaults like defaultCollection).

.PARAMETER LockPath
    Path to the lockfile JSON that pins each module to a specific changeset.

.PARAMETER Name
    Optional module name to restore. If omitted, all modules in the lock are restored.

.PARAMETER Mode
    Execution mode, e.g., "DEV" or "CI".
    If not supplied, the function resolves it via Get-Mode.

.OUTPUTS
    None. Writes status messages to the host.

.EXAMPLE
    Invoke-RestoreCommand -ManifestPath .\submodules.json -LockPath .\submodules.lock.json -Mode CI

.NOTES
    Dependent functions required:
    - Get-Mode
    - Read-ManifestLock
    - Get-WorkspaceName
    - Confirm-Workspace
    - Confirm-Mapping
    - Invoke-TeamFoundationCommand
    - Remove-Workspace (or Delete-Workspace)
#>
function Invoke-RestoreCommand {
    [CmdletBinding()]
    param(
        # Path to the manifest JSON file
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ManifestPath,

        # Path to the lockfile JSON
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$LockPath,
        
        # Optional module name filter
        [string]$Name,
        
        # Execution mode (e.g., "DEV" or "CI")
        [string]$Mode
    )

    # Load inputs (fail fast on IO/JSON errors).
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    
    # Respect explicit -Mode if provided; otherwise detect dynamically.
    $mode = if ($PSBoundParameters.ContainsKey('Mode') -and $Mode) { $Mode } else { Get-Mode }

    # Load the lockfile (or get a default empty structure if missing).
    $lock = Read-ManifestLock -Path $LockPath

    # Track which collections we touched so CI can clean their workspaces later.
    $touchedCollections = @()

    # Process each module recorded in the lockfile.
    foreach ($module in $lock.modules) {
        # Optional name filter: skip non-matching modules.
        if ($Name -and $module.name -ne $Name) { 
            continue
        }

        # Resolve the TFS collection: use module.collection if present, otherwise manifest.defaultCollection
        $collection = if ($module.PSObject.Properties.Name -contains 'collection' -and $module.collection) {
            [string]$module.collection
        } else {
            [string]$manifest.defaultCollection
        }

        # Extract collection name from the collection URL for workspace naming
        $collectionName = ($collection.TrimEnd('/') -split '/')[-1]

        # Set up the local workspace path
        $localPath = ([System.IO.Path]::Combine($manifest.defaultWorkspace, $collectionName, $module.localPath))

        # Ensure a workspace exists for this collection and mode
        $workspace = Confirm-Workspace `
            -CollectionUrl $collection `
            -Mode $mode `
            -WorkingDirectory (Join-Path -Path $manifest.defaultWorkspace -ChildPath $collectionName)

        # Map the server path to the local path inside the workspace
        Confirm-Mapping `
            -CollectionUrl $collection `
            -WorkspaceName $workspace `
            -ServerPath $module.serverPath `
            -LocalPath $localPath

        # Restore the local files to the exact changeset recorded in the lockfile.
        # Notes:
        #   - Using the *local* path here is valid once mapping is in place.
        #   - /recursive: include sub-items; /version:Cnnn: exact changeset; /overwrite: replace local.
        Invoke-TeamFoundationCommand `
            -Arguments "get `"$($localPath)`" /recursive /version:C$($module.resolvedChangeset) /overwrite" `
            -WorkingDirectory $manifest.defaultWorkspace

        # Record this collection so CI can clean up workspaces afterward.
        $touchedCollections += $collection
    }

    # In CI we want to leave no local state behind—remove all distinct workspaces we created.
    if ($mode.ToUpper() -eq 'CI') {
        $touchedCollections = $touchedCollections | Select-Object -Unique
        foreach ($touchedCollection in $touchedCollections) {

            # Recompute the workspace name the same way it was created.
            $wsName = Get-WorkspaceName `
                -CollectionUrl $touchedCollection `
                -Mode $mode
            
            # Remove the workspace. 
            Remove-Workspace `
                -CollectionUrl $touchedCollection `
                -WorkspaceName $wsName
        }
    }

    # Final success message.
    Write-Host "Restore operation completed successfully for all specified modules" -ForegroundColor Green
}

<#
.SYNOPSIS
    Updates modules per the manifest, syncs them to the requested versions, and refreshes the lock file.

.DESCRIPTION
    For each module in the manifest (optionally filtered by -Name), this command:
      1) Resolves the collection URL (module.collection or manifest.defaultCollection).
      2) Ensures a workspace exists for the collection/mode (Confirm-Workspace).
      3) Ensures server↔local mapping exists (Confirm-Mapping).
      4) Builds a TFVC version spec (Format-Version) and performs `tf get` to that version.
      5) Resolves the concrete numeric changeset (Resolve-VersionChangeset).
      6) Upserts the module’s entry in the lock (Update-LockEntry).
      7) Persists the updated lock file.
    When running in CI mode, it de-provisions transient workspaces for touched collections.

    Expected manifest module fields:
      - name (string), serverPath (string), localPath (string)
      - Optional: version (string), label (string), collection (string)

.PARAMETER ManifestPath
    Path to the manifest JSON file.

.PARAMETER LockPath
    Path to the lockfile JSON.

.PARAMETER Name
    Optional module name to process exclusively.

.PARAMETER Mode
    Execution mode (e.g., "CI", "Local", or "AUTO"). If omitted, Get-Mode is used.
.OUTPUTS
    None. Writes progress to host and updates the lock file on disk.

.EXAMPLE
    Invoke-UpdateCommand -ManifestPath .\config-specification.json -LockPath .\config-specification.lock.json

.EXAMPLE
    Invoke-UpdateCommand -ManifestPath .\config.json -LockPath .\lock.json -Name common-file -Mode CI

.NOTES
    Dependencies:
    - Get-Mode
    - Read-ManifestLock
    - Confirm-Workspace
    - Confirm-Mapping
    - Format-Version
    - Invoke-TeamFoundationCommand
    - Resolve-VersionChangeset
    - Update-LockEntry
    - Get-WorkspaceName
    - Remove-Workspace
#>
function Invoke-UpdateCommand {
    [CmdletBinding()]
    param(
        # Path to the manifest JSON file
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ManifestPath,

        # Path to the lockfile JSON
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$LockPath,
        
        # Optional module name filter
        [string]$Name,
        
        # Execution mode (e.g., "CI", "Local", or "AUTO")
        [string]$Mode
    )

    # Load the manifest.
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

    # Respect explicit -Mode if provided; otherwise detect dynamically.
    $mode = if ($PSBoundParameters.ContainsKey('Mode') -and $Mode) { $Mode } else { Get-Mode }

    # Load existing lock (or default empty) so updates append/modify entries in place.
    $lock = Read-ManifestLock -Path $LockPath

    # Track collections touched (used for CI workspace cleanup).
    $touchedCollections = @()

    foreach ($module in $manifest.modules) {
        # Honor -Name filter if provided.
        if ($Name -and $module.name -ne $Name) { 
            continue
        }

        # Resolve the TFS collection: use module.collection if present, otherwise manifest.defaultCollection
        $collection = if ($module.PSObject.Properties.Name -contains 'collection' -and $module.collection) {
            [string]$module.collection
        } else {
            [string]$manifest.defaultCollection
        }

        # Extract collection name from the collection URL for workspace naming
        $collectionName = ($collection.TrimEnd('/') -split '/')[-1]

        # Set up the local workspace path
        $localPath = ([System.IO.Path]::Combine($manifest.defaultWorkspace, $collectionName, $module.localPath))

        # Build a TFVC version spec (e.g., C123 / L<label> / T / Dyyyy-mm-dd).
        $versionSpec = Format-Version `
            -Version $($module.version) `
            -Label  $($module.label)

        # Sync the local folder to the requested version (overwrite to enforce exact state).
        Invoke-TeamFoundationCommand `
            -Arguments "get `"$($localPath)`" /recursive /version:$versionSpec /overwrite" `
            -WorkingDirectory $manifest.defaultWorkspace

        # Resolve the concrete numeric changeset that the spec maps to.
        $resolvedChangeset = Resolve-VersionChangeset `
            -CollectionUrl $collection `
            -ServerPath    $($module.serverPath) `
            -Version       $versionSpec
        
        # Upsert the module’s lock entry with resolved state.
        Update-LockEntry `
            -Lock          $lock `
            -ModuleName    $($module.name) `
            -CollectionUrl $collection `
            -ServerPath    $($module.serverPath) `
            -LocalPath     $($module.localPath) `
            -Changeset     $resolvedChangeset

        # Record the collection for potential CI cleanup later.
        $touchedCollections += $collection
    }

    # Persist the updated lock to disk.
    $lock | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $LockPath

    # In CI mode, tear down transient workspaces per touched collection.
    if ($mode.ToUpper() -eq 'CI') {
        $touchedCollections = $touchedCollections | Select-Object -Unique
        foreach ($touchedCollection in $touchedCollections) {
            $workspaceName = Get-WorkspaceName `
                -CollectionUrl $touchedCollection `
                -Mode          $mode
            
            Remove-Workspace `
                -CollectionUrl $touchedCollection `
                -WorkspaceName $workspaceName
        }
    }

    # Done.
    Write-Host "Update operation completed successfully for all specified modules" -ForegroundColor Green
}

<#
.SYNOPSIS
    Unmaps module workspace mappings and deletes local directories as defined in the manifest.

.DESCRIPTION
    For each module in the manifest (optionally filtered by -Name), this command:
      1) Resolves the collection URL (module.collection or manifest.defaultCollection).
      2) Ensures a workspace exists / gets its name (Confirm-Workspace).
      3) Unmaps the server↔local mapping (`tf workfold /unmap` via Invoke-TeamFoundationCommand).
      4) Deletes the local directory if it exists.
    When running in CI mode, it also removes transient workspaces for all touched collections.

.PARAMETER ManifestPath
    Path to the manifest JSON file.

.PARAMETER LockPath
    Path to the lockfile JSON. Present for parity/consistency with other commands.

.PARAMETER Name
    Optional module name to process exclusively.

.PARAMETER Mode
    Execution mode (e.g., "CI", "Local", or "AUTO"). If omitted, Get-Mode is used.

.INPUTS
    None. All inputs are passed as parameters and read from files.

.OUTPUTS
    None. Writes progress to host.

.EXAMPLE
    Invoke-RemoveCommand -ManifestPath .\config-specification.json -LockPath .\config-specification.lock.json
    # Unmaps and removes all modules in the manifest; in CI, also deletes transient workspaces.

.EXAMPLE
    Invoke-RemoveCommand -Mode CI
    # Forces CI behavior (e.g., workspace teardown) regardless of environment.

.NOTES
    Destructive operation: unmaps TFVC folders and deletes local directories.

    Dependencies:
    - Get-Mode
    - Confirm-Workspace
    - Get-WorkspaceName
    - Remove-Workspace
    - Invoke-TeamFoundationCommand

    Tip:
    Some tf.exe clients reject `/collection:` on `workfold /unmap`. If you receive
    “The option collection is not allowed.”, try omitting `/collection:` or placing
    `/unmap` first and/or using the local path as the argument to `/unmap`.
#>
function Invoke-RemoveCommand {
    [CmdletBinding()]
    param(
        # Path to the manifest JSON file
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ManifestPath,

        # Path to the lockfile JSON
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$LockPath,
        
        # Optional module name filter
        [string]$Name,
        
        # Execution mode (e.g., "CI", "Local", or "AUTO")
        [string]$Mode
    )

    # Load manifest
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

    # Compute effective mode: honor -Mode if supplied; otherwise detect dynamically.
    $mode = if ($PSBoundParameters.ContainsKey('Mode') -and $Mode) { $Mode } else { Get-Mode }
    
    # Track which collections were touched (used for CI workspace cleanup).
    $touchedCollections = @()

    foreach ($module in $manifest.modules) {
        # Honor -Name filter if provided.
        if ($Name -and $module.name -ne $Name) { 
            continue
        }

        # Resolve the TFS collection: use module.collection if present, otherwise manifest.defaultCollection
        $collection = if ($module.PSObject.Properties.Name -contains 'collection' -and $module.collection) {
            [string]$module.collection
        } else {
            [string]$manifest.defaultCollection
        }

        # Extract collection name from the collection URL for workspace naming
        $collectionName = ($collection.TrimEnd('/') -split '/')[-1]

        # Set up the local workspace path
        $localPath = ([System.IO.Path]::Combine($manifest.defaultWorkspace, $collectionName, $module.localPath))

        # Ensure a workspace exists for this collection and mode
        $workspace = Confirm-Workspace `
            -CollectionUrl $collection `
            -Mode $mode `
            -WorkingDirectory (Join-Path -Path $manifest.defaultWorkspace -ChildPath $collectionName)
        
        # Unmap the local path from the workspace mapping.
        Invoke-TeamFoundationCommand `
            -Arguments "workfold /unmap `"$($module.serverPath)`" /workspace:`"$workspace`" /collection:`"$collection`"" `
            -WorkingDirectory $manifest.defaultWorkspace

        # Remove the local directory if it still exists (force + recurse).
        if (Test-Path $($localPath)) { 
            Remove-Item -Path $($localPath) -Recurse -Force
        }

        # Record the collection for potential CI cleanup later.
        $touchedCollections += $collection
    }

    # In CI mode, tear down transient workspaces for each unique touched collection.
    if ($mode.ToUpper() -eq 'CI') {
        $touchedCollections = $touchedCollections | Select-Object -Unique

        # Remove any temporary workspaces created
        foreach ($touchedCollection in $touchedCollections) {
            $workspaceName = Get-WorkspaceName `
                -CollectionUrl $touchedCollection `
                -Mode $mode
            
            Remove-Workspace `
                -CollectionUrl $touchedCollection `
                -WorkspaceName $workspaceName
        }
    }

    # Success message.
    Write-Host "Remove operation completed successfully for all specified modules" -ForegroundColor Green
}

<#
.SYNOPSIS
    Prints CLI usage, manifest fields, and version examples for the tfmodules script.

.DESCRIPTION
    Displays a concise multi-line help message covering:
      - Supported commands (install, restore, update, remove)
      - Optional switches (-Name, -Mode)
      - Expected manifest module fields
      - Version priority and examples (C<changeset>, L<label>, T, D<yyyy-mm-dd>)

.PARAMETER (none)
    This function takes no parameters.

.OUTPUTS
    None. Writes formatted text to the host.

.EXAMPLE
    Show-Help
    # Prints the usage guide to the console.

.NOTES
    Intended for quick, in-terminal guidance. Uses Write-Host to preserve formatting.
#>
function Show-Help {
@"
Usage:
    pwsh|powershell ./tools/tfmodules.ps1 -Command install  [-Name <module>] [-Mode auto|local|ci]
    pwsh|powershell ./tools/tfmodules.ps1 -Command restore  [-Name <module>] [-Mode auto|local|ci]
    pwsh|powershell ./tools/tfmodules.ps1 -Command update   [-Name <module>] [-Mode auto|local|ci]
    pwsh|powershell ./tools/tfmodules.ps1 -Command remove   [-Name <module>] [-Mode auto|local|ci]

Manifest module fields:
    name, serverPath, localPath, [collection], [version], [label]

Version priority: version > label > latest (T)
Examples:
    "version": 123          # same as C123
    "version": "C456"
    "version": "T"
    "version": "D2025-09-01"
"@ | Write-Host
}

# Dispatch based on the normalized (lowercase) command string.
switch ($Command.ToLower()) {
    'install' { 
        # Install: ensure workspaces/mappings exist and materialize modules per manifest.
        Invoke-InstallCommand `
            -ManifestPath $ManifestPath `
            -LockPath     $LockPath `
            -Name         $Name `
            -Mode         $Mode
    }
    'restore' {
        # Restore: rehydrate modules from the lock file (exact recorded versions/changesets).
        Invoke-RestoreCommand `
            -ManifestPath $ManifestPath `
            -LockPath     $LockPath `
            -Name         $Name `
            -Mode         $Mode
    }
    'update'  {
        # Update: sync to requested versions/labels, then refresh and persist the lock file.
        Invoke-UpdateCommand `
            -ManifestPath $ManifestPath `
            -LockPath     $LockPath `
            -Name         $Name `
            -Mode         $Mode
    }
    'remove'  {
        # Remove: unmap workspace folders and delete local directories (optionally one module).
        Invoke-RemoveCommand `
            -ManifestPath $ManifestPath `
            -LockPath     $LockPath `
            -Name         $Name `
            -Mode         $Mode
    }
    default   {
        # Unknown command → print usage/help.
        Show-Help
    }
}
