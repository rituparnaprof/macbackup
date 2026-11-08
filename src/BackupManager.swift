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

    // Restore State
    @Published public var isRestoring = false
    @Published public var restoreStatus = ""
    @Published public var restoreProgress: Double = 0.0
    @Published public var restoredFilesCount: Int = 0

    // Stored Preferences
    @AppStorage("registeredDriveUUID") public var registeredDriveUUID: String = ""
    @AppStorage("savedTargetFolderPath") public var savedTargetFolderPath: String = ""
    @AppStorage("savedSourceFolderPaths") public var savedSourceFolderPaths: String = ""
    @AppStorage("savedLastBackupDate") public var savedLastBackupDate: Double = 0

    private let fileManager = FileManager.default
    private var cancellables = Set<AnyCancellable>()
    private var activityToken: NSObjectProtocol?

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
        backupStatus = "Drive paired with this Mac successfully!"
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
    
    private func safeCopyAndVerify(source: URL, target: URL) throws {
        let tmpTarget = target.appendingPathExtension("tmp")
        
        if fileManager.fileExists(atPath: tmpTarget.path) {
            try fileManager.removeItem(at: tmpTarget)
        }
        
        // 1. Copy to tmp
        try performWithRetry {
            try fileManager.copyItem(at: source, to: tmpTarget)
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

    // MARK: - Backup Execution

    public func performBackup() {
        guard !sourceFolders.isEmpty, let target = targetFolder else { return }
        
        isBackingUp = true
        backupStatus = "Starting safe backup..."
        newFilesAdded = 0
        modifiedFilesUpdated = 0
        
        // Sleep Prevention
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
                // Update manifest source mappings
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
                DispatchQueue.main.async { self.currentManifest = manifest }

                for source in self.sourceFolders {
                    let resourceKeys: [URLResourceKey] = [.contentModificationDateKey]
                    let enumerator = self.fileManager.enumerator(at: source, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])
                    
                    while let fileURL = enumerator?.nextObject() as? URL {
                        var isDir: ObjCBool = false
                        if self.fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                            continue
                        }
                        
                        let sourceParentPath = source.deletingLastPathComponent().path + "/"
                        let relativePath = fileURL.path.replacingOccurrences(of: sourceParentPath, with: "")
                        let targetURL = target.appendingPathComponent(relativePath)
                        
                        let targetDir = targetURL.deletingLastPathComponent()
                        if !self.fileManager.fileExists(atPath: targetDir.path) {
                            try? self.fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
                        }
                        
                        if self.fileManager.fileExists(atPath: targetURL.path) {
                            let sourceAttr = try? self.fileManager.attributesOfItem(atPath: fileURL.path)
                            let targetAttr = try? self.fileManager.attributesOfItem(atPath: targetURL.path)
                            
                            let sourceDate = sourceAttr?[.modificationDate] as? Date ?? Date()
                            let targetDate = targetAttr?[.modificationDate] as? Date ?? Date.distantPast
                            
                            if sourceDate.timeIntervalSince(targetDate) > 1.0 {
                                let ext = targetURL.pathExtension
                                let nameWithoutExt = targetURL.deletingPathExtension().lastPathComponent
                                
                                let formatter = DateFormatter()
                                formatter.dateFormat = "yyyyMMdd_HHmmss"
                                let timestamp = formatter.string(from: targetDate)
                                
                                let oldFileName = "\(nameWithoutExt)_\(timestamp).\(ext)"
                                let oldTargetURL = targetURL.deletingLastPathComponent().appendingPathComponent(oldFileName)
                                
                                if self.fileManager.fileExists(atPath: oldTargetURL.path) {
                                    try? self.fileManager.removeItem(at: oldTargetURL)
                                }
                                try self.performWithRetry {
                                    try self.fileManager.moveItem(at: targetURL, to: oldTargetURL)
                                }
                                
                                DispatchQueue.main.async {
                                    self.backupStatus = "Safe updating: \(targetURL.lastPathComponent)..."
                                    self.modifiedFilesUpdated += 1
                                }
                                try self.safeCopyAndVerify(source: fileURL, target: targetURL)
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.backupStatus = "Safe copying: \(targetURL.lastPathComponent)..."
                                self.newFilesAdded += 1
                            }
                            try self.safeCopyAndVerify(source: fileURL, target: targetURL)
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.backupStatus = "Backup completed flawlessly!"
                    self.lastBackupDate = Date()
                    self.savedLastBackupDate = self.lastBackupDate!.timeIntervalSince1970
                    self.isBackingUp = false
                    self.refreshTargetFiles()
                    self.calculateSyncStatus()
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.backupStatus = "Error: \(error.localizedDescription)"
                    self.isBackingUp = false
                }
            }
        }
    }

    // MARK: - Restore Engine (Reverse Staging with SHA-256)

    private func safeRestoreAndVerify(source: URL, target: URL, conflictPolicy: ConflictPolicy) throws {
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

    private func restoreNodeRecursively(_ node: FileSystemNode, relativeToBase: URL, destinationBase: URL, conflictPolicy: ConflictPolicy) throws {
        if node.isDirectory {
            if let children = node.children {
                for child in children {
                    try restoreNodeRecursively(child, relativeToBase: relativeToBase, destinationBase: destinationBase, conflictPolicy: conflictPolicy)
                }
            }
        } else {
            let relativePath = node.url.path.replacingOccurrences(of: relativeToBase.path + "/", with: "")
            let destURL = destinationBase.appendingPathComponent(relativePath)
            try safeRestoreAndVerify(source: node.url, target: destURL, conflictPolicy: conflictPolicy)
            DispatchQueue.main.async {
                self.restoredFilesCount += 1
                self.restoreStatus = "Restored: \(node.name)"
            }
        }
    }

    public func performFullRestore(to destinationBaseURL: URL, conflictPolicy: ConflictPolicy = .keepBoth) {
        guard let target = targetFolder else { return }
        
        isRestoring = true
        restoreStatus = "Starting full restore..."
        restoredFilesCount = 0
        restoreProgress = 0.0
        
        activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Running Restore")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                if let token = self.activityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    self.activityToken = nil
                }
            }
            
            do {
                for node in self.targetNodes {
                    if node.name == ManifestManager.manifestDirectoryName { continue }
                    try self.restoreNodeRecursively(node, relativeToBase: target, destinationBase: destinationBaseURL, conflictPolicy: conflictPolicy)
                }
                
                DispatchQueue.main.async {
                    self.restoreStatus = "Restore completed successfully! \(self.restoredFilesCount) files restored."
                    self.isRestoring = false
                    self.restoreProgress = 1.0
                }
            } catch {
                DispatchQueue.main.async {
                    self.restoreStatus = "Restore Failed: \(error.localizedDescription)"
                    self.isRestoring = false
                }
            }
        }
    }

    public func performSelectiveRestore(nodes: [FileSystemNode], destinationURL: URL, conflictPolicy: ConflictPolicy = .keepBoth) {
        guard let target = targetFolder else { return }
        
        isRestoring = true
        restoreStatus = "Restoring selected items..."
        restoredFilesCount = 0
        restoreProgress = 0.0
        
        activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Running Selective Restore")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                if let token = self.activityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    self.activityToken = nil
                }
            }
            
            do {
                for node in nodes {
                    if node.isDirectory {
                        try self.restoreNodeRecursively(node, relativeToBase: target, destinationBase: destinationURL, conflictPolicy: conflictPolicy)
                    } else {
                        let destFile = destinationURL.appendingPathComponent(node.name)
                        try self.safeRestoreAndVerify(source: node.url, target: destFile, conflictPolicy: conflictPolicy)
                        DispatchQueue.main.async {
                            self.restoredFilesCount += 1
                            self.restoreStatus = "Restored: \(node.name)"
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.restoreStatus = "Selected files restored successfully!"
                    self.isRestoring = false
                    self.restoreProgress = 1.0
                }
            } catch {
                DispatchQueue.main.async {
                    self.restoreStatus = "Restore Failed: \(error.localizedDescription)"
                    self.isRestoring = false
                }
            }
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
                // In migration mode or before sources are set, NEVER treat files as orphaned
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
