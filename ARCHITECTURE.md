# MacBackup Architecture & Design 🏗️

This document details the internal design, components, and data flow of **MacBackup v2.0**.

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
    end
```

---

## 2. Core Components

### `BackupManifest.swift`
- **Data Model**: Implements `BackupManifest`, `SourceMapping`, and `MachineMetadata` conforming to `Codable` and `Sendable`. Versioned at `"2.0"`.
- **On-Disk Manifest**: Stored in a hidden container directory `.macbackup/manifest.json` on the target volume.
- **Machine Identification**: Compares persistent `machineId` in `UserDefaults` against the manifest's `lastBackupMachine.machineId`.
  - When matching: the current machine is recognized as the owner.
  - When non-matching: automatically engages **Migration Mode**, freezing orphan marking so that files from the previous Mac are protected from accidental deletion.

### `BackupManager.swift`
The central observable engine (`ObservableObject`), handling all backup, restore, metrics, and lifecycle events:
1. **Drive Registration & Lifecycle**:
   - Manages four distinct states: `.disconnected`, `.unregistered`, `.pairedThisMac`, and `.pairedOtherMac`.
   - `deregisterFromThisMac()`: Unlinks the drive from the current Mac's local preferences without altering any backup data.
   - `deregisterAndWipeMetadata()`: Removes `.macbackup/` container metadata while preserving user files.
   - `adoptBackupForThisMac()`: Updates the manifest's owning machine to the current Mac, re-enabling regular backup sync.
   - `autoLinkStandardFolders()`: Automatically matches folders recorded in the manifest with corresponding local directories on the current user's Mac (`~/Documents`, `~/Desktop`, `~/Pictures`, etc.).
2. **Fail-Safe Incremental Backup**:
   - Sleep prevention via `ProcessInfo.processInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled])`.
   - Timestamp archiving: Older target files are renamed to `[name]_[YYYYMMDD_HHmmss].[ext]` before modified source files are written.
   - Staged atomic writes (`.tmp` -> SHA-256 verify -> atomic move).
   - Dynamic update of `sources` mappings in the container manifest.
3. **Storage & Reclaimable Space Analytics**:
   - `StorageMetrics` tracks total volume capacity, free space, active backup footprint, version archives, and space consumed by orphaned files.
   - Real-time Mac SSD free space monitoring for pre-flight safety checks.
4. **Live Performance & Graceful Cancellation**:
   - Real-time throughput (`transferRateFormatted` in MB/s) and rolling ETA (`estimatedTimeRemainingFormatted`).
   - `cancelTransfer()`: Instantly halts active transfers and immediately purges orphaned `.tmp` files.
5. **Restore Engine & Space Guard**:
   - `canRestore(bytesNeeded:)`: Validates that destination Mac SSD has sufficient storage plus a 1 GB safety buffer before starting recovery.
   - Reverse safe staging: copies from external drive to a local `.tmp` file, computes SHA-256 checksums, and atomically moves to destination.
   - Conflict policies:
     - `Keep Both`: appends `(Restored)` or `(Restored N)` to avoid overwriting existing work.
     - `Overwrite`: safely replaces existing files after checksum verification.
     - `Skip If Exists`: preserves local files.
6. **Orphan Management & Safety Guards**:
   - Automatically pauses orphan marking when `isMigrationMode` is active or when local `sourceFolders` are empty.
   - **Safety Guard**: If over 50% of files on the backup disk appear to have no local match, orphan deletion is hard-locked to prevent accidental mass deletion.
   - Flat list helpers (`allOrphans`, `allVersionedArchives`) for dedicated review.
   - Reverse recovery action: `recoverOrphan(node:to:)` to restore deleted files directly back to the Mac SSD.

### `ContentView.swift`
- **Top Segmented Views**:
   - **Backup View**: Hierarchical tree explorer, file preview, live throughput (MB/s), ETA, progress bar with instant Cancel, and source folder pickers.
   - **Restore View**: Destination picker, Mac SSD free space indicator, conflict policy menu, one-click "Restore All to This Mac", and "Restore Checked" with pre-restore space verification.
   - **Orphan Cleanup View**: Reclaimable space header badge, dedicated filter for orphaned items and versioned archives, individual/batch "Recover to Mac", and protected deletion.
- **Migration Assistant Banner**: Displayed prominently whenever a drive from another Mac is connected, featuring 1-click **Auto-Link Folders**, **Restore**, and **Pair Drive**.
- **Sidebar**: Real-time status badge, visual storage usage bar (used/free), volume path, eject button, and drive management menu.

---

## 3. Data Safety & Integrity Model

| Failure Mode | Mitigation in MacBackup v2.0 |
| :--- | :--- |
| **New Mac False Orphans** | Manifest machine detection automatically engages Migration Mode and freezes orphan status. |
| **Accidental Overwrites** | Prior versions timestamp-archived during backup; `Keep Both` policy available during restore. |
| **Silent Bit Rot / Glitches** | SHA-256 double-hashing on both backup writes and restore writes. |
| **System Sleep Mid-Transfer** | `ProcessInfo` sleep prevention activity assertion on both backup and restore jobs. |
| **Unintended Orphan Deletion**| Deletion hard-locked when >50% orphans detected or sources unlinked. |
| **Destination Disk Exhaustion**| `canRestore(bytesNeeded:)` checks Mac SSD free space before initiating data transfer. |
| **Partial Writes on Cancel** | `cancelTransfer()` safely deletes incomplete `.tmp` staging files. |

---

## 4. Build & Distribution System

- **Target Architecture**: Apple Silicon (`arm64-apple-macosx`) exclusively.
- **CI/CD Automation**: GitHub Actions workflow ([`.github/workflows/build.yml`](file:///.github/workflows/build.yml)) triggers on release tags (`v*`, numeric) to compile, package `.dmg`, and publish releases.
