//
//  BackupManager.swift
//  MacBackup
//
//  Copyright (C) 2024-2026 MacBackup Contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import Combine
import AppKit
import SwiftUI
import CryptoKit

public struct FileSystemNode: Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let modificationDate: Date
    public let size: Int64
    public var isOrphaned: Bool
    public var isVersionedArchive: Bool
    public var children: [FileSystemNode]?

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        modificationDate: Date,
        size: Int64,
        isOrphaned: Bool = false,
        isVersionedArchive: Bool = false,
        children: [FileSystemNode]? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.size = size
        self.isOrphaned = isOrphaned
        self.isVersionedArchive = isVersionedArchive
        self.children = children
    }
}

public enum DriveRegistrationState: Equatable {
    case disconnected
    case unregistered
    case pairedThisMac
    case pairedOtherMac
}

public enum ConflictPolicy: String, CaseIterable, Identifiable {
    case keepBoth = "Keep Both (Append (Restored))"
    case overwrite = "Overwrite Existing"
    case skip = "Skip If Exists"

    public var id: String { rawValue }
}

public struct StorageMetrics {
    public var totalDriveCapacity: Int64 = 0
    public var freeDriveSpace: Int64 = 0
    public var activeBackupSize: Int64 = 0
    public var orphanedFilesSize: Int64 = 0
    public var archivedVersionsSize: Int64 = 0
    public var macSSDFreeSpace: Int64 = 0
    public var orphanCount: Int = 0
    public var versionCount: Int = 0
    public var activeFileCount: Int = 0

    public var usedDriveSpace: Int64 {
        max(0, totalDriveCapacity - freeDriveSpace)
    }

    public var reclaimableSpaceFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: orphanedFilesSize)
    }
}

public class BackupManager: ObservableObject {
    @Published public var sourceFolders: [URL] = []
    @Published public var targetFolder: URL?
    @Published public var targetNodes: [FileSystemNode] = []
    
    // Backup State
    @Published public var isBackingUp = false
    @Published public var backupStatus = ""
    @Published public var showingBackupPrompt = false
    @Published public var checkedNodes: Set<String> = []
    @Published public var isDriveConnected = false
    @Published public var pendingBackupPercentage: Double = 0
    @Published public var lastBackupDate: Date?
    @Published public var newFilesAdded: Int = 0
    @Published public var modifiedFilesUpdated: Int = 0

    // Drive & Machine Lifecycle
    @Published public var driveState: DriveRegistrationState = .disconnected
    @Published public var currentManifest: BackupManifest? = nil
    @Published public var isMigrationMode: Bool = false
    @Published public var orphanSafetyLocked: Bool = false

    // Storage Analytics
    @Published public var storageMetrics = StorageMetrics()

    // Restore State
    @Published public var isRestoring = false
    @Published public var restoreStatus = ""
    @Published public var restoreProgress: Double = 0.0
    @Published public var restoredFilesCount: Int = 0

    // Real-Time Transfer Metrics & Cancellation
    @Published public var currentFileName: String = ""
    @Published public var transferRateFormatted: String = ""
    @Published public var estimatedTimeRemainingFormatted: String = ""
    @Published public var totalBytesTransferred: Int64 = 0
    @Published public var totalBytesToTransfer: Int64 = 0

    // Stored Preferences
    @AppStorage("registeredDriveUUID") public var registeredDriveUUID: String = ""
    @AppStorage("savedTargetFolderPath") public var savedTargetFolderPath: String = ""
    @AppStorage("savedSourceFolderPaths") public var savedSourceFolderPaths: String = ""
    @AppStorage("savedLastBackupDate") public var savedLastBackupDate: Double = 0

    private let fileManager = FileManager.default
    private var cancellables = Set<AnyCancellable>()
    private var activityToken: NSObjectProtocol?
    @Published public var isCancelRequested = false

    public init() {
        if savedLastBackupDate > 0 {
            lastBackupDate = Date(timeIntervalSince1970: savedLastBackupDate)
        }
        
        if !savedSourceFolderPaths.isEmpty {
            let paths = savedSourceFolderPaths.components(separatedBy: "|")
            sourceFolders = paths.compactMap { path in
                let url = URL(fileURLWithPath: path)
                return fileManager.fileExists(atPath: url.path) ? url : nil
            }
        }
        
        if !savedTargetFolderPath.isEmpty {
            targetFolder = URL(fileURLWithPath: savedTargetFolderPath)
        }
        
        checkDriveConnectionStatus()
        
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
            .sink { [weak self] notification in
                self?.handleDriveMount(notification: notification)
            }
            .store(in: &cancellables)
            
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
            .sink { [weak self] notification in
                self?.handleDriveUnmount(notification: notification)
            }
            .store(in: &cancellables)
    }

    // MARK: - Cancellation

    public func cancelTransfer() {
        isCancelRequested = true
        if isBackingUp {
            backupStatus = "Cancelling backup..."
        }
        if isRestoring {
            restoreStatus = "Cancelling restore..."
        }
    }

    // MARK: - Drive Connection & Status

    public func checkDriveConnectionStatus() {
        guard !registeredDriveUUID.isEmpty else {
            isDriveConnected = false
            driveState = .unregistered
            return
        }
        
        let mountedVolumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
        let matchingVolume = mountedVolumes.first { url in
            (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == registeredDriveUUID
        }
        
        isDriveConnected = matchingVolume != nil
        if isDriveConnected, let target = targetFolder, fileManager.fileExists(atPath: target.path) {
            inspectTargetFolder(target)
        } else {
            driveState = .disconnected
        }
    }

    private func inspectTargetFolder(_ folder: URL) {
        if let manifest = ManifestManager.load(from: folder) {
            currentManifest = manifest
            let localMachine = MachineMetadata.current()
            if manifest.lastBackupMachine.machineId == localMachine.machineId {
                driveState = .pairedThisMac
                isMigrationMode = false
            } else {
                driveState = .pairedOtherMac
                isMigrationMode = true
            }
        } else {
            currentManifest = nil
            driveState = .unregistered
            isMigrationMode = false
        }
        refreshTargetFiles()
        calculateSyncStatus()
        calculateStorageMetrics()
    }

    private func handleDriveMount(notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        
        if let uuid = try? volumeURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString, uuid == registeredDriveUUID {
            DispatchQueue.main.async {
                self.isDriveConnected = true
                let targetURL = URL(fileURLWithPath: self.savedTargetFolderPath)
                var isDir: ObjCBool = false
                if !self.fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDir) {
                    self.targetFolder = volumeURL
                    self.savedTargetFolderPath = volumeURL.path
                } else {
                    self.targetFolder = targetURL
                }
                
                if let target = self.targetFolder {
                    self.inspectTargetFolder(target)
                }
                
                NotificationCenter.default.post(name: Notification.Name("RegisteredDriveMounted"), object: nil)
                
                // Bring app to foreground
                NSApp.activate(ignoringOtherApps: true)
                if !self.isMigrationMode {
                    self.showingBackupPrompt = true
                }
            }
        }
    }
    
    private func handleDriveUnmount(notification: Notification) {
        DispatchQueue.main.async {
            self.checkDriveConnectionStatus()
            if !self.isDriveConnected {
                self.targetFolder = nil
                self.targetNodes = []
                self.currentManifest = nil
                self.driveState = .disconnected
                self.isMigrationMode = false
                self.storageMetrics = StorageMetrics()
            }
        }
    }

    // MARK: - Registration & Deregistration

    public func selectSourceFolders() {
        let panel = NSOpenPanel()
        panel.title = "Select Source Folders"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        
        if panel.runModal() == .OK {
            sourceFolders = panel.urls
            savedSourceFolderPaths = panel.urls.map { $0.path }.joined(separator: "|")
            refreshTargetFiles()
            calculateSyncStatus()
            calculateStorageMetrics()
        }
    }

    public func selectTargetFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Target (USB) Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            targetFolder = url
            savedTargetFolderPath = url.path
            
            if let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
                registeredDriveUUID = uuid
            }
            
            // Check for existing manifest or initialize new one
            if let manifest = ManifestManager.load(from: url) {
                currentManifest = manifest
                let localMachine = MachineMetadata.current()
                if manifest.lastBackupMachine.machineId == localMachine.machineId {
                    driveState = .pairedThisMac
                    isMigrationMode = false
                } else {
                    driveState = .pairedOtherMac
                    isMigrationMode = true
                }
            } else {
                let friendly = url.lastPathComponent.isEmpty ? "Backup Drive" : url.lastPathComponent
                let newManifest = BackupManifest(friendlyName: friendly)
                try? ManifestManager.save(newManifest, to: url)
                currentManifest = newManifest
                driveState = .pairedThisMac
                isMigrationMode = false
            }
            
            checkDriveConnectionStatus()
            refreshTargetFiles()
            calculateSyncStatus()
            calculateStorageMetrics()
        }
    }

    public func deregisterFromThisMac() {
        registeredDriveUUID = ""
        savedTargetFolderPath = ""
        targetFolder = nil
        targetNodes = []
        currentManifest = nil
        isDriveConnected = false
        driveState = .disconnected
        isMigrationMode = false
        storageMetrics = StorageMetrics()
        backupStatus = "Drive deregistered from this Mac."
    }

    public func deregisterAndWipeMetadata() {
        guard let target = targetFolder else { return }
        try? ManifestManager.delete(from: target)
        deregisterFromThisMac()
        backupStatus = "Drive deregistered and backup metadata erased."
    }

    public func adoptBackupForThisMac() {
        guard let target = targetFolder, var manifest = currentManifest else { return }
        manifest.lastBackupMachine = .current()
        manifest.updatedAt = Date()
        try? ManifestManager.save(manifest, to: target)
        currentManifest = manifest
        driveState = .pairedThisMac
        isMigrationMode = false
        refreshTargetFiles()
        calculateSyncStatus()
        calculateStorageMetrics()
        backupStatus = "Drive paired with this Mac successfully!"
    }

    public func autoLinkStandardFolders() {
        guard let manifest = currentManifest else { return }
        let home = fileManager.homeDirectoryForCurrentUser
        var linkedURLs: [URL] = []
        
        for source in manifest.sources {
            let candidate: URL
            if let relHome = source.relativeHomePath, !relHome.isEmpty {
                candidate = home.appendingPathComponent(relHome)
            } else {
                candidate = home.appendingPathComponent(source.folderName)
            }
            
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                linkedURLs.append(candidate)
            }
        }
        
        if !linkedURLs.isEmpty {
            sourceFolders = linkedURLs
            savedSourceFolderPaths = linkedURLs.map { $0.path }.joined(separator: "|")
            adoptBackupForThisMac()
            backupStatus = "Auto-linked \(linkedURLs.count) standard folder(s) on this Mac!"
        } else {
            backupStatus = "No matching standard folders found in your home directory."
        }
    }

    public func ejectDrive() {
        guard let url = targetFolder else { return }
        guard let volumeURL = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return }
        
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            DispatchQueue.main.async {
                self.backupStatus = "Drive safely ejected!"
            }
        } catch {
            DispatchQueue.main.async {
                self.backupStatus = "Eject Failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Storage Analytics Calculation

    public func calculateStorageMetrics() {
        guard let target = targetFolder else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var metrics = StorageMetrics()
            
            // 1. External drive capacity
            if let volumeValues = try? target.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
                metrics.totalDriveCapacity = Int64(volumeValues.volumeTotalCapacity ?? 0)
                metrics.freeDriveSpace = Int64(volumeValues.volumeAvailableCapacity ?? 0)
            }
            
            // 2. Mac SSD free space
            let homeURL = self.fileManager.homeDirectoryForCurrentUser
            if let homeValues = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]) {
                metrics.macSSDFreeSpace = Int64(homeValues.volumeAvailableCapacity ?? 0)
            }
            
            // 3. Target file tree breakdown
            let leaves = self.flattenNodes(self.targetNodes).filter { !$0.isDirectory }
            for leaf in leaves {
                if leaf.isOrphaned {
                    metrics.orphanedFilesSize += leaf.size
                    metrics.orphanCount += 1
                } else if leaf.isVersionedArchive {
                    metrics.archivedVersionsSize += leaf.size
                    metrics.versionCount += 1
                } else {
                    metrics.activeBackupSize += leaf.size
                    metrics.activeFileCount += 1
                }
            }
            
            DispatchQueue.main.async {
                self.storageMetrics = metrics
            }
        }
    }

    // MARK: - SHA-256 Hashing & Safe Copying

    private func hashFile(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        
        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB chunks
        
        while autoreleasepool(invoking: {
            guard let data = try? handle.read(upToCount: bufferSize) else { return false }
            hasher.update(data: data)
            return true
        }) {}
        
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func performWithRetry<T>(maxRetries: Int = 3, action: () throws -> T) throws -> T {
        var attempts = 0
        while true {
            do {
                return try action()
            } catch {
                attempts += 1
                if attempts >= maxRetries { throw error }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }
    
    private func safeCopyAndVerify(source: URL, target: URL, onBytesCopied: ((Int64) -> Void)? = nil) throws {
        let tmpTarget = target.appendingPathExtension("tmp")
        
        if fileManager.fileExists(atPath: tmpTarget.path) {
            try fileManager.removeItem(at: tmpTarget)
        }
        
        // 1. Copy to tmp
        try performWithRetry {
            try fileManager.copyItem(at: source, to: tmpTarget)
        }
        
        let fileSize = (try? fileManager.attributesOfItem(atPath: tmpTarget.path)[.size] as? Int64) ?? 0
        onBytesCopied?(fileSize)
        
        // Check cancellation
        if isCancelRequested {
            try? fileManager.removeItem(at: tmpTarget)
            throw NSError(domain: "BackupManager", code: 99, userInfo: [NSLocalizedDescriptionKey: "Transfer cancelled by user."])
        }
        
        // 2. Checksum Verification
        guard let sourceHash = hashFile(url: source),
              let targetHash = hashFile(url: tmpTarget) else {
            try? fileManager.removeItem(at: tmpTarget)
            throw NSError(domain: "BackupManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read file for hashing."])
        }
        
        if sourceHash != targetHash {
            try? fileManager.removeItem(at: tmpTarget)
            throw NSError(domain: "BackupManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch: Data corruption detected."])
        }
        
        // 3. Atomic Rename
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: tmpTarget, to: target)
    }

    // MARK: - Backup Execution with Metrics & Cancellation

    public func performBackup() {
        guard !sourceFolders.isEmpty, let target = targetFolder else { return }
        
        isBackingUp = true
        isCancelRequested = false
        backupStatus = "Scanning files to back up..."
        newFilesAdded = 0
        modifiedFilesUpdated = 0
        totalBytesTransferred = 0
        totalBytesToTransfer = 0
        transferRateFormatted = ""
        estimatedTimeRemainingFormatted = ""
        
        activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Running Backup")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                if let token = self.activityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    self.activityToken = nil
                }
            }
            
            do {
                // 1. Pre-scan items and compute total bytes to copy
                var itemsToCopy: [(source: URL, target: URL, isModification: Bool, oldTargetDate: Date?)] = []
                var bytesToTransfer: Int64 = 0
                
                for source in self.sourceFolders {
                    let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
                    let enumerator = self.fileManager.enumerator(at: source, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])
                    
                    while let fileURL = enumerator?.nextObject() as? URL {
                        var isDir: ObjCBool = false
                        if self.fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                            continue
                        }
                        
                        let sourceParentPath = source.deletingLastPathComponent().path + "/"
                        let relativePath = fileURL.path.replacingOccurrences(of: sourceParentPath, with: "")
                        let targetURL = target.appendingPathComponent(relativePath)
                        
                        let sourceAttr = try? self.fileManager.attributesOfItem(atPath: fileURL.path)
                        let fileSize = (sourceAttr?[.size] as? Int64) ?? 0
                        
                        if self.fileManager.fileExists(atPath: targetURL.path) {
                            let targetAttr = try? self.fileManager.attributesOfItem(atPath: targetURL.path)
                            let sourceDate = sourceAttr?[.modificationDate] as? Date ?? Date()
                            let targetDate = targetAttr?[.modificationDate] as? Date ?? Date.distantPast
                            
                            if sourceDate.timeIntervalSince(targetDate) > 1.0 {
                                itemsToCopy.append((source: fileURL, target: targetURL, isModification: true, oldTargetDate: targetDate))
                                bytesToTransfer += fileSize
                            }
                        } else {
                            itemsToCopy.append((source: fileURL, target: targetURL, isModification: false, oldTargetDate: nil))
                            bytesToTransfer += fileSize
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.totalBytesToTransfer = bytesToTransfer
                }
                
                let startTime = Date()
                
                // 2. Perform safe copies
                for item in itemsToCopy {
                    if self.isCancelRequested {
                        throw NSError(domain: "BackupManager", code: 99, userInfo: [NSLocalizedDescriptionKey: "Backup cancelled by user."])
                    }
                    
                    let targetDir = item.target.deletingLastPathComponent()
                    if !self.fileManager.fileExists(atPath: targetDir.path) {
                        try? self.fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
                    }
                    
                    if item.isModification, let targetDate = item.oldTargetDate {
                        let ext = item.target.pathExtension
                        let nameWithoutExt = item.target.deletingPathExtension().lastPathComponent
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyyMMdd_HHmmss"
                        let timestamp = formatter.string(from: targetDate)
                        let oldFileName = "\(nameWithoutExt)_\(timestamp).\(ext)"
                        let oldTargetURL = item.target.deletingLastPathComponent().appendingPathComponent(oldFileName)
                        
                        if self.fileManager.fileExists(atPath: oldTargetURL.path) {
                            try? self.fileManager.removeItem(at: oldTargetURL)
                        }
                        try self.performWithRetry {
                            try self.fileManager.moveItem(at: item.target, to: oldTargetURL)
                        }
                        DispatchQueue.main.async { self.modifiedFilesUpdated += 1 }
                    } else if !item.isModification {
                        DispatchQueue.main.async { self.newFilesAdded += 1 }
                    }
                    
                    DispatchQueue.main.async {
                        self.currentFileName = item.target.lastPathComponent
                        self.backupStatus = "Copying \(item.target.lastPathComponent)..."
                    }
                    
                    try self.safeCopyAndVerify(source: item.source, target: item.target) { bytesCopied in
                        self.updateTransferMetrics(bytesCopied: bytesCopied, startTime: startTime)
                    }
                }
                
                // 3. Update manifest
                var updatedSources: [SourceMapping] = []
                let homePath = FileManager.default.homeDirectoryForCurrentUser.path
                for source in self.sourceFolders {
                    let relHome = source.path.hasPrefix(homePath) ? String(source.path.dropFirst(homePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : nil
                    updatedSources.append(SourceMapping(folderName: source.lastPathComponent, relativeHomePath: relHome, lastKnownPath: source.path))
                }
                
                var manifest = self.currentManifest ?? BackupManifest(friendlyName: target.lastPathComponent)
                manifest.sources = updatedSources
                manifest.lastBackupMachine = .current()
                manifest.updatedAt = Date()
                try? ManifestManager.save(manifest, to: target)
                
                DispatchQueue.main.async {
                    self.currentManifest = manifest
                    self.backupStatus = "Backup completed flawlessly!"
                    self.lastBackupDate = Date()
                    self.savedLastBackupDate = self.lastBackupDate!.timeIntervalSince1970
                    self.isBackingUp = false
                    self.currentFileName = ""
                    self.transferRateFormatted = ""
                    self.estimatedTimeRemainingFormatted = ""
                    self.refreshTargetFiles()
                    self.calculateSyncStatus()
                    self.calculateStorageMetrics()
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.backupStatus = error.localizedDescription.contains("cancelled") ? "Backup cancelled by user." : "Error: \(error.localizedDescription)"
                    self.isBackingUp = false
                    self.currentFileName = ""
                    self.transferRateFormatted = ""
                    self.estimatedTimeRemainingFormatted = ""
                }
            }
        }
    }

    // MARK: - Restore Engine with Metrics & Pre-Space Check

    private func safeRestoreAndVerify(source: URL, target: URL, conflictPolicy: ConflictPolicy, onBytesRestored: ((Int64) -> Void)? = nil) throws {
        var finalTarget = target
        if fileManager.fileExists(atPath: target.path) {
            switch conflictPolicy {
            case .skip:
                return
            case .overwrite:
                break
            case .keepBoth:
                let ext = target.pathExtension
                let name = target.deletingPathExtension().lastPathComponent
                let dir = target.deletingLastPathComponent()
                var counter = 1
                var candidate = dir.appendingPathComponent("\(name) (Restored).\(ext)")
                while fileManager.fileExists(atPath: candidate.path) {
                    counter += 1
                    candidate = dir.appendingPathComponent("\(name) (Restored \(counter)).\(ext)")
                }
                finalTarget = candidate
            }
        }

        let targetDir = finalTarget.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: targetDir.path) {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
        }

        let tmpTarget = finalTarget.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: tmpTarget.path) {
            try fileManager.removeItem(at: tmpTarget)
        }

        // 1. Copy to tmp
        try performWithRetry {
            try fileManager.copyItem(at: source, to: tmpTarget)
        }

        let fileSize = (try? fileManager.attributesOfItem(atPath: tmpTarget.path)[.size] as? Int64) ?? 0
        onBytesRestored?(fileSize)

        if isCancelRequested {
            try? fileManager.removeItem(at: tmpTarget)
            throw NSError(domain: "RestoreEngine", code: 99, userInfo: [NSLocalizedDescriptionKey: "Restore cancelled by user."])
        }

        // 2. Hash check
        guard let sourceHash = hashFile(url: source),
              let targetHash = hashFile(url: tmpTarget) else {
            try? fileManager.removeItem(at: tmpTarget)
            throw NSError(domain: "RestoreEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read file for hashing."])
        }

        if sourceHash != targetHash {
            try? fileManager.removeItem(at: tmpTarget)
            throw NSError(domain: "RestoreEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch during restore: Data corruption detected."])
        }

        // 3. Move tmp to final target
        if fileManager.fileExists(atPath: finalTarget.path) {
            try fileManager.removeItem(at: finalTarget)
        }
        try fileManager.moveItem(at: tmpTarget, to: finalTarget)
    }

    private func restoreNodeRecursively(_ node: FileSystemNode, relativeToBase: URL, destinationBase: URL, conflictPolicy: ConflictPolicy, startTime: Date) throws {
        if isCancelRequested {
            throw NSError(domain: "RestoreEngine", code: 99, userInfo: [NSLocalizedDescriptionKey: "Restore cancelled by user."])
        }
        
        if node.isDirectory {
            if let children = node.children {
                for child in children {
                    try restoreNodeRecursively(child, relativeToBase: relativeToBase, destinationBase: destinationBase, conflictPolicy: conflictPolicy, startTime: startTime)
                }
            }
        } else {
            let relativePath = node.url.path.replacingOccurrences(of: relativeToBase.path + "/", with: "")
            let destURL = destinationBase.appendingPathComponent(relativePath)
            
            DispatchQueue.main.async {
                self.currentFileName = node.name
                self.restoreStatus = "Restoring \(node.name)..."
            }
            
            try safeRestoreAndVerify(source: node.url, target: destURL, conflictPolicy: conflictPolicy) { bytesRestored in
                self.updateTransferMetrics(bytesCopied: bytesRestored, startTime: startTime)
            }
            
            DispatchQueue.main.async {
                self.restoredFilesCount += 1
                if self.totalBytesToTransfer > 0 {
                    self.restoreProgress = min(1.0, Double(self.totalBytesTransferred) / Double(self.totalBytesToTransfer))
                }
            }
        }
    }

    public func canRestore(bytesNeeded: Int64) -> (allowed: Bool, neededFormatted: String, freeFormatted: String) {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        let free = storageMetrics.macSSDFreeSpace
        let allowed = bytesNeeded <= free
        return (allowed, formatter.string(fromByteCount: bytesNeeded), formatter.string(fromByteCount: free))
    }

    public func performFullRestore(to destinationBaseURL: URL, conflictPolicy: ConflictPolicy = .keepBoth) {
        guard let target = targetFolder else { return }
        
        isRestoring = true
        isCancelRequested = false
        restoreStatus = "Starting full restore..."
        restoredFilesCount = 0
        restoreProgress = 0.0
        totalBytesTransferred = 0
        transferRateFormatted = ""
        estimatedTimeRemainingFormatted = ""
        
        let validNodes = targetNodes.filter { $0.name != ManifestManager.manifestDirectoryName }
        let totalBytes = flattenNodes(validNodes).filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
        totalBytesToTransfer = totalBytes
        
        activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Running Restore")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                if let token = self.activityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    self.activityToken = nil
                }
            }
            
            let startTime = Date()
            
            do {
                for node in validNodes {
                    try self.restoreNodeRecursively(node, relativeToBase: target, destinationBase: destinationBaseURL, conflictPolicy: conflictPolicy, startTime: startTime)
                }
                
                DispatchQueue.main.async {
                    self.restoreStatus = "Restore completed successfully! \(self.restoredFilesCount) files restored."
                    self.isRestoring = false
                    self.restoreProgress = 1.0
                    self.currentFileName = ""
                    self.transferRateFormatted = ""
                    self.estimatedTimeRemainingFormatted = ""
                }
            } catch {
                DispatchQueue.main.async {
                    self.restoreStatus = error.localizedDescription.contains("cancelled") ? "Restore cancelled by user." : "Restore Failed: \(error.localizedDescription)"
                    self.isRestoring = false
                    self.currentFileName = ""
                    self.transferRateFormatted = ""
                    self.estimatedTimeRemainingFormatted = ""
                }
            }
        }
    }

    public func performSelectiveRestore(nodes: [FileSystemNode], destinationURL: URL, conflictPolicy: ConflictPolicy = .keepBoth) {
        guard let target = targetFolder else { return }
        
        isRestoring = true
        isCancelRequested = false
        restoreStatus = "Restoring selected items..."
        restoredFilesCount = 0
        restoreProgress = 0.0
        totalBytesTransferred = 0
        transferRateFormatted = ""
        estimatedTimeRemainingFormatted = ""
        
        let totalBytes = flattenNodes(nodes).filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
        totalBytesToTransfer = totalBytes
        
        activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Running Selective Restore")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                if let token = self.activityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    self.activityToken = nil
                }
            }
            
            let startTime = Date()
            
            do {
                for node in nodes {
                    if node.isDirectory {
                        try self.restoreNodeRecursively(node, relativeToBase: target, destinationBase: destinationURL, conflictPolicy: conflictPolicy, startTime: startTime)
                    } else {
                        if self.isCancelRequested {
                            throw NSError(domain: "RestoreEngine", code: 99, userInfo: [NSLocalizedDescriptionKey: "Restore cancelled by user."])
                        }
                        
                        let destFile = destinationURL.appendingPathComponent(node.name)
                        DispatchQueue.main.async {
                            self.currentFileName = node.name
                            self.restoreStatus = "Restoring \(node.name)..."
                        }
                        
                        try self.safeRestoreAndVerify(source: node.url, target: destFile, conflictPolicy: conflictPolicy) { bytesRestored in
                            self.updateTransferMetrics(bytesCopied: bytesRestored, startTime: startTime)
                        }
                        
                        DispatchQueue.main.async {
                            self.restoredFilesCount += 1
                            if self.totalBytesToTransfer > 0 {
                                self.restoreProgress = min(1.0, Double(self.totalBytesTransferred) / Double(self.totalBytesToTransfer))
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.restoreStatus = "Selected files restored successfully!"
                    self.isRestoring = false
                    self.restoreProgress = 1.0
                    self.currentFileName = ""
                    self.transferRateFormatted = ""
                    self.estimatedTimeRemainingFormatted = ""
                }
            } catch {
                DispatchQueue.main.async {
                    self.restoreStatus = error.localizedDescription.contains("cancelled") ? "Restore cancelled by user." : "Restore Failed: \(error.localizedDescription)"
                    self.isRestoring = false
                    self.currentFileName = ""
                    self.transferRateFormatted = ""
                    self.estimatedTimeRemainingFormatted = ""
                }
            }
        }
    }

    private func updateTransferMetrics(bytesCopied: Int64, startTime: Date) {
        DispatchQueue.main.async {
            self.totalBytesTransferred += bytesCopied
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0.5 {
                let bytesPerSec = Double(self.totalBytesTransferred) / elapsed
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useAll]
                formatter.countStyle = .file
                self.transferRateFormatted = "\(formatter.string(fromByteCount: Int64(bytesPerSec)))/s"
                
                let remainingBytes = max(0, self.totalBytesToTransfer - self.totalBytesTransferred)
                if bytesPerSec > 0 {
                    let secondsLeft = Double(remainingBytes) / bytesPerSec
                    self.estimatedTimeRemainingFormatted = self.formatTimeInterval(secondsLeft)
                }
            }
        }
    }

    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        if totalSeconds < 60 {
            return "~\(totalSeconds)s remaining"
        } else if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            return "~\(minutes)m \(seconds)s remaining"
        } else {
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            return "~\(hours)h \(minutes)m remaining"
        }
    }

    // MARK: - Tree Building & Orphan Safety

    public func refreshTargetFiles() {
        guard let target = targetFolder else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let nodes = self.buildTree(for: target, targetRoot: target)
            
            // Check orphan safety guard
            let allLeaves = self.flattenNodes(nodes).filter { !$0.isDirectory }
            let orphanLeaves = allLeaves.filter { $0.isOrphaned }
            let orphanRatio = allLeaves.isEmpty ? 0 : Double(orphanLeaves.count) / Double(allLeaves.count)
            let isLocked = self.isMigrationMode || self.sourceFolders.isEmpty || (orphanRatio > 0.5 && allLeaves.count > 10)
            
            DispatchQueue.main.async {
                self.targetNodes = nodes
                self.orphanSafetyLocked = isLocked
                self.calculateStorageMetrics()
            }
        }
    }
    
    private func buildTree(for url: URL, targetRoot: URL) -> [FileSystemNode] {
        var nodes: [FileSystemNode] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        
        guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return nodes
        }
        
        for itemURL in contents {
            if itemURL.lastPathComponent == ManifestManager.manifestDirectoryName {
                continue
            }
            
            let attr = try? itemURL.resourceValues(forKeys: Set(keys))
            let isDir = attr?.isDirectory ?? false
            let modDate = attr?.contentModificationDate ?? Date()
            let size = Int64(attr?.fileSize ?? 0)
            
            let isVersioned = itemURL.lastPathComponent.range(of: "_\\d{8}_\\d{6}\\.", options: .regularExpression) != nil
            
            let relativePath = itemURL.path.replacingOccurrences(of: targetRoot.path + "/", with: "")
            let baseRelativePath = relativePath.replacingOccurrences(of: "_\\d{8}_\\d{6}", with: "", options: .regularExpression)
            
            var foundInSource = false
            if !isMigrationMode && !sourceFolders.isEmpty {
                for source in self.sourceFolders {
                    let sourceParentPath = source.deletingLastPathComponent().path + "/"
                    let expectedSourcePath = sourceParentPath + baseRelativePath
                    if self.fileManager.fileExists(atPath: expectedSourcePath) {
                        foundInSource = true
                        break
                    }
                }
            } else {
                foundInSource = true
            }
            
            let isOrphaned = !foundInSource
            
            if isDir {
                let children = buildTree(for: itemURL, targetRoot: targetRoot)
                nodes.append(FileSystemNode(url: itemURL, name: itemURL.lastPathComponent, isDirectory: true, modificationDate: modDate, size: size, isOrphaned: isOrphaned, isVersionedArchive: false, children: children.isEmpty ? nil : children))
            } else {
                nodes.append(FileSystemNode(url: itemURL, name: itemURL.lastPathComponent, isDirectory: false, modificationDate: modDate, size: size, isOrphaned: isOrphaned, isVersionedArchive: isVersioned, children: nil))
            }
        }
        
        nodes.sort {
            if $0.isDirectory == $1.isDirectory {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.isDirectory && !$1.isDirectory
        }
        
        return nodes
    }

    public func flattenNodes(_ nodes: [FileSystemNode]) -> [FileSystemNode] {
        var result: [FileSystemNode] = []
        for node in nodes {
            result.append(node)
            if let children = node.children {
                result.append(contentsOf: flattenNodes(children))
            }
        }
        return result
    }

    public var allOrphans: [FileSystemNode] {
        flattenNodes(targetNodes).filter { $0.isOrphaned && !$0.isDirectory }
    }

    public var allVersionedArchives: [FileSystemNode] {
        flattenNodes(targetNodes).filter { $0.isVersionedArchive && !$0.isDirectory }
    }
    
    public func findNode(by id: String, in nodes: [FileSystemNode]? = nil) -> FileSystemNode? {
        let searchNodes = nodes ?? targetNodes
        for node in searchNodes {
            if node.id == id { return node }
            if let children = node.children, let found = findNode(by: id, in: children) {
                return found
            }
        }
        return nil
    }
    
    public func deleteNode(_ node: FileSystemNode) {
        guard !orphanSafetyLocked || !node.isOrphaned else {
            backupStatus = "Deletion blocked: Orphan safety lock is active."
            return
        }
        do {
            try fileManager.removeItem(at: node.url)
            refreshTargetFiles()
        } catch {
            print("Error deleting file/folder: \(error)")
        }
    }
    
    public func deleteSelectedNodes() {
        guard !orphanSafetyLocked else {
            backupStatus = "Bulk deletion blocked: Orphan safety lock is active."
            return
        }
        let nodesToDelete = checkedNodes.compactMap { findNode(by: $0) }
        for node in nodesToDelete {
            try? fileManager.removeItem(at: node.url)
        }
        checkedNodes.removeAll()
        refreshTargetFiles()
    }

    public func recoverOrphan(node: FileSystemNode, to destinationURL: URL?) {
        let destDir = destinationURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Restored_Orphans")
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)
        let targetFile = destDir.appendingPathComponent(node.name)
        try? safeRestoreAndVerify(source: node.url, target: targetFile, conflictPolicy: .keepBoth)
        backupStatus = "Recovered \(node.name) to \(destDir.lastPathComponent)"
    }

    public func recoverSelectedOrphans(to destinationURL: URL?) {
        let destDir = destinationURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Restored_Orphans")
        let orphansToRecover = checkedNodes.compactMap { findNode(by: $0) }.filter { $0.isOrphaned }
        for node in orphansToRecover {
            recoverOrphan(node: node, to: destDir)
        }
        checkedNodes.removeAll()
    }
    
    public func calculateSyncStatus() {
        guard !sourceFolders.isEmpty, let target = targetFolder else {
            DispatchQueue.main.async { self.pendingBackupPercentage = 0 }
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var totalFiles = 0
            var outOfSyncFiles = 0
            
            for source in self.sourceFolders {
                let keys: [URLResourceKey] = [.contentModificationDateKey]
                let enumerator = self.fileManager.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                
                while let fileURL = enumerator?.nextObject() as? URL {
                    var isDir: ObjCBool = false
                    if self.fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                        continue
                    }
                    
                    totalFiles += 1
                    
                    let sourceParentPath = source.deletingLastPathComponent().path + "/"
                    let relativePath = fileURL.path.replacingOccurrences(of: sourceParentPath, with: "")
                    let targetURL = target.appendingPathComponent(relativePath)
                    
                    if !self.fileManager.fileExists(atPath: targetURL.path) {
                        outOfSyncFiles += 1
                    } else {
                        let sourceAttr = try? self.fileManager.attributesOfItem(atPath: fileURL.path)
                        let targetAttr = try? self.fileManager.attributesOfItem(atPath: targetURL.path)
                        
                        let sourceDate = sourceAttr?[.modificationDate] as? Date ?? Date()
                        let targetDate = targetAttr?[.modificationDate] as? Date ?? Date.distantPast
                        
                        if sourceDate.timeIntervalSince(targetDate) > 1.1 {
                            outOfSyncFiles += 1
                        }
                    }
                }
            }
            
            let percentage = totalFiles == 0 ? 0 : Double(outOfSyncFiles) / Double(totalFiles)
            DispatchQueue.main.async {
                self.pendingBackupPercentage = percentage
            }
        }
    }
}
