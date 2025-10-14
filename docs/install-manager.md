# Install-Manager.ps1 — Onboarding Tutorial

## Table of Contents

1. [Purpose & What This Installs](#purpose--what-this-installs)
2. [Prerequisites](#prerequisites)
3. [Repository Layout (After Install)](#repository-layout-after-install)
4. [Quick Start](#quick-start)
5. [Deep Dive: How the Script Works](#deep-dive-how-the-script-works)
6. [Parameters & Options](#parameters--options)
7. [Common Day-to-Day Flows](#common-day-to-day-flows)
8. [Git Concepts Used (Plain English)](#git-concepts-used-plain-english)
9. [Symlink Behavior on Windows/macOS/Linux](#symlink-behavior-on-windowsmacoslinux)
10. [Troubleshooting](#troubleshooting)
11. [Uninstall / Reinstall](#uninstall--reinstall)
12. [CI/CD Usage](#cicd-usage)
13. [Security & Policy Notes](#security--policy-notes)
14. [FAQ](#faq)

---

## Purpose & What This Installs

**Install-Manager.ps1** bootstraps your **Git Submodules Package Manager** into your main repository:

* **Adds (or updates) the manager repo as a Git submodule** at a path you choose (default: `submodules/git-package-manager`).
* **Exposes a stable entry point** at `tools/GitPackageManager.ps1` by creating a **relative symbolic link** into the submodule (default manager script inside the submodule: `src/GitPackageManager.ps1`).
* **Stages** the necessary changes (`.gitmodules`, submodule path, and `tools/GitPackageManager.ps1`) so you can commit them.

Think of it as installing a “package manager CLI” into your repo using Git-native building blocks (submodule + symlink).

---

## Prerequisites

* Run from the **root of your main Git repository** (must contain a `.git` folder).
* **Git CLI** available on PATH.
* **PowerShell** (pwsh or Windows PowerShell).
* **Symlink permission**:

  * **Windows**: enable **Developer Mode** *or* run PowerShell **as Administrator**.
  * **macOS/Linux**: standard user privileges are typically fine.

---

## Repository Layout (After Install)

```none
<your-repo-root>/
├─ .git/
├─ .gitmodules                 # records submodule(s)
├─ submodules/
│  └─ git-package-manager/     # the manager repo as a submodule
│     └─ src/
│        └─ GitPackageManager.ps1
└─ tools/
   └─ GitPackageManager.ps1    # symlink -> ../submodules/git-package-manager/src/GitPackageManager.ps1
```

You’ll commit `.gitmodules`, the submodule folder, and the symlink so teammates/CI get the same setup.

---

## Quick Start

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

> Tip: If Windows blocks symlink creation, see [Symlink Behavior](#symlink-behavior-on-windowsmacoslinux) and [Troubleshooting](#troubleshooting).

---

## Deep Dive: How the Script Works

1. **Guards location** — verifies you’re in the repo root (`.git` exists).
2. **Resolves paths** — submodule folder, the internal manager script, and the external symlink (`tools/GitPackageManager.ps1`).
3. **Ensures submodule exists**

   * If missing → `git submodule add <ManagerRepoUrl> <SubmodulePath>`.
   * If present → verifies origin URL and suggests how to change it (non-destructive).
4. **Initializes/updates the submodule**

   * `git submodule sync` for URL/path sync.
   * `git submodule update --init --recursive` to fetch the content.
5. **Validates manager script** — checks that `<SubmodulePath>/<ManagerScriptPath>` exists.
6. **Creates/refreshes symlink**

   * Removes any existing file/link at `tools/GitPackageManager.ps1`.
   * Creates a **relative** symbolic link pointing into the submodule’s script.
7. **Stages for commit** — `git add .gitmodules <SubmodulePath> tools/GitPackageManager.ps1`.
8. **Prints final instructions** — shows the commit command you can run.

The process is **idempotent**: safe to re-run; it will sync/refresh everything.

---

## Parameters & Options

All are **optional** with sensible defaults:

* `-ManagerRepoUrl`
  Git URL to the manager repo (default: `https://github.com/g4-api/git-submodules-manager.git`).

* `-SubmodulePath`
  Where to place the manager submodule inside your repo (default: `submodules/git-package-manager`).
  Use a **single, consistent submodules root** for cleanliness.

* `-ManagerScriptPath`
  The path **inside the submodule** to the entry script (default: `src/GitPackageManager.ps1`).
  If the manager repo reorganizes, adjust this.

### Examples

* Install from a fork:

  ```pwsh
  pwsh ./Install-Manager.ps1 -ManagerRepoUrl "https://github.com/you/git-submodules-manager.git"
  ```

* Use a different submodule location:

  ```pwsh
  pwsh ./Install-Manager.ps1 -SubmodulePath "external/git-pm"
  ```

* Manager script moved inside submodule:

  ```pwsh
  pwsh ./Install-Manager.ps1 -ManagerScriptPath "tools/entry.ps1"
  ```

---

## Common Day-to-Day Flows

### First-Time Setup (per repo)

```pwsh
pwsh ./Install-Manager.ps1
git commit -m "Install Git Package Manager submodule and expose tools/GitPackageManager.ps1"
git push
```

### Refresh/Re-run (safe)

* If the submodule already exists, the script will **sync** and **update** it.
* It will also **recreate the symlink** if needed.

### Switch Manager Source (e.g., move from upstream to fork)

```pwsh
pwsh ./Install-Manager.ps1 -ManagerRepoUrl "https://github.com/you/git-submodules-manager.git"
# If you want to actually change the remote:
git -C submodules/git-package-manager remote set-url origin "https://github.com/you/git-submodules-manager.git"
git submodule sync -- submodules/git-package-manager
git submodule update --init --recursive -- submodules/git-package-manager
git add .gitmodules submodules/git-package-manager
git commit -m "Point manager submodule to new origin"
```

### If Manager Script Moves (inside submodule)

```pwsh
pwsh ./Install-Manager.ps1 -ManagerScriptPath "new/path/GitPackageManager.ps1"
git commit -m "Refresh manager symlink to new internal path"
```

### Use the Manager After Install

```pwsh
# examples (your manager supports these)
pwsh ./tools/GitPackageManager.ps1 -Command restore
pwsh ./tools/GitPackageManager.ps1 -Command install -Commit
pwsh ./tools/GitPackageManager.ps1 -Command update  -Name sub-module-poc -Tag v1.2.3 -Commit
pwsh ./tools/GitPackageManager.ps1 -Command remove  -Name sub-module-poc -Commit
```

---

## Git Concepts Used (Plain English)

* **Submodule**: a *repo inside your repo*. It’s linked, not copied. Your repo records a **commit pointer** to that nested repo.
* **.gitmodules**: config file in your repo that stores submodule `path` and `url`. It’s versioned with your code.
* **`git submodule add`**: registers a new submodule (creates the folder, writes `.gitmodules`).
* **`git submodule update --init --recursive`**: fetches the submodule content and initializes nested submodules (if any).
* **Staging**: `git add` queues files for the next commit (here: `.gitmodules`, submodule folder, symlink).
* **Commit**: records your change to history so teammates/CI get the same state when they pull.

---

## Symlink Behavior on Windows/macOS/Linux

* The script creates a **symbolic link** at `tools/GitPackageManager.ps1` pointing **into** the submodule’s entry script.
* **Windows**: requires **Developer Mode** enabled *or* **Administrator** PowerShell to create symlinks.

  * If blocked, you’ll see an error on `New-Item -ItemType SymbolicLink`.
  * Workarounds: enable Developer Mode, or run PowerShell **as Admin**.
* **Relative** link: robust if the repo root moves as a unit (e.g., different parent folder), because the relative path still resolves.

---

## Troubleshooting

**“This script must be run from your main repository git root”**
→ You’re not in the repo root. `cd` into the folder containing `.git` and run again.

**Submodule URL mismatch warning**
→ The submodule already exists, but its origin differs from `-ManagerRepoUrl`.
Use:

```pwsh
git -C <SubmodulePath> remote set-url origin "<ManagerRepoUrl>"
git submodule sync -- <SubmodulePath>
git submodule update --init --recursive -- <SubmodulePath>
```

**Manager script not found inside submodule**
→ Check `-ManagerScriptPath` matches the actual file inside the manager repo. Update the parameter and re-run.

**Symlink creation fails on Windows**
→ Enable **Developer Mode** or run PowerShell **as Administrator**. Then re-run the script.

**Git not found**
→ Ensure `git` is installed and available on PATH.

**Symlink points to the wrong place**
→ Re-run `Install-Manager.ps1` (it removes and recreates the link). Or delete `tools/GitPackageManager.ps1` and re-run.

---

## Uninstall / Reinstall

**Remove the manager from your repo:**

```pwsh
# Remove symlink
Remove-Item -LiteralPath tools/GitPackageManager.ps1 -Force

# Remove submodule cleanly
git submodule deinit -f submodules/git-package-manager
git rm -f submodules/git-package-manager
# Optionally purge internal submodule metadata folder if left:
Remove-Item -Recurse -Force .git/modules/submodules/git-package-manager -ErrorAction SilentlyContinue

git commit -m "Remove Git Package Manager"
git push
```

**Reinstall**: run `pwsh ./Install-Manager.ps1` again (with parameters if needed).

---

## CI/CD Usage

* Add a step that runs the installer **once** (usually not needed on every CI run once it’s committed).
* Typical pipeline steps:

  1. `git clone --recurse-submodules …`  (or `git submodule update --init --recursive`)
  2. Run the manager:

     ```pwsh
     pwsh ./tools/GitPackageManager.ps1 -Command restore
     # optionally:
     pwsh ./tools/GitPackageManager.ps1 -Command install -Commit
     ```

* If your CI agent lacks symlink privileges on Windows, ensure the repo already includes the link (committed) — Git will check it out as a link.

---

## Security & Policy Notes

* The **manager repo** is third-party/internal code — review before adopting.
* **Lockfile** (if your manager uses one) pins exact commits for reproducibility.
* Keep **`.gitmodules`** and submodule **URLs** under code review to prevent injection of unexpected sources.

---

## FAQ

**Q: Do my teammates need to run Install-Manager.ps1?**
A: Only once per repo setup. After it’s committed, teammates just clone and use `tools/GitPackageManager.ps1`.

**Q: Can we move the submodule later?**
A: Yes. Change `-SubmodulePath`, re-run the installer, commit updates. Git will track the new location in `.gitmodules`.

**Q: Our manager entry script moved inside its own repo — what now?**
A: Re-run with `-ManagerScriptPath` pointing to the new path. The installer will recreate the symlink.

**Q: We prefer no symlinks.**
A: You can copy the script instead of linking, but you’ll lose automatic updates when the submodule updates. The symlink is the cleanest “always up to date” entry point.

**Q: Do we need `git submodule update --init --recursive` ourselves?**
A: The installer runs it for the manager submodule. For your *dependencies* managed by the manager, you’ll still use `tools/GitPackageManager.ps1` (e.g., `restore`, `install`).
