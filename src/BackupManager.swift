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

public enum PathSecurity: Sendable {
    public static func relativeSubpath(of fileURL: URL, relativeTo baseURL: URL) -> String? {
        let base = baseURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let file = fileURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = base + "/"
        guard file.hasPrefix(prefix) else { return nil }
        let relative = String(file.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    public static func isSubpath(of childURL: URL, inside parentURL: URL) -> Bool {
        let parent = parentURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let child = childURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return child.hasPrefix(parent + "/")
    }
}

extension Int64 {
    private static let sharedByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter
    }()

    public var formattedBytes: String {
        Self.sharedByteFormatter.string(fromByteCount: self)
    }
}

public struct FileSystemNode: Identifiable, Sendable {
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

public enum DriveRegistrationState: Equatable, Sendable {
    case disconnected
    case unregistered
    case pairedThisMac
    case pairedOtherMac
}

public enum ConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case keepBoth = "Keep Both (Append (Restored))"
    case overwrite = "Overwrite Existing"
    case skip = "Skip If Exists"

    public var id: String { rawValue }
}

public struct StorageMetrics: Sendable {
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
        orphanedFilesSize.formattedBytes
    }
}

public struct DiscoveredBackup: Identifiable, Sendable {
    public var id: String { backupFolderURL.path }
    public let volumeURL: URL
    public let backupFolderURL: URL
    public let manifest: BackupManifest
    public let isSameMachine: Bool
    public let volumeName: String

    public init(volumeURL: URL, backupFolderURL: URL, manifest: BackupManifest, isSameMachine: Bool, volumeName: String) {
        self.volumeURL = volumeURL
        self.backupFolderURL = backupFolderURL
        self.manifest = manifest
        self.isSameMachine = isSameMachine
        self.volumeName = volumeName
    }
}

public struct FolderRestoreMapping: Identifiable, Equatable, Sendable {
    public var id: String { sourceFolderURL.path }
    public let folderName: String
    public let sourceFolderURL: URL
    public var destinationURL: URL
    public var isSelected: Bool
    public var totalSize: Int64
    public var fileCount: Int
    public var activeSize: Int64
    public var activeFileCount: Int
    public var orphanCount: Int
    public var orphanSize: Int64
    public var archiveCount: Int
    public var archiveSize: Int64
    public var originalPath: String?

    public init(
        folderName: String,
        sourceFolderURL: URL,
        destinationURL: URL,
        isSelected: Bool = true,
        totalSize: Int64 = 0,
        fileCount: Int = 0,
        activeSize: Int64 = 0,
        activeFileCount: Int = 0,
        orphanCount: Int = 0,
        orphanSize: Int64 = 0,
        archiveCount: Int = 0,
        archiveSize: Int64 = 0,
        originalPath: String? = nil
    ) {
        self.folderName = folderName
        self.sourceFolderURL = sourceFolderURL
        self.destinationURL = destinationURL
        self.isSelected = isSelected
        self.totalSize = totalSize
        self.fileCount = fileCount
        self.activeSize = activeSize
        self.activeFileCount = activeFileCount
        self.orphanCount = orphanCount
        self.orphanSize = orphanSize
        self.archiveCount = archiveCount
        self.archiveSize = archiveSize
        self.originalPath = originalPath
    }
}

public class BackupManager: ObservableObject {
    @Published public var sourceFolders: [URL] = []
    @Published public var targetFolder: URL?
    @Published public var targetNodes: [FileSystemNode] = []
    
    // Fast O(1) Lookup & Caches
    @Published public var nodeLookup: [String: FileSystemNode] = [:]
    @Published public var allOrphans: [FileSystemNode] = []
    @Published public var allVersionedArchives: [FileSystemNode] = []

    // Smart Discovery & Setup Assistant
    @Published public var discoveredBackups: [DiscoveredBackup] = []
    @Published public var showingSetupAssistant: Bool = false
    @Published public var activeSetupBackup: DiscoveredBackup? = nil

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
    @Published public var currentCatalog: BackupCatalog? = nil
    @Published public var isMigrationMode: Bool = false
    @Published public var orphanSafetyLocked: Bool = false

    // Storage Analytics
    @Published public var storageMetrics = StorageMetrics()

    // Restore State
    @Published public var isRestoring = false
    @Published public var restoreStatus = ""
    @Published public var restoreProgress: Double = 0.0
    @Published public var restoredFilesCount: Int = 0
    @Published public var restoreFolderMappings: [FolderRestoreMapping] = []
    @Published public var restoreCheckedNodes: Set<String> = []

    // Real-Time Transfer Metrics & Cancellation
    @Published public var currentFileName: String = ""
    @Published public var transferRateFormatted: String = ""
    @Published public var estimatedTimeRemainingFormatted: String = ""
    @Published public var totalBytesTransferred: Int64 = 0
    @Published public var totalBytesToTransfer: Int64 = 0
    @Published public var isCancelRequested = false

    // Stored Preferences
    @AppStorage("registeredDriveUUID") public var registeredDriveUUID: String = ""
    @AppStorage("savedTargetFolderPath") public var savedTargetFolderPath: String = ""
    @AppStorage("savedSourceFolderPaths") public var savedSourceFolderPaths: String = ""
    @AppStorage("savedLastBackupDate") public var savedLastBackupDate: Double = 0

    private let fileManager = FileManager.default
    private var cancellables = Set<AnyCancellable>()

    // Thread-safe pre-compiled archive regex (supporting optional collision sequence suffixes like _1)
    private static let archiveRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "(_|\\.v)\\d{8}_\\d{6}(_\\d+)?(\\.[^.]+)?$")) ?? (try! NSRegularExpression(pattern: "_\\d{8}_\\d{6}"))
    }()

    public init() {
        if savedLastBackupDate > 0 {
            lastBackupDate = Date(timeIntervalSince1970: savedLastBackupDate)
        }
        
        if !savedSourceFolderPaths.isEmpty {
            let paths: [String]
            if savedSourceFolderPaths.starts(with: "["),
               let data = savedSourceFolderPaths.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                paths = decoded
            } else {
                paths = savedSourceFolderPaths.components(separatedBy: "|")
            }
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
            scanMountedVolumesForBackups()
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
            scanMountedVolumesForBackups()
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
        currentCatalog = CatalogManager.load(from: folder)
        refreshTargetFiles()
        calculateSyncStatus()
        calculateStorageMetrics()
    }

    private func handleDriveMount(notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        
        let uuid = try? volumeURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        if let driveUUID = uuid, !registeredDriveUUID.isEmpty, driveUUID == registeredDriveUUID {
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
                
                NSApp.activate(ignoringOtherApps: true)
                if !self.isMigrationMode {
                    self.showingBackupPrompt = true
                }
            }
        } else {
            scanMountedVolumesForBackups()
        }
    }

    // MARK: - Smart Volume Discovery & Setup Assistant

    public func scanMountedVolumesForBackups() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsRemovableKey]
        let mountedVolumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        
        var discovered: [DiscoveredBackup] = []
        let localMachine = MachineMetadata.current()
        
        for volume in mountedVolumes where volume.path != "/" && volume.path.hasPrefix("/Volumes/") {
            let volumeName = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent
            
            let candidateFolders = [
                volume,
                volume.appendingPathComponent("Backups"),
                volume.appendingPathComponent("MacBackup")
            ]
            
            for candidate in candidateFolders {
                if let manifest = ManifestManager.load(from: candidate) {
                    let isSame = (manifest.lastBackupMachine.machineId == localMachine.machineId) ||
                                 (manifest.lastBackupMachine.hostname == localMachine.hostname && manifest.lastBackupMachine.username == localMachine.username)
                    discovered.append(DiscoveredBackup(
                        volumeURL: volume,
                        backupFolderURL: candidate,
                        manifest: manifest,
                        isSameMachine: isSame,
                        volumeName: volumeName
                    ))
                    break
                }
            }
        }
        
        DispatchQueue.main.async {
            self.discoveredBackups = discovered
            if self.driveState == .unregistered || self.driveState == .disconnected {
                if let first = discovered.first {
                    self.activeSetupBackup = first
                    self.showingSetupAssistant = true
                }
            }
        }
    }

    public func reconnectDiscoveredBackup(_ discovered: DiscoveredBackup) {
        targetFolder = discovered.backupFolderURL
        savedTargetFolderPath = discovered.backupFolderURL.path
        if let uuid = try? discovered.volumeURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
            registeredDriveUUID = uuid
        }
        inspectTargetFolder(discovered.backupFolderURL)
        if sourceFolders.isEmpty {
            autoLinkStandardFolders()
        }
        showingSetupAssistant = false
        activeSetupBackup = nil
        backupStatus = "Reconnected to backup on \(discovered.volumeName)!"
    }

    public func prepareRestoreFromDiscoveredBackup(_ discovered: DiscoveredBackup) {
        targetFolder = discovered.backupFolderURL
        savedTargetFolderPath = discovered.backupFolderURL.path
        if let uuid = try? discovered.volumeURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
            registeredDriveUUID = uuid
        }
        inspectTargetFolder(discovered.backupFolderURL)
        isMigrationMode = true
        driveState = .pairedOtherMac
        showingSetupAssistant = false
        activeSetupBackup = nil
        backupStatus = "Ready to restore files from \(discovered.manifest.friendlyName)."
    }

    public func adoptAndPairDiscoveredBackup(_ discovered: DiscoveredBackup) {
        reconnectDiscoveredBackup(discovered)
        adoptBackupForThisMac()
    }
    
    private func handleDriveUnmount(notification: Notification) {
        DispatchQueue.main.async {
            self.checkDriveConnectionStatus()
            if !self.isDriveConnected {
                self.targetFolder = nil
                self.targetNodes = []
                self.nodeLookup.removeAll()
                self.allOrphans.removeAll()
                self.allVersionedArchives.removeAll()
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
            if let data = try? JSONEncoder().encode(panel.urls.map { $0.path }),
               let json = String(data: data, encoding: .utf8) {
                savedSourceFolderPaths = json
            }
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

    public func selectBackupFolder(_ url: URL) {
        targetFolder = url
        savedTargetFolderPath = url.path
        if let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
            registeredDriveUUID = uuid
        }
        isDriveConnected = true
        inspectTargetFolder(url)
    }

    public func deregisterFromThisMac() {
        registeredDriveUUID = ""
        savedTargetFolderPath = ""
        targetFolder = nil
        targetNodes = []
        nodeLookup.removeAll()
        allOrphans.removeAll()
        allVersionedArchives.removeAll()
        currentManifest = nil
        currentCatalog = nil
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
            if let data = try? JSONEncoder().encode(linkedURLs.map { $0.path }),
               let json = String(data: data, encoding: .utf8) {
                savedSourceFolderPaths = json
            }
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
            
            if let volumeValues = try? target.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
                metrics.totalDriveCapacity = Int64(volumeValues.volumeTotalCapacity ?? 0)
                metrics.freeDriveSpace = Int64(volumeValues.volumeAvailableCapacity ?? 0)
            }
            
            let homeURL = self.fileManager.homeDirectoryForCurrentUser
            if let homeValues = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]) {
                metrics.macSSDFreeSpace = Int64(homeValues.volumeAvailableCapacity ?? 0)
            }
            
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

    public func hashFile(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        
        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB chunks
        
        while autoreleasepool(invoking: {
            guard let data = try? handle.read(upToCount: bufferSize), !data.isEmpty else { return false }
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
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
    
    private func safeCopyAndVerify(source: URL, target: URL, onBytesCopied: ((Int64) -> Void)? = nil) throws {
        let tmpTarget = target.appendingPathExtension("tmp")
        
        if fileManager.fileExists(atPath: tmpTarget.path) {
            try? fileManager.removeItem(at: tmpTarget)
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
        
        // 3. Move tmp to final target (atomic where possible)
        if fileManager.fileExists(atPath: target.path) {
            do {
                _ = try fileManager.replaceItemAt(target, withItemAt: tmpTarget, backupItemName: nil, options: .usingNewMetadataOnly)
            } catch {
                try? fileManager.removeItem(at: target)
                try fileManager.moveItem(at: tmpTarget, to: target)
            }
        } else {
            try fileManager.moveItem(at: tmpTarget, to: target)
        }

        // 4. Synchronize source modification timestamp to prevent FAT32 jitter
        if let sourceAttr = try? fileManager.attributesOfItem(atPath: source.path),
           let sourceDate = sourceAttr[.modificationDate] as? Date {
            try? fileManager.setAttributes([.modificationDate: sourceDate], ofItemAtPath: target.path)
        }
    }

    // MARK: - Backup Execution with Metrics & Cancellation

    public func performBackup() {
        guard !sourceFolders.isEmpty, let target = targetFolder else { return }
        guard !isBackingUp && !isRestoring else { return }
        
        isBackingUp = true
        isCancelRequested = false
        backupStatus = "Scanning files to back up..."
        newFilesAdded = 0
        modifiedFilesUpdated = 0
        totalBytesTransferred = 0
        totalBytesToTransfer = 0
        transferRateFormatted = ""
        estimatedTimeRemainingFormatted = ""
        
        let token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Running Backup")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                ProcessInfo.processInfo.endActivity(token)
            }
            
            do {
                var itemsToCopy: [(source: URL, target: URL, isModification: Bool, oldTargetDate: Date?)] = []
                var bytesToTransfer: Int64 = 0
                var activeRelativePaths = Set<String>()
                var archivedRelativePaths = self.currentCatalog?.archivedVersions ?? Set<String>()
                
                for source in self.sourceFolders {
                    let sourceParent = source.deletingLastPathComponent()
                    let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]
                    let enumerator = self.fileManager.enumerator(at: source, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    
                    while let fileURL = enumerator?.nextObject() as? URL {
                        let resValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
                        if resValues?.isSymbolicLink == true {
                            continue
                        }
                        
                        var isDir: ObjCBool = false
                        if self.fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                            continue
                        }
                        
                        guard let relativePath = PathSecurity.relativeSubpath(of: fileURL, relativeTo: sourceParent) else {
                            continue
                        }
                        activeRelativePaths.insert(relativePath)
                        let targetURL = target.appendingPathComponent(relativePath)
                        
                        let sourceAttr = try? self.fileManager.attributesOfItem(atPath: fileURL.path)
                        let sourceSize = (sourceAttr?[.size] as? Int64) ?? 0
                        
                        if self.fileManager.fileExists(atPath: targetURL.path) {
                            let targetAttr = try? self.fileManager.attributesOfItem(atPath: targetURL.path)
                            let targetSize = (targetAttr?[.size] as? Int64) ?? 0
                            let sourceDate = sourceAttr?[.modificationDate] as? Date ?? Date()
                            let targetDate = targetAttr?[.modificationDate] as? Date ?? Date.distantPast
                            
                            // 2.0 second tolerance window for cross-filesystem accuracy
                            if (sourceSize != targetSize) || (sourceDate.timeIntervalSince(targetDate) > 2.0) {
                                itemsToCopy.append((source: fileURL, target: targetURL, isModification: true, oldTargetDate: targetDate))
                                bytesToTransfer += sourceSize
                            }
                        } else {
                            itemsToCopy.append((source: fileURL, target: targetURL, isModification: false, oldTargetDate: nil))
                            bytesToTransfer += sourceSize
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.totalBytesToTransfer = bytesToTransfer
                }
                
                let startTime = Date()
                
                // 2. Perform safe copies with per-file error isolation
                for item in itemsToCopy {
                    if self.isCancelRequested {
                        throw NSError(domain: "BackupManager", code: 99, userInfo: [NSLocalizedDescriptionKey: "Backup cancelled by user."])
                    }
                    
                    let targetDir = item.target.deletingLastPathComponent()
                    if !self.fileManager.fileExists(atPath: targetDir.path) {
                        try? self.fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
                    }
                    
                    do {
                        if item.isModification, let targetDate = item.oldTargetDate {
                            let ext = item.target.pathExtension
                            let nameWithoutExt = item.target.deletingPathExtension().lastPathComponent
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyyMMdd_HHmmss"
                            let timestamp = formatter.string(from: targetDate)
                            let baseArchiveName = ext.isEmpty ? "\(nameWithoutExt)_\(timestamp)" : "\(nameWithoutExt)_\(timestamp).\(ext)"
                            var oldTargetURL = item.target.deletingLastPathComponent().appendingPathComponent(baseArchiveName)
                            
                            var seq = 1
                            while self.fileManager.fileExists(atPath: oldTargetURL.path) {
                                let seqName = ext.isEmpty ? "\(nameWithoutExt)_\(timestamp)_\(seq)" : "\(nameWithoutExt)_\(timestamp)_\(seq).\(ext)"
                                oldTargetURL = item.target.deletingLastPathComponent().appendingPathComponent(seqName)
                                seq += 1
                            }
                            
                            try self.performWithRetry {
                                try self.fileManager.moveItem(at: item.target, to: oldTargetURL)
                            }
                            if let relArch = PathSecurity.relativeSubpath(of: oldTargetURL, relativeTo: target) {
                                archivedRelativePaths.insert(relArch)
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
                    } catch {
                        if self.isCancelRequested { throw error }
                        DispatchQueue.main.async {
                            self.backupStatus = "Skipped unreadable item: \(item.source.lastPathComponent)"
                        }
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
                
                let newCatalog = BackupCatalog(
                    version: "2.6.0",
                    updatedAt: Date(),
                    activeFiles: activeRelativePaths,
                    archivedVersions: archivedRelativePaths
                )
                try? CatalogManager.save(newCatalog, to: target)
                
                DispatchQueue.main.async {
                    self.currentManifest = manifest
                    self.currentCatalog = newCatalog
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
                let baseRestoredName = ext.isEmpty ? "\(name) (Restored)" : "\(name) (Restored).\(ext)"
                var candidate = dir.appendingPathComponent(baseRestoredName)
                while fileManager.fileExists(atPath: candidate.path) {
                    counter += 1
                    let countedName = ext.isEmpty ? "\(name) (Restored \(counter))" : "\(name) (Restored \(counter)).\(ext)"
                    candidate = dir.appendingPathComponent(countedName)
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
            try? fileManager.removeItem(at: tmpTarget)
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

        // 3. Move tmp to final target using atomic replace where supported
        if fileManager.fileExists(atPath: finalTarget.path) {
            do {
                _ = try fileManager.replaceItemAt(finalTarget, withItemAt: tmpTarget, backupItemName: nil, options: .usingNewMetadataOnly)
            } catch {
                try? fileManager.removeItem(at: finalTarget)
                try fileManager.moveItem(at: tmpTarget, to: finalTarget)
            }
        } else {
            try fileManager.moveItem(at: tmpTarget, to: finalTarget)
        }

        // 4. Mirror source timestamp
        if let sourceAttr = try? fileManager.attributesOfItem(atPath: source.path),
           let sourceDate = sourceAttr[.modificationDate] as? Date {
            try? fileManager.setAttributes([.modificationDate: sourceDate], ofItemAtPath: finalTarget.path)
        }
    }

    private func restoreNodeRecursively(
        _ node: FileSystemNode,
        relativeToBase: URL,
        destinationBase: URL,
        conflictPolicy: ConflictPolicy,
        includeOrphans: Bool = false,
        includeArchives: Bool = false,
        startTime: Date
    ) throws {
        if isCancelRequested {
            throw NSError(domain: "RestoreEngine", code: 99, userInfo: [NSLocalizedDescriptionKey: "Restore cancelled by user."])
        }
        
        if !includeOrphans && node.isOrphaned {
            return
        }
        
        if node.isDirectory {
            if let children = node.children {
                for child in children {
                    try restoreNodeRecursively(
                        child,
                        relativeToBase: relativeToBase,
                        destinationBase: destinationBase,
                        conflictPolicy: conflictPolicy,
                        includeOrphans: includeOrphans,
                        includeArchives: includeArchives,
                        startTime: startTime
                    )
                }
            }
        } else {
            if !includeOrphans && node.isOrphaned {
                return
            }
            if !includeArchives && node.isVersionedArchive {
                return
            }
            guard let relativePath = PathSecurity.relativeSubpath(of: node.url, relativeTo: relativeToBase) else {
                return
            }
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

    // MARK: - Folder-Mapped Restore

    public func refreshRestoreFolderMappings() {
        guard let target = targetFolder else {
            DispatchQueue.main.async {
                self.restoreFolderMappings = []
            }
            return
        }
        let home = fileManager.homeDirectoryForCurrentUser
        let rootFolders = targetNodes.filter { $0.isDirectory && $0.name != ManifestManager.manifestDirectoryName }
        let rootFiles = targetNodes.filter { !$0.isDirectory && $0.name != ManifestManager.manifestFileName }
        
        var newMappings: [FolderRestoreMapping] = []
        for node in rootFolders {
            let folderName = node.name
            let manifestSource = currentManifest?.sources.first(where: { $0.folderName == folderName })
            let originalPath = manifestSource?.lastKnownPath
            
            let existing = restoreFolderMappings.first(where: { $0.id == node.url.path })
            let dest: URL
            let selected: Bool
            if let existing = existing {
                dest = existing.destinationURL
                selected = existing.isSelected
            } else {
                if let relHome = manifestSource?.relativeHomePath, !relHome.isEmpty {
                    dest = home.appendingPathComponent(relHome)
                } else {
                    dest = home.appendingPathComponent(folderName)
                }
                selected = true
            }
            
            let allLeaves = flattenNodes([node]).filter { !$0.isDirectory }
            let activeLeaves = allLeaves.filter { !$0.isOrphaned && !$0.isVersionedArchive }
            let orphanLeaves = allLeaves.filter { $0.isOrphaned }
            let archiveLeaves = allLeaves.filter { $0.isVersionedArchive }
            
            let totalBytes = allLeaves.reduce(0) { $0 + $1.size }
            let totalCount = allLeaves.count
            let activeBytes = activeLeaves.reduce(0) { $0 + $1.size }
            let activeCount = activeLeaves.count
            let orphanBytes = orphanLeaves.reduce(0) { $0 + $1.size }
            let orphanCount = orphanLeaves.count
            let archiveBytes = archiveLeaves.reduce(0) { $0 + $1.size }
            let archiveCount = archiveLeaves.count
            
            newMappings.append(FolderRestoreMapping(
                folderName: folderName,
                sourceFolderURL: node.url,
                destinationURL: dest,
                isSelected: selected,
                totalSize: totalBytes,
                fileCount: totalCount,
                activeSize: activeBytes,
                activeFileCount: activeCount,
                orphanCount: orphanCount,
                orphanSize: orphanBytes,
                archiveCount: archiveCount,
                archiveSize: archiveBytes,
                originalPath: originalPath
            ))
        }
        
        if !rootFiles.isEmpty {
            let existing = restoreFolderMappings.first(where: { $0.id == target.path })
            let dest = existing?.destinationURL ?? home.appendingPathComponent("Restored_Root_Files")
            let selected = existing?.isSelected ?? true
            let totalBytes = rootFiles.reduce(0) { $0 + $1.size }
            let activeFiles = rootFiles.filter { !$0.isOrphaned && !$0.isVersionedArchive }
            let orphanFiles = rootFiles.filter { $0.isOrphaned }
            let archiveFiles = rootFiles.filter { $0.isVersionedArchive }
            newMappings.append(FolderRestoreMapping(
                folderName: "Root Files",
                sourceFolderURL: target,
                destinationURL: dest,
                isSelected: selected,
                totalSize: totalBytes,
                fileCount: rootFiles.count,
                activeSize: activeFiles.reduce(0) { $0 + $1.size },
                activeFileCount: activeFiles.count,
                orphanCount: orphanFiles.count,
                orphanSize: orphanFiles.reduce(0) { $0 + $1.size },
                archiveCount: archiveFiles.count,
                archiveSize: archiveFiles.reduce(0) { $0 + $1.size },
                originalPath: target.path
            ))
        }
        
        DispatchQueue.main.async {
            self.restoreFolderMappings = newMappings
        }
    }

    public func autoMapRestoreDestinationsToStandardFolders() {
        let home = fileManager.homeDirectoryForCurrentUser
        for i in 0..<restoreFolderMappings.count {
            let folderName = restoreFolderMappings[i].folderName
            let manifestSource = currentManifest?.sources.first(where: { $0.folderName == folderName })
            if let relHome = manifestSource?.relativeHomePath, !relHome.isEmpty {
                restoreFolderMappings[i].destinationURL = home.appendingPathComponent(relHome)
            } else {
                restoreFolderMappings[i].destinationURL = home.appendingPathComponent(folderName)
            }
        }
    }

    public func setCommonRestoreDestination(_ commonParent: URL) {
        for i in 0..<restoreFolderMappings.count {
            if restoreFolderMappings[i].isSelected {
                restoreFolderMappings[i].destinationURL = commonParent.appendingPathComponent(restoreFolderMappings[i].folderName)
            }
        }
    }

    public func selectAllRestoreMappings(_ select: Bool) {
        for i in 0..<restoreFolderMappings.count {
            restoreFolderMappings[i].isSelected = select
        }
    }

    public func performMappedRestore(
        mappings: [FolderRestoreMapping],
        conflictPolicy: ConflictPolicy = .keepBoth,
        includeOrphans: Bool = false,
        includeArchives: Bool = false
    ) {
        guard let target = targetFolder else { return }
        guard !isRestoring && !isBackingUp else { return }
        
        let activeMappings = mappings.filter { $0.isSelected }
        guard !activeMappings.isEmpty else { return }
        
        isRestoring = true
        isCancelRequested = false
        restoreStatus = "Starting mapped restore..."
        restoredFilesCount = 0
        restoreProgress = 0.0
        totalBytesTransferred = 0
        transferRateFormatted = ""
        estimatedTimeRemainingFormatted = ""
        
        let totalBytes: Int64 = activeMappings.reduce(Int64(0)) { sum, m in
            var bytes = m.activeSize
            if includeOrphans { bytes += m.orphanSize }
            if includeArchives { bytes += m.archiveSize }
            return sum + bytes
        }
        totalBytesToTransfer = totalBytes
        
        let token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Running Mapped Restore")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                ProcessInfo.processInfo.endActivity(token)
            }
            
            let startTime = Date()
            
            do {
                for mapping in activeMappings {
                    if self.isCancelRequested {
                        throw NSError(domain: "RestoreEngine", code: 99, userInfo: [NSLocalizedDescriptionKey: "Restore cancelled by user."])
                    }
                    
                    if !self.fileManager.fileExists(atPath: mapping.destinationURL.path) {
                        try self.fileManager.createDirectory(at: mapping.destinationURL, withIntermediateDirectories: true, attributes: nil)
                    }
                    
                    if mapping.sourceFolderURL == target {
                        let rootFiles = self.targetNodes.filter { leaf in
                            if leaf.isDirectory { return false }
                            if !includeOrphans && leaf.isOrphaned { return false }
                            if !includeArchives && leaf.isVersionedArchive { return false }
                            return true
                        }
                        for f in rootFiles {
                            if self.isCancelRequested {
                                throw NSError(domain: "RestoreEngine", code: 99, userInfo: [NSLocalizedDescriptionKey: "Restore cancelled by user."])
                            }
                            let dest = mapping.destinationURL.appendingPathComponent(f.name)
                            try self.safeRestoreAndVerify(source: f.url, target: dest, conflictPolicy: conflictPolicy) { bytes in
                                self.updateTransferMetrics(bytesCopied: bytes, startTime: startTime)
                            }
                            DispatchQueue.main.async {
                                self.restoredFilesCount += 1
                                if self.totalBytesToTransfer > 0 {
                                    self.restoreProgress = min(1.0, Double(self.totalBytesTransferred) / Double(self.totalBytesToTransfer))
                                }
                            }
                        }
                    } else if let rootNode = self.targetNodes.first(where: { $0.url == mapping.sourceFolderURL }) {
                        try self.restoreFolderMappingRecursively(
                            rootNode,
                            sourceRoot: mapping.sourceFolderURL,
                            destinationRoot: mapping.destinationURL,
                            conflictPolicy: conflictPolicy,
                            includeOrphans: includeOrphans,
                            includeArchives: includeArchives,
                            startTime: startTime
                        )
                    } else {
                        try self.restoreDirectoryFromDisk(
                            sourceDir: mapping.sourceFolderURL,
                            destinationDir: mapping.destinationURL,
                            conflictPolicy: conflictPolicy,
                            includeOrphans: includeOrphans,
                            includeArchives: includeArchives,
                            startTime: startTime
                        )
                    }
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

    private func restoreFolderMappingRecursively(
        _ node: FileSystemNode,
        sourceRoot: URL,
        destinationRoot: URL,
        conflictPolicy: ConflictPolicy,
        includeOrphans: Bool = false,
        includeArchives: Bool = false,
        startTime: Date
    ) throws {
        if isCancelRequested {
            throw NSError(domain: "RestoreEngine", code: 99, userInfo: [NSLocalizedDescriptionKey: "Restore cancelled by user."])
        }
        
        if !includeOrphans && node.isOrphaned {
            return
        }
        
        if node.isDirectory {
            if let children = node.children {
                for child in children {
                    try restoreFolderMappingRecursively(
                        child,
                        sourceRoot: sourceRoot,
                        destinationRoot: destinationRoot,
                        conflictPolicy: conflictPolicy,
                        includeOrphans: includeOrphans,
                        includeArchives: includeArchives,
                        startTime: startTime
                    )
                }
            }
        } else {
            if !includeOrphans && node.isOrphaned {
                return
            }
            if !includeArchives && node.isVersionedArchive {
                return
            }
            
            guard let relativePath = PathSecurity.relativeSubpath(of: node.url, relativeTo: sourceRoot) else {
                return
            }
            let destURL = destinationRoot.appendingPathComponent(relativePath)
            
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

    private func restoreDirectoryFromDisk(
        sourceDir: URL,
        destinationDir: URL,
        conflictPolicy: ConflictPolicy,
        includeOrphans: Bool = false,
        includeArchives: Bool = false,
        startTime: Date
    ) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let enumerator = fileManager.enumerator(at: sourceDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        
        while let fileURL = enumerator?.nextObject() as? URL {
            if isCancelRequested {
                throw NSError(domain: "RestoreEngine", code: 99, userInfo: [NSLocalizedDescriptionKey: "Restore cancelled by user."])
            }
            let vals = try? fileURL.resourceValues(forKeys: Set(keys))
            if vals?.isSymbolicLink == true || vals?.isDirectory == true {
                continue
            }
            
            let isArchive = Self.archiveRegex.firstMatch(in: fileURL.lastPathComponent, options: [], range: NSRange(location: 0, length: fileURL.lastPathComponent.utf16.count)) != nil
            if !includeArchives && isArchive {
                continue
            }
            
            if let cachedNode = self.nodeLookup[fileURL.path], !includeOrphans && cachedNode.isOrphaned {
                continue
            }
            
            guard let relativePath = PathSecurity.relativeSubpath(of: fileURL, relativeTo: sourceDir) else {
                continue
            }
            let destURL = destinationDir.appendingPathComponent(relativePath)
            
            DispatchQueue.main.async {
                self.currentFileName = fileURL.lastPathComponent
                self.restoreStatus = "Restoring \(fileURL.lastPathComponent)..."
            }
            
            try safeRestoreAndVerify(source: fileURL, target: destURL, conflictPolicy: conflictPolicy) { bytesRestored in
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
        let free = storageMetrics.macSSDFreeSpace
        let allowed = bytesNeeded <= free
        return (allowed, bytesNeeded.formattedBytes, free.formattedBytes)
    }

    public func performFullRestore(
        to destinationBaseURL: URL,
        conflictPolicy: ConflictPolicy = .keepBoth,
        includeOrphans: Bool = false,
        includeArchives: Bool = false
    ) {
        guard let target = targetFolder else { return }
        guard !isRestoring && !isBackingUp else { return }
        
        isRestoring = true
        isCancelRequested = false
        restoreStatus = "Starting full restore..."
        restoredFilesCount = 0
        restoreProgress = 0.0
        totalBytesTransferred = 0
        transferRateFormatted = ""
        estimatedTimeRemainingFormatted = ""
        
        let validNodes = targetNodes.filter { $0.name != ManifestManager.manifestDirectoryName }
        let totalBytes = flattenNodes(validNodes).filter { leaf in
            if leaf.isDirectory { return false }
            if !includeOrphans && leaf.isOrphaned { return false }
            if !includeArchives && leaf.isVersionedArchive { return false }
            return true
        }.reduce(0) { $0 + $1.size }
        totalBytesToTransfer = totalBytes
        
        let token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Running Restore")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                ProcessInfo.processInfo.endActivity(token)
            }
            
            let startTime = Date()
            
            do {
                for node in validNodes {
                    try self.restoreNodeRecursively(
                        node,
                        relativeToBase: target,
                        destinationBase: destinationBaseURL,
                        conflictPolicy: conflictPolicy,
                        includeOrphans: includeOrphans,
                        includeArchives: includeArchives,
                        startTime: startTime
                    )
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

    public func performSelectiveRestore(
        nodes: [FileSystemNode],
        destinationURL: URL,
        conflictPolicy: ConflictPolicy = .keepBoth,
        includeOrphans: Bool = false,
        includeArchives: Bool = false
    ) {
        guard targetFolder != nil else { return }
        guard !isRestoring && !isBackingUp else { return }
        
        isRestoring = true
        isCancelRequested = false
        restoreStatus = "Restoring selected items..."
        restoredFilesCount = 0
        restoreProgress = 0.0
        totalBytesTransferred = 0
        transferRateFormatted = ""
        estimatedTimeRemainingFormatted = ""
        
        let totalBytes = flattenNodes(nodes).filter { leaf in
            if leaf.isDirectory { return false }
            if !includeOrphans && leaf.isOrphaned && !nodes.contains(where: { $0.id == leaf.id }) { return false }
            if !includeArchives && leaf.isVersionedArchive && !nodes.contains(where: { $0.id == leaf.id }) { return false }
            return true
        }.reduce(0) { $0 + $1.size }
        totalBytesToTransfer = totalBytes
        
        let token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Running Selective Restore")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                ProcessInfo.processInfo.endActivity(token)
            }
            
            let startTime = Date()
            
            do {
                for node in nodes {
                    if node.isDirectory {
                        let sourceParent = node.url.deletingLastPathComponent()
                        try self.restoreFolderMappingRecursively(
                            node,
                            sourceRoot: sourceParent,
                            destinationRoot: destinationURL,
                            conflictPolicy: conflictPolicy,
                            includeOrphans: includeOrphans,
                            includeArchives: includeArchives,
                            startTime: startTime
                        )
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
                self.transferRateFormatted = "\(Int64(bytesPerSec).formattedBytes)/s"
                
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

    private func synthesizeCatalogIfMissing(target: URL) {
        guard currentCatalog == nil && !isMigrationMode && !sourceFolders.isEmpty else { return }
        
        var activePaths = Set<String>()
        for source in sourceFolders {
            let sourceParent = source.deletingLastPathComponent()
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
            let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let fileURL = enumerator?.nextObject() as? URL {
                let vals = try? fileURL.resourceValues(forKeys: Set(keys))
                if vals?.isSymbolicLink == true || vals?.isDirectory == true { continue }
                if let rel = PathSecurity.relativeSubpath(of: fileURL, relativeTo: sourceParent) {
                    activePaths.insert(rel)
                }
            }
        }
        
        var archivePaths = Set<String>()
        let targetKeys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let targetEnum = fileManager.enumerator(at: target, includingPropertiesForKeys: targetKeys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let fileURL = targetEnum?.nextObject() as? URL {
            let vals = try? fileURL.resourceValues(forKeys: Set(targetKeys))
            if vals?.isSymbolicLink == true || vals?.isDirectory == true { continue }
            if Self.archiveRegex.firstMatch(in: fileURL.lastPathComponent, options: [], range: NSRange(location: 0, length: fileURL.lastPathComponent.utf16.count)) != nil {
                if let rel = PathSecurity.relativeSubpath(of: fileURL, relativeTo: target) {
                    archivePaths.insert(rel)
                }
            }
        }
        
        let catalog = BackupCatalog(version: "2.6.0", updatedAt: Date(), activeFiles: activePaths, archivedVersions: archivePaths)
        try? CatalogManager.save(catalog, to: target)
        self.currentCatalog = catalog
    }

    public func refreshTargetFiles() {
        guard let target = targetFolder else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if self.currentCatalog == nil {
                self.currentCatalog = CatalogManager.load(from: target)
            }
            self.synthesizeCatalogIfMissing(target: target)
            
            let nodes = self.buildTree(for: target, targetRoot: target)
            
            // Build indexed dictionary and cache lists
            let allFlat = self.flattenNodes(nodes)
            var lookup: [String: FileSystemNode] = [:]
            lookup.reserveCapacity(allFlat.count)
            for n in allFlat {
                lookup[n.id] = n
            }
            
            let allLeaves = allFlat.filter { !$0.isDirectory }
            let orphanLeaves = allLeaves.filter { $0.isOrphaned }
            let versionArchives = allLeaves.filter { $0.isVersionedArchive }
            let orphanRatio = allLeaves.isEmpty ? 0 : Double(orphanLeaves.count) / Double(allLeaves.count)
            let isLocked = self.isMigrationMode || self.sourceFolders.isEmpty || (orphanRatio > 0.5 && allLeaves.count > 10)
            
            DispatchQueue.main.async {
                self.targetNodes = nodes
                self.nodeLookup = lookup
                self.allOrphans = orphanLeaves
                self.allVersionedArchives = versionArchives
                self.orphanSafetyLocked = isLocked
                self.calculateStorageMetrics()
                self.refreshRestoreFolderMappings()
            }
        }
    }
    
    private func buildTree(for url: URL, targetRoot: URL) -> [FileSystemNode] {
        var nodes: [FileSystemNode] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]
        
        guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return nodes
        }
        
        for itemURL in contents {
            if itemURL.lastPathComponent == ManifestManager.manifestDirectoryName {
                continue
            }
            
            let attr = try? itemURL.resourceValues(forKeys: Set(keys))
            if attr?.isSymbolicLink == true {
                continue
            }
            
            let isDir = attr?.isDirectory ?? false
            let modDate = attr?.contentModificationDate ?? Date()
            let size = Int64(attr?.fileSize ?? 0)
            
            guard let relativePath = PathSecurity.relativeSubpath(of: itemURL, relativeTo: targetRoot) else {
                continue
            }
            
            if isDir {
                let children = buildTree(for: itemURL, targetRoot: targetRoot)
                let dirOrphaned = !children.isEmpty && children.allSatisfy { $0.isOrphaned }
                nodes.append(FileSystemNode(
                    url: itemURL,
                    name: itemURL.lastPathComponent,
                    isDirectory: true,
                    modificationDate: modDate,
                    size: size,
                    isOrphaned: dirOrphaned,
                    isVersionedArchive: false,
                    children: children.isEmpty ? nil : children
                ))
            } else {
                let isVersioned: Bool
                let isOrphaned: Bool
                
                if let catalog = self.currentCatalog {
                    // Catalog Index Ground Truth (works accurately across any Mac!)
                    if catalog.activeFiles.contains(relativePath) {
                        isVersioned = false
                        isOrphaned = false
                    } else if catalog.archivedVersions.contains(relativePath) || Self.archiveRegex.firstMatch(in: itemURL.lastPathComponent, options: [], range: NSRange(location: 0, length: itemURL.lastPathComponent.utf16.count)) != nil {
                        isVersioned = true
                        isOrphaned = false
                    } else {
                        isVersioned = false
                        isOrphaned = true
                    }
                } else {
                    // Fallback for legacy backups without catalog.json
                    isVersioned = Self.archiveRegex.firstMatch(in: itemURL.lastPathComponent, options: [], range: NSRange(location: 0, length: itemURL.lastPathComponent.utf16.count)) != nil
                    
                    var foundInSource = false
                    if !isMigrationMode && !sourceFolders.isEmpty {
                        let baseRelativePath = relativePath.replacingOccurrences(of: "(_|\\.v)\\d{8}_\\d{6}(_\\d+)?(\\.[^.]+)?$", with: "", options: .regularExpression)
                        for source in self.sourceFolders {
                            let sourceParent = source.deletingLastPathComponent()
                            let expectedSourceURL = sourceParent.appendingPathComponent(baseRelativePath)
                            if self.fileManager.fileExists(atPath: expectedSourceURL.path) {
                                foundInSource = true
                                break
                            }
                        }
                    } else {
                        foundInSource = true
                    }
                    isOrphaned = !isVersioned && !foundInSource
                }
                
                nodes.append(FileSystemNode(
                    url: itemURL,
                    name: itemURL.lastPathComponent,
                    isDirectory: false,
                    modificationDate: modDate,
                    size: size,
                    isOrphaned: isOrphaned,
                    isVersionedArchive: isVersioned,
                    children: nil
                ))
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
    
    public func findNode(by id: String, in nodes: [FileSystemNode]? = nil) -> FileSystemNode? {
        if nodes == nil, let fastFound = nodeLookup[id] {
            return fastFound
        }
        if nodes == nil {
            let altId = id.hasPrefix("/var/") ? "/private" + id : (id.hasPrefix("/private/var/") ? String(id.dropFirst(8)) : id)
            if let altFound = nodeLookup[altId] {
                return altFound
            }
        }
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
        guard let target = targetFolder, PathSecurity.isSubpath(of: node.url, inside: target) else {
            backupStatus = "Security Guard: Deletion outside backup drive rejected."
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
        guard let target = targetFolder else { return }
        let nodesToDelete = checkedNodes.compactMap { nodeLookup[$0] }
            .filter { PathSecurity.isSubpath(of: $0.url, inside: target) }
        for node in nodesToDelete {
            try? fileManager.removeItem(at: node.url)
        }
        checkedNodes.removeAll()
        refreshTargetFiles()
    }

    public func recoverOrphan(node: FileSystemNode, to destinationURL: URL?) {
        guard let target = targetFolder, PathSecurity.isSubpath(of: node.url, inside: target) else {
            backupStatus = "Security Guard: Source file is outside backup drive."
            return
        }
        let destDir = destinationURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Restored_Orphans")
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)
        let targetFile = destDir.appendingPathComponent(node.name)
        try? safeRestoreAndVerify(source: node.url, target: targetFile, conflictPolicy: .keepBoth)
        backupStatus = "Recovered \(node.name) to \(destDir.lastPathComponent)"
    }

    public func recoverSelectedOrphans(to destinationURL: URL?) {
        guard let target = targetFolder else { return }
        let destDir = destinationURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Restored_Orphans")
        let orphansToRecover = checkedNodes.compactMap { nodeLookup[$0] }
            .filter { $0.isOrphaned && PathSecurity.isSubpath(of: $0.url, inside: target) }
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
                let sourceParent = source.deletingLastPathComponent()
                let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]
                let enumerator = self.fileManager.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                
                while let fileURL = enumerator?.nextObject() as? URL {
                    let resValues = try? fileURL.resourceValues(forKeys: Set(keys))
                    if resValues?.isSymbolicLink == true {
                        continue
                    }
                    
                    var isDir: ObjCBool = false
                    if self.fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                        continue
                    }
                    
                    totalFiles += 1
                    
                    guard let relativePath = PathSecurity.relativeSubpath(of: fileURL, relativeTo: sourceParent) else {
                        continue
                    }
                    let targetURL = target.appendingPathComponent(relativePath)
                    
                    if !self.fileManager.fileExists(atPath: targetURL.path) {
                        outOfSyncFiles += 1
                    } else {
                        let sourceAttr = try? self.fileManager.attributesOfItem(atPath: fileURL.path)
                        let targetAttr = try? self.fileManager.attributesOfItem(atPath: targetURL.path)
                        
                        let sourceSize = (sourceAttr?[.size] as? Int64) ?? 0
                        let targetSize = (targetAttr?[.size] as? Int64) ?? 0
                        let sourceDate = sourceAttr?[.modificationDate] as? Date ?? Date()
                        let targetDate = targetAttr?[.modificationDate] as? Date ?? Date.distantPast
                        
                        // Cross-filesystem 2.0s tolerance window
                        if (sourceSize != targetSize) || (sourceDate.timeIntervalSince(targetDate) > 2.0) {
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
