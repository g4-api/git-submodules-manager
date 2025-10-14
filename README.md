# Git Submodules Manager

A compact PowerShell toolkit for managing **Git-based modular repositories**.
It includes two key scripts:

* **Install-Manager.ps1** – bootstraps and exposes the manager as a git submodule.
* **GitPackageManager.ps1** – installs, restores, updates, or removes repositories defined in a manifest.

Together they provide a deterministic, CI-friendly workflow for external dependencies.

---

## Table of Contents

1. [Overview](#overview)
2. [Installation Script (Install-Manager)](#installation-script-install-manager)

   * [Quick Start](#install-manager-quick-start)
3. [Package Manager (GitPackageManager)](#package-manager-gitpackagemanager)

   * [Quick Start](#gitpackagemanager-quick-start)
4. [Documentation](#documentation)
5. [License](#license)

---

## Overview

This project provides an easy, reproducible way to manage **submodules and external Git repositories** using manifest files.

* **Manifest-based control**: Define modules (repositories) declaratively in JSON.
* **Lockfile support**: Track exact commits for deterministic builds.
* **Cross-platform**: Works with PowerShell 5.1+ or PowerShell 7+.
* **Automation-ready**: Suitable for CI/CD pipelines and local development.

All documentation for the individual tools lives under the [`./docs`](./docs) folder:

* [`git-package-manager.md`](./docs/git-package-manager.md)
* [`install-manager.md`](./docs/install-manager.md)

---

## Installation Script (Install-Manager)

### Install-Manager Quick Start

1. **Copy** `Install-Manager.ps1` into your repo root.

2. **Run** (accepting defaults):

   ```pwsh
   pwsh ./Install-Manager.ps1
   ```

3. **Commit the staged changes**:

   ```pwsh
   git commit -m "Install Git Package Manager submodule and expose tools/GitPackageManager.ps1"
   git push
   ```

4. **Use the manager**:

   ```pwsh
   pwsh ./tools/GitPackageManager.ps1 -Command restore
   pwsh ./tools/GitPackageManager.ps1 -Command install -Commit
   pwsh ./tools/GitPackageManager.ps1 -Command update  -Name some-module -Commit
   pwsh ./tools/GitPackageManager.ps1 -Command remove  -Name some-module -Commit
   ```

---

## Package Manager (GitPackageManager)

### GitPackageManager Quick Start

#### Requirements

* PowerShell 5.1+ or PowerShell 7+
* Git 2.23+ recommended (falls back for older)
* Execute at **repo root**

#### Files

```none
config-specification.json            # manifest you edit
config-specification.lock.json       # lockfile script writes
tools/GitPackageManager.ps1          # script (path arbitrary)
```

#### Minimal manifest

```json
{
  "modules": [
    {
      "name": "sub-module-demo",
      "repo": "https://github.com/g4-api/sub-module-demo.git",
      "localPath": "submodules/sub-module-demo",
      "tag": "v1.0.0",
      "submodule": true
    }
  ]
}
```

#### Common commands

```powershell
# Install all modules and write lock
.\tools\GitPackageManager.ps1 -Command Install

# Update according to manifest (refresh lock)
.\tools\GitPackageManager.ps1 -Command Update

# Restore exact state from lock file
.\tools\GitPackageManager.ps1 -Command Restore

# Remove modules (folder or submodule)
.\tools\GitPackageManager.ps1 -Command Remove
```

Filter a single module:

```powershell
.\tools\GitPackageManager.ps1 -Command Update -Name "sub-module-demo"
```

Help:

```powershell
.\tools\GitPackageManager.ps1 -Command Help
```

---

## Documentation

* [Git Package Manager Reference](./docs/git-package-manager.md)
* [Install Manager Reference](./docs/install-manager.md)

Each includes full command documentation, manifest format, and troubleshooting.

---

## License

Apache-v2.0 License © G4 Automation Platform
