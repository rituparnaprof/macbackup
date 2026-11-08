# MacBackup

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-2.4.0-blue.svg)](https://github.com/rituparnaprof/macbackup/releases)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Architecture](https://img.shields.io/badge/Arch-Apple%20Silicon%20(arm64)-orange.svg)](https://www.apple.com/mac/)
[![Build & Release](https://github.com/rituparnaprof/macbackup/actions/workflows/build.yml/badge.svg)](https://github.com/rituparnaprof/macbackup/actions/workflows/build.yml)

**MacBackup** is a lightweight macOS menu bar utility built in SwiftUI for fast, reliable backups from your Mac SSD to external storage (USB drives or external SSDs), built specifically for Apple Silicon.

---

## What it does

- **Interactive Source & Destination Folder Restore Mapping**: When restoring, you have total control over what folder to restore where. Map individual backed-up source folders (`Documents`, `Desktop`, `Pictures`, etc.) to custom destinations on your Mac with individual folder pickers, 1-click **Auto-Map to This Mac** (~/Documents, ~/Desktop, etc.), batch **Set Common Destination...**, conflict resolution (`Keep Both`, `Overwrite`, `Skip`), and pre-flight Mac SSD space guards.
- **Orphan-Safe Restores (Excludes Deleted Files by Default)**: Folder and tree restores restore active files only by default, excluding orphaned files (files previously deleted from your Mac) and version archives to prevent clutter. Optional checkboxes allow including orphans or version archives when specifically desired.
- **Selective File & Folder Tree Browser**: Switch between high-level folder mapping and a granular tree browser to inspect backup files, search with instant filter, inspect orphaned items with visual badges, and selectively restore specific items to any location.
- **Smart Drive Auto-Discovery & Interactive Setup Assistant**: On app launch or whenever an external drive is attached, MacBackup automatically scans mounted volumes (`/Volumes/*`) for existing `.macbackup/` repositories. An intelligent setup assistant pops up and asks whether this is the **Same Mac** (1-click reconnect and resume backups) or a **New Mac** (1-click restore or pair & adopt), eliminating manual folder picking and configuration confusion.
- **Global Persistent Status Footer**: Essential sync and backup metrics—Last Backup time, New Files count, Modified Files count, Total Items, release version (`v2.4.0`), and dedication (*"Made for my Love - DG"*)—are permanently visible at the bottom of the window across all views (Backup, Restore, and Orphan Cleanup).
- **Auto-detection & Seamless Migration**: Plug in your registered external drive, and the app recognizes it and prompts you to sync right away. If connecting a backup from another MacBook, it automatically switches to Migration Mode, freezes false-orphan markings, and offers 1-click folder auto-linking, restore, or machine pairing.
- **Backs up only what changed**: Only new and modified files are copied over. If an existing backup file has changed on your Mac, the older version is saved with a timestamp instead of being overwritten.
- **Storage & Reclaimable Space Analytics**: Visual capacity breakdown showing total drive size, free space, active backup footprint, version archives, and reclaimable space consumed by orphaned files.
- **Live Transfer Speed, Rolling ETA & Cancellation**: Monitor real-time throughput (MB/s) and estimated time remaining during transfers, with instant graceful cancellation and immediate cleanup of temporary `.tmp` files.
- **Complete data restoration with Pre-Flight Space Guard**: Full machine recovery or selective file/folder restore with configurable collision policies (Keep Both, Overwrite, Skip If Exists) directly to your Mac, guarded by an automated Mac SSD free space check.
- **Verifies data integrity both ways**: Every file transferred during backup or restore is staged to a temporary file and verified against the source using SHA-256 checksums before atomic move.
- **Keeps your Mac awake**: Prevents macOS from sleeping during active transfers, and automatically retries any transient read or write errors up to three times.
- **Dedicated orphan and archive management**: Scans for files removed from your Mac SSD in a dedicated view, allowing you to recover them back to your Mac or safely delete them with automatic safeguards against accidental bulk deletion.
- **Robust drive registration & deregistration**: Clear status messaging ("No Drive Configured" vs "Drive Synced"), unlinking from the current Mac, or cleanly erasing container metadata without losing backup files.
- **One-click drive eject**: Safely unmounts and ejects your external drive straight from the application window.
- **Runs quietly in the menu bar**: Sits in your menu bar with quick status indicators (green = synced, orange = migration mode, red = disconnected) and opens into a full window whenever you want to inspect files, restore, or tweak settings.

For technical details, component breakdown, and system design, see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Requirements

- **Operating System**: macOS 13.0 (Ventura) or later
- **Architecture**: Apple Silicon (`arm64` - M1/M2/M3/M4 or later) exclusively
- **Toolchain**: Swift 5.9+ / Xcode 15+ (for compiling from source)

---

## Installation & Getting Started

### Option 1: Download Pre-Built DMG

1. Download **`MacBackup.dmg`** from the [Releases](https://github.com/rituparnaprof/macbackup/releases) page.
2. Open the disk image and drag **`MacBackup.app`** to your `/Applications` folder.
3. **Bypassing macOS Gatekeeper (`xattr`)**:
   > [!NOTE]
   > Because this is a free, independent open-source project without a paid Apple Developer subscription, the binary is not notarized by Apple. macOS Gatekeeper will flag downloaded binaries with *"cannot be opened because the developer cannot be verified"* or *"is damaged"*.
   >
   > To clear the macOS quarantine attribute, open **Terminal** and run:
   > ```bash
   > xattr -cr /Applications/MacBackup.app
   > ```
   > *(Alternatively: Right-click / Control-click `MacBackup.app` in Finder, select **Open**, and click **Open** in the confirmation dialog).*

---

### Option 2: Build & Run Locally from Source (No Developer Certificate Needed)

Building the application on your own Mac automatically ad-hoc signs the binary locally, so macOS will run it without quarantine warnings:

1. **Install Prerequisites**: Ensure the Swift toolchain is installed (via Xcode or Command Line Tools):
   ```bash
   xcode-select --install
   ```

2. **Clone the Repository**:
   ```bash
   git clone https://github.com/rituparnaprof/macbackup.git
   cd macbackup
   ```

3. **Run Directly via Swift PM**:
   ```bash
   swift run MacBackup
   ```

4. **Or Build a Standalone `.app` for `/Applications`**:
   ```bash
   # Compile optimized release binary for Apple Silicon
   swift build -c release --triple arm64-apple-macosx

   # Assemble local .app bundle
   mkdir -p MacBackup.app/Contents/MacOS MacBackup.app/Contents/Resources
   cp "$(swift build --show-bin-path -c release --triple arm64-apple-macosx)/MacBackup" MacBackup.app/Contents/MacOS/
   cp assets/MacBackup.icns MacBackup.app/Contents/Resources/AppIcon.icns

   # Copy to your Applications folder
   cp -R MacBackup.app /Applications/
   ```

---

## Important Warnings & Disclaimers

### 1. Data Deletion Warning (`deleteNode`)
> [!CAUTION]
> Deleting files or folders from within the backup file tree (such as cleaning orphaned files) permanently deletes them from your external storage volume immediately using `FileManager.removeItem`.
> 
> **Items are NOT moved to the macOS Trash** and **cannot be recovered**. Always double-check your selection before confirming any single or bulk deletion action.

### 2. AI / LLM Implementation Notice
> [!NOTE]
> Most of the code in this repository was generated with the assistance of Large Language Models (LLMs). The core concept, system architecture, functional specifications, and validation were designed and directed by the author.

### 3. Apple Trademark Disclaimer
> [!IMPORTANT]
> Mac, macOS, and Apple are trademarks of Apple Inc., registered in the U.S. and other countries. **MacBackup** is an independent open-source project and is not affiliated with, endorsed by, sponsored by, or associated with Apple Inc.

---

## License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See the [LICENSE](LICENSE) file for the full license text.
