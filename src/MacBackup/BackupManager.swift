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

struct FileSystemNode: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let modificationDate: Date
    let size: Int64
    var isOrphaned: Bool
    var children: [FileSystemNode]?
}

class BackupManager: ObservableObject {
    @Published var sourceFolders: [URL] = []
    @Published var targetFolder: URL?
    @Published var targetNodes: [FileSystemNode] = []
    @Published var isBackingUp = false
    @Published var backupStatus = ""
    
    @Published var showingBackupPrompt = false
    @Published var checkedNodes: Set<String> = []
    @Published var isDriveConnected = false
    
    @AppStorage("registeredDriveUUID") var registeredDriveUUID: String = ""
    @AppStorage("savedTargetFolderPath") var savedTargetFolderPath: String = ""
    @AppStorage("savedSourceFolderPaths") var savedSourceFolderPaths: String = ""
    @AppStorage("savedLastBackupDate") var savedLastBackupDate: Double = 0

    @Published var lastBackupDate: Date?
    @Published var newFilesAdded: Int = 0
    @Published var modifiedFilesUpdated: Int = 0
    @Published var pendingBackupPercentage: Double = 0

    private let fileManager = FileManager.default
    private var cancellables = Set<AnyCancellable>()
    private var activityToken: NSObjectProtocol?

    init() {
        if savedLastBackupDate > 0 {
            lastBackupDate = Date(timeIntervalSince1970: savedLastBackupDate)
        }
        
        if !savedSourceFolderPaths.isEmpty {
            let paths = savedSourceFolderPaths.components(separatedBy: "|")
            sourceFolders = paths.map { URL(fileURLWithPath: $0) }
        }
        
        if !savedTargetFolderPath.isEmpty {
            targetFolder = URL(fileURLWithPath: savedTargetFolderPath)
            refreshTargetFiles()
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

    private func checkDriveConnectionStatus() {
        guard !registeredDriveUUID.isEmpty else {
            isDriveConnected = false
            return
        }
        let mountedVolumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
        isDriveConnected = mountedVolumes.contains { url in
            (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == registeredDriveUUID
        }
    }

    private func handleDriveMount(notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        
        if let uuid = try? volumeURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString, uuid == registeredDriveUUID {
            print("Registered Backup Drive Mounted!")
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
                
                self.refreshTargetFiles()
                self.calculateSyncStatus()
                NotificationCenter.default.post(name: Notification.Name("RegisteredDriveMounted"), object: nil)
                
                // Bring app to foreground
                NSApp.activate(ignoringOtherApps: true)
                self.showingBackupPrompt = true
            }
        }
    }
    
    private func handleDriveUnmount(notification: Notification) {
        DispatchQueue.main.async {
            self.checkDriveConnectionStatus()
            if !self.isDriveConnected {
                self.targetFolder = nil
                self.targetNodes = []
            }
        }
    }

    func selectSourceFolders() {
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

    func selectTargetFolder() {
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
            
            checkDriveConnectionStatus()
            refreshTargetFiles()
            calculateSyncStatus()
        }
    }
    
    func ejectDrive() {
        guard let url = targetFolder else { return }
        // Find the volume root
        guard let volumeURL = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return }
        
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            DispatchQueue.main.async {
                self.backupStatus = "Drive safely ejected!"
                // handleDriveUnmount will trigger and clear the targetFolder and UI
            }
        } catch {
            DispatchQueue.main.async {
                self.backupStatus = "Eject Failed: \(error.localizedDescription)"
            }
        }
    }
    
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

    func performBackup() {
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

    func refreshTargetFiles() {
        guard let target = targetFolder else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let nodes = self.buildTree(for: target, targetRoot: target)
            DispatchQueue.main.async {
                self.targetNodes = nodes
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
            let attr = try? itemURL.resourceValues(forKeys: Set(keys))
            let isDir = attr?.isDirectory ?? false
            let modDate = attr?.contentModificationDate ?? Date()
            let size = Int64(attr?.fileSize ?? 0)
            
            let relativePath = itemURL.path.replacingOccurrences(of: targetRoot.path + "/", with: "")
            let baseRelativePath = relativePath.replacingOccurrences(of: "_\\d{8}_\\d{6}", with: "", options: .regularExpression)
            
            var foundInSource = false
            for source in self.sourceFolders {
                let sourceParentPath = source.deletingLastPathComponent().path + "/"
                let expectedSourcePath = sourceParentPath + baseRelativePath
                if self.fileManager.fileExists(atPath: expectedSourcePath) {
                    foundInSource = true
                    break
                }
            }
            let isOrphaned = !foundInSource
            
            if isDir {
                let children = buildTree(for: itemURL, targetRoot: targetRoot)
                nodes.append(FileSystemNode(url: itemURL, name: itemURL.lastPathComponent, isDirectory: true, modificationDate: modDate, size: size, isOrphaned: isOrphaned, children: children.isEmpty ? nil : children))
            } else {
                nodes.append(FileSystemNode(url: itemURL, name: itemURL.lastPathComponent, isDirectory: false, modificationDate: modDate, size: size, isOrphaned: isOrphaned, children: nil))
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
    
    func findNode(by id: String, in nodes: [FileSystemNode]? = nil) -> FileSystemNode? {
        let searchNodes = nodes ?? targetNodes
        for node in searchNodes {
            if node.id == id { return node }
            if let children = node.children, let found = findNode(by: id, in: children) {
                return found
            }
        }
        return nil
    }
    
    func deleteNode(_ node: FileSystemNode) {
        do {
            try fileManager.removeItem(at: node.url)
            refreshTargetFiles()
        } catch {
            print("Error deleting file/folder: \(error)")
        }
    }
    
    func deleteSelectedNodes() {
        let nodesToDelete = checkedNodes.compactMap { findNode(by: $0) }
        for node in nodesToDelete {
            try? fileManager.removeItem(at: node.url)
        }
        checkedNodes.removeAll()
        refreshTargetFiles()
    }
    
    func calculateSyncStatus() {
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
                        
                        // Use a small buffer for modification date comparison (1.1s)
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
