# Git Package Manager — Comprehensive User Guide

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Manifest Structure](#manifest-structure)
4. [Command Reference & Detailed Behavior](#command-reference--detailed-behavior)
   * [Install](#install)
   * [Update](#update)
   * [Restore](#restore)
   * [Remove](#remove)
   * [Help](#help)
5. [Lock File Explained](#lock-file-explained)
6. [Submodules vs Plain Clones](#submodules-vs-plain-clones)
7. [Advanced Options & Workflows](#advanced-options--workflows)
8. [CI/CD Integration](#cicd-integration)
9. [Troubleshooting](#troubleshooting)
10. [Best Practices](#best-practices)
11. [End-to-End Examples](#end-to-end-examples)
12. [FAQs](#faqs)
13. [Command-Line Options (Reference)](#command-line-options-reference)
14. [Safety & Idempotency Notes](#safety--idempotency-notes)
15. [Suggested .gitignore Additions](#suggested-gitignore-additions)
16. [Migration Playbook](#migration-playbook)

---

## Overview

The Git Package Manager script manages external repositories and submodules from a single JSON manifest. It:

* Clones or initializes dependencies (plain clone or submodule).
* Resolves branches/tags/refs to **exact commits**.
* Checks out deterministically (detached HEAD by design).
* Writes a **lock file** so `Restore` is reproducible in dev & CI.

> Run the script **from the root of a Git repo**.

---

## Quick Start

### Requirements

* PowerShell 5.1+ or PowerShell 7+
* Git 2.23+ recommended (falls back for older)
* Execute at **repo root**

### Files

```none
config-specification.json            # manifest you edit
config-specification.lock.json       # lockfile script writes
tools/GitPackageManager.ps1          # script (path arbitrary)
```

### Minimal manifest

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

### Common commands

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

## Manifest Structure

Top-level schema:

```json
{
    "modules": [
        {
            "name": "<required string>",
            "repo": "<required git url>",
            "localPath": "<required repo-relative path>",
            "version": "<optional branch/ref/sha>",
            "tag": "<optional tag name>",
            "submodule": "<optional bool>",
            "asSubmodule": "<optional bool; legacy alias>"
        }
    ]
}
```

### Resolution Rules

* If `version` is present → resolve to commit (branch/ref/SHA). **Takes precedence** over `tag`.
* Else if `tag` is present → resolve tag to commit.
* Else → resolve **origin/HEAD** (default remote branch), falling back to `origin/main` or `origin/master`.

### Examples

* Plain clone pinned to branch:

```json
{
    "name": "lib-plain",
    "repo": "https://github.com/org/lib.git",
    "localPath": "vendor/lib",
    "version": "main"
}
```

* Submodule pinned to tag:

```json
{
    "name": "lib-sub",
    "repo": "https://github.com/org/lib.git",
    "localPath": "submodules/lib",
    "tag": "v2.0.1",
    "submodule": true
}
```

* Submodule pinned to SHA:

```json
{
    "name": "lib-sha",
    "repo": "https://github.com/org/lib.git",
    "localPath": "submodules/lib",
    "version": "a1b2c3d",
    "submodule": true
}
```

---

## Command Reference & Detailed Behavior

### Install

* Validates git root.
* Ensures each module exists: submodule (`git submodule add` + init) or plain clone.
* Resolves to **exact commit** via `version` → `tag` → `default branch`.
* Checks out (detached HEAD), hard-resets to the commit.
* If submodule: stages and commits submodule pointer if changed.
* Updates/writes the lock file.

### Update

* Same flow as Install, intended to **move forward** according to manifest rules (e.g., latest on a branch).
* Writes new `resolvedCommit` for each module.

### Restore

* Reads **lock file** as source of truth; restores to **exact commits**.
* Submodules: ensure registered, `submodule update --init --recursive -- <path>`, record current submodule HEAD in lock.
* Plain clones: ensure cloned, fetch, verify locked commit exists, checkout exact commit.

### Remove

* Submodule: `submodule deinit -f -- <path>` → `git rm -f -- <path>` → delete `.git/modules/<path>` if present → commit if index changed.
* Plain clone: remove the folder if it exists.

### Help

* Prints usage and notes.

---

## Lock File Explained

Generated by Install/Update/Restore:

```json
{
    "modules": [
        {
            "name": "sub-module-demo",
            "repo": "https://github.com/g4-api/sub-module-demo.git",
            "localPath": "submodules/sub-module-demo",
            "resolvedCommit": "ed42564f2ba4cada4c24d82d5b95e73e6c36395e"
        }
    ]
}
```

* Commit this file to version control for deterministic `Restore`.

---

## Submodules vs Plain Clones

| Aspect                                | Submodule                                    | Plain Clone                         |
| ------------------------------------- | -------------------------------------------- | ----------------------------------- |
| Tracked by parent repo index          | ✅ (160000 entry)                           | ❌                                  |
| `.gitmodules` entry                   | ✅                                          | ❌                                  |
| Parent repo records dependency commit | ✅                                          | ❌ (lockfile still records it)      |
| Best for                              | Code you want versioned with parent          | Vendor/tools not tracked in history |
| Removal                               | Deinit + `git rm` + purge `.git/modules/...` | Delete folder                       |

Detached HEAD is expected: dependencies are pinned to commits for reproducibility.

---

## Advanced Options & Workflows

### Filter by name

```powershell
.\tools\GitPackageManager.ps1 -Command Update -Name engine
```

### Mixed modes

Mix submodules and plain clones in one manifest; choose per dependency.

### Friendly tag UX

When `-Tag` is used, checkout uses the tag ref for nicer status (`HEAD detached at v1.2.3`), then hard-resets to the exact commit.

### Deterministic releases

* Use tags for released dependencies.
* Let `Update` move to new tags/commits; commit the lockfile changes.

---

## CI/CD Integration

**Deterministic build:**

```powershell
.\tools\GitPackageManager.ps1 -Command Restore
```

**Refresh dependencies pipeline:**

```powershell
.\tools\GitPackageManager.ps1 -Command Update
# open a PR with lockfile changes
```

### Notes

* Ensure Git auth works (HTTPS tokens or SSH keys).
* If CI uses shallow clones, ensure submodules can fetch their required commits (`--recursive` is already handled).

---

## Troubleshooting

**“Current directory is not a Git repository…”**
You’re not at a git root. `cd` to the directory that has `.git/`.

**“pathspec 'path' did not match any file(s) known to git”**
The path isn’t registered in `.gitmodules`. Add as submodule or set `"submodule": true` and run `Install`.

**“fatal: 'path' already exists in the index”**
Stale index from a broken submodule. Try:

```powershell
git rm --cached <path>
git add .gitmodules
git commit -m "Fix submodule index"
```

Then rerun.

**“Cannot resolve version/tag …”**
Check ref/tag spelling and remote availability:

```powershell
git ls-remote <repo>
```

**“Locked commit not found after fetch”**
Remote no longer contains that commit (GC/force-push). Use `Update` to re-resolve and write a fresh lock.

---

## Best Practices

* **Commit the lockfile**.
* Use **tags** for reproducible releases.
* Prefer **submodules** when parent history should capture the dependency pointer.
* Prefer **plain clones** for vendor code you don’t want in parent history.
* Keep `localPath` **relative**; script assumes repo root execution.
* Avoid moving tags; treat tags as immutable.

---

## End-to-End Examples

### Mixed manifest

```json
{
    "modules": [
        {
            "name": "engine",
            "repo": "https://github.com/org/engine.git",
            "localPath": "submodules/engine",
            "version": "main",
            "submodule": true
        },
        {
            "name": "ui-lib",
            "repo": "https://github.com/org/ui-lib.git",
            "localPath": "vendor/ui-lib",
            "tag": "v3.4.1"
        },
        {
            "name": "tools-scripts",
            "repo": "https://github.com/org/tools-scripts.git",
            "localPath": "tools/scripts",
            "version": "a13fcb3"
        }
    ]
}
```

#### Install everything

```powershell
.\tools\GitPackageManager.ps1 -Command Install
```

#### Update only `engine`

```powershell
.\tools\GitPackageManager.ps1 -Command Update -Name engine
```

#### Restore exact lockfile state

```powershell
.\tools\GitPackageManager.ps1 -Command Restore
```

#### Remove a module

```powershell
.\tools\GitPackageManager.ps1 -Command Remove -Name ui-lib
```

---

## FAQs

**Why does `git status` show “HEAD detached at …”?**
We pin dependencies to exact commits for reproducibility. Detached HEAD is expected and safe.

**Can I edit the lockfile manually?**
You can, but prefer `Update` to change dependency revisions and let the script write the lock.

**Do I need both Install and Update?**
Both ensure presence and resolution. `Install` is great for first setup; `Update` implies “move forward according to manifest.” For reproducible environments (dev/CI), `Restore` is ideal.

**What about nested submodules?**
The script uses `--recursive`, so nested submodules are initialized and updated.

**HTTPS vs SSH?**
Both work. HTTPS is simple in CI (with tokens). SSH is fine where keys are set up.

---

## Command-Line Options (Reference)

```powershell
.\tools\GitPackageManager.ps1 `
  -Command <Install|Restore|Update|Remove|Help> `
  [-ManifestPath <path>] `
  [-LockPath <path>] `
  [-Name <moduleName>]
```

* `-Command` — Operation to run.
* `-ManifestPath` — Path to manifest (default: `./config-specification.json`).
* `-LockPath` — Path to lock (default: `./config-specification.lock.json`).
* `-Name` — Process a specific module only.

---

## Safety & Idempotency Notes

* Commands are **idempotent**; re-running converges state.
* Submodule pin commits only happen when index changes exist.
* The script does **not** rewrite `.gitmodules` except on `submodule add`.

---

## Suggested .gitignore Additions

If you keep vendor clones untracked:

```none
vendor/
```

Track these:

```none
config-specification.json
config-specification.lock.json
.gitmodules
```

---

## Migration Playbook

1. List external dependencies you manage manually.
2. Add each to the manifest with `name`, `repo`, `localPath`, and either `version` or `tag`. Set `"submodule": true` when you want the parent repo to record the pointer.
3. Run `Install` to normalize. Commit:
   * `.gitmodules` (if any),
   * the lockfile,
   * and any submodule pointer updates.
4. In CI, use `Restore` for deterministic builds.
5. Periodically run `Update` to move forward and commit the lockfile changes.
