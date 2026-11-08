# MacBackup Architecture & Design 🏗️

This document details the internal design, components, and data flow of **MacBackup v2.1.0**.

---

## 1. High-Level Architecture Flow

```mermaid
flowchart TD
    A["🔌 Connect External Drive"] --> B["NSWorkspace.didMountNotification"]
    B --> C{"Inspect Target Folder"}
    C -- "No manifest found" --> D["State: unregistered"]
    C -- "manifest.machineId == localMachine" --> E["State: pairedThisMac"]
    C -- "manifest.machineId != localMachine" --> F["State: pairedOtherMac (Migration Mode)"]
    
    E --> G["Live Sync Percentage & Regular Sync"]
    F --> H["Freeze Orphan Detection & Show Migration Assistant"]
    
    subgraph MigrationAssistant ["Migration Mode Workflows"]
        H --> H1["Restore Everything to this Mac"]
        H --> H2["Auto-Link Standard Folders"]
        H --> H3["Pair & Adopt Drive on this Mac"]
    end
    
    subgraph DataOperations ["Data Operations Pipeline"]
        G --> OP1["Incremental Backup (Mac SSD -> Drive)"]
        H1 --> OP2["Pre-Flight Space Guard & Full Restore"]
        OP3["Selective File / Folder Restore"]
        OP4["Orphan Review & Reclaimable Space Analytics"]
        OP5["Graceful Mid-Stream Cancel & .tmp Cleanup"]
        OP6["Security Boundary & Symlink Defense"]
    end
```

---

## 2. Core Components

### `BackupManifest.swift`
- **Data Model**: Implements `BackupManifest`, `SourceMapping`, and `MachineMetadata` conforming to `Codable` and `Sendable`. Versioned at `"2.1.0"`.
- **On-Disk Manifest**: Stored in a hidden container directory `.macbackup/manifest.json` on the target volume.
- **Machine Identification**: Compares persistent `machineId` in `UserDefaults` against the manifest's `lastBackupMachine.machineId`.
  - When matching: the current machine is recognized as the owner.
  - When non-matching: automatically engages **Migration Mode**, freezing orphan marking so that files from the previous Mac are protected from accidental deletion.

### `BackupManager.swift`
The central observable engine (`ObservableObject`), handling all backup, restore, metrics, security checks, and lifecycle events:
1. **Path Security & Boundary Containment**:
   - `PathSecurity.relativeSubpath`: Canonical prefix stripping to eliminate path traversal vulnerabilities and duplicate directory collisions.
   - `PathSecurity.isSubpath`: Enforces hard boundary checks on all deletion (`deleteNode`, `deleteSelectedNodes`) and recovery (`recoverOrphan`) operations to ensure no files outside the backup volume can ever be modified or removed.
2. **Drive Registration & Lifecycle**:
   - Manages four distinct states: `.disconnected`, `.unregistered`, `.pairedThisMac`, and `.pairedOtherMac`.
   - `deregisterFromThisMac()`: Unlinks the drive from the current Mac's local preferences without altering any backup data.
   - `deregisterAndWipeMetadata()`: Removes `.macbackup/` container metadata while preserving user files.
   - `adoptBackupForThisMac()`: Updates the manifest's owning machine to the current Mac, re-enabling regular backup sync.
   - `autoLinkStandardFolders()`: Matches folders recorded in the manifest with corresponding local directories on the current user's Mac (`~/Documents`, `~/Desktop`, `~/Pictures`, etc.).
3. **Fail-Safe Incremental Backup**:
   - Re-entrancy guards prevent overlapping executions (`guard !isBackingUp && !isRestoring`).
   - Sleep prevention via scoped `ProcessInfo` activity assertions.
   - Cross-filesystem timestamp tolerance: 2.0-second window plus post-copy timestamp synchronization to prevent FAT32/exFAT duplicate archive loops.
   - Sequence numbering on archive collisions (`_1`, `_2`) to prevent accidental deletion of historical versions.
   - Per-file error isolation: transient file read failures (e.g. temporary caches) are safely skipped without aborting the broader backup job.
   - Symlink cycle suppression: skips directory symlinks to avoid recursion loops and private credential leaks.
4. **Storage & Reclaimable Space Analytics**:
   - `StorageMetrics` tracks total volume capacity, free space, active backup footprint, version archives, and space consumed by orphaned files.
   - Real-time Mac SSD free space monitoring for pre-flight safety checks.
5. **Live Performance & Graceful Cancellation**:
   - Real-time throughput (`transferRateFormatted` in MB/s) and rolling ETA (`estimatedTimeRemainingFormatted`).
   - `cancelTransfer()`: Instantly halts active transfers and immediately purges orphaned `.tmp` files.
6. **Restore Engine & Space Guard**:
   - `canRestore(bytesNeeded:)`: Validates destination Mac SSD storage with a safety margin before initiating recovery.
   - Atomic replacement: uses `FileManager.replaceItemAt` during overwrite restores to guarantee the original file is preserved if transfer fails.
   - Safe conflict policies: `Keep Both` (with sequence numbering), `Overwrite`, and `Skip If Exists`.
7. **Algorithmic Performance & Caching**:
   - Fast $O(1)$ node lookup dictionary (`nodeLookup`) replacing recursive $O(M \times N)$ traversals during selection actions.
   - Cached `allOrphans` and `allVersionedArchives` arrays to maintain 60/120 FPS SwiftUI list scrolling.
   - Static pre-compiled regular expressions for timestamp matching.

### `ContentView.swift`
- **Segmented Views**:
   - **Backup View**: Hierarchical tree explorer, file preview, live throughput (MB/s), ETA, progress bar with instant Cancel, and source folder pickers.
   - **Restore View**: Destination picker, Mac SSD free space indicator, conflict policy menu, one-click "Restore All to This Mac", and "Restore Checked" with pre-restore space verification.
   - **Orphan Cleanup View**: Reclaimable space header badge, dedicated filter for orphaned items and versioned archives, individual/batch "Recover to Mac", and protected deletion.
- **Migration Assistant Banner**: Displayed prominently whenever a drive from another Mac is connected, featuring 1-click **Auto-Link Folders**, **Restore**, and **Pair Drive**.
- **Sidebar**: Real-time status badge, visual storage usage bar (used/free), volume path, eject button, and drive management menu.

---

## 3. Data Safety & Integrity Model

| Failure Mode | Mitigation in MacBackup v2.1.0 |
| :--- | :--- |
| **Infinite Hashing Loop (DoS)** | `hashFile` checks `!data.isEmpty` on `FileHandle.read` EOF. |
| **Path Traversal / Name Collision** | `PathSecurity.relativeSubpath` canonical prefix stripping. |
| **Arbitrary File Deletion** | `PathSecurity.isSubpath` enforces strict boundary inside target folder. |
| **FAT32 Timestamp Jitter Loop** | 2.0-second tolerance window + post-copy timestamp synchronization. |
| **Archive Collision Loss** | Sequence numbering (`_1`, `_2`) prevents deleting past archives. |
| **Restore Overwrite Data Loss** | Atomic replacement via `FileManager.replaceItemAt`. |
| **Symlink Recursion / Leaks** | Symlink detection and directory symlink suppression. |
| **Transient File Abort** | Per-file `do/catch` error isolation prevents backup failure. |
| **Sleep Assertion Leak** | Scoped `activityToken` lifecycle tied to async task `defer`. |
| **Re-entrancy Corruption** | `guard !isBackingUp && !isRestoring` on all entry points. |
| **New Mac False Orphans** | Manifest machine detection automatically engages Migration Mode and freezes orphan status. |

---

## 4. Build & Distribution System

- **Target Architecture**: Apple Silicon (`arm64-apple-macosx`) exclusively.
- **CI/CD Automation**: GitHub Actions workflow ([`.github/workflows/build.yml`](file:///.github/workflows/build.yml)) runs unit tests (`swift test`), compiles release binaries, packages `.dmg`, and publishes releases on version tags.
