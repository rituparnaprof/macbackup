# MacBackup

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Architecture](https://img.shields.io/badge/Arch-Apple%20Silicon%20(arm64)-orange.svg)](https://www.apple.com/mac/)
[![Build & Release](https://github.com/rituparnaprof/macbackup/actions/workflows/build.yml/badge.svg)](https://github.com/rituparnaprof/macbackup/actions/workflows/build.yml)

**MacBackup** is a lightweight macOS menu bar utility built in SwiftUI for fast, reliable backups from your Mac SSD to external storage (USB drives or external SSDs), built specifically for Apple Silicon.

---

## What it does

- **Detects your drive automatically**: Plug in your registered external drive, and the app recognizes it and prompts you to sync right away without having to search for folders.
- **Backs up only what changed**: Only new and modified files are copied over. If an existing backup file has changed on your Mac, the older version is saved with a timestamp instead of being overwritten.
- **Verifies data integrity**: Every file is staged to a temporary file and verified against the source using SHA-256 checksums before being moved to its final location.
- **Keeps your Mac awake**: Prevents macOS from sleeping during active transfers, and automatically retries any transient read or write errors up to three times.
- **Finds deleted files**: Scans the backup drive for files that you have since removed from your Mac SSD, highlighting them as orphaned so you can review or delete them.
- **One-click drive eject**: Safely unmounts and ejects your external drive straight from the application window.
- **Runs quietly in the menu bar**: Sits in your menu bar with quick status indicators and opens into a full window whenever you want to inspect files or tweak settings.

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
