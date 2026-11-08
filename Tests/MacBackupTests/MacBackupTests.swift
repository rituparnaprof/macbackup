//
//  MacBackupTests.swift
//  MacBackupTests
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

import XCTest
import Foundation
@testable import MacBackup

final class MacBackupTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MacBackupTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: nil)
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectory, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Path Security & Traversal Tests

    func testPathSecurityRelativeSubpathValid() {
        let base = URL(fileURLWithPath: "/Users/tester/Documents")
        let file = URL(fileURLWithPath: "/Users/tester/Documents/Projects/App/main.swift")
        
        let relative = PathSecurity.relativeSubpath(of: file, relativeTo: base)
        XCTAssertEqual(relative, "Projects/App/main.swift")
    }

    func testPathSecurityDuplicateFolderNames() {
        // Ensures relativeSubpath does not strip nested folder names with identical names
        let base = URL(fileURLWithPath: "/Users/tester/Documents/tester")
        let file = URL(fileURLWithPath: "/Users/tester/Documents/tester/tester/file.txt")
        
        let relative = PathSecurity.relativeSubpath(of: file, relativeTo: base)
        XCTAssertEqual(relative, "tester/file.txt")
    }

    func testPathSecurityOutsideDirectoryRejected() {
        let base = URL(fileURLWithPath: "/Users/tester/Documents")
        let outside = URL(fileURLWithPath: "/Users/tester/Pictures/photo.jpg")
        
        let relative = PathSecurity.relativeSubpath(of: outside, relativeTo: base)
        XCTAssertNil(relative, "Files outside base must return nil")
    }

    func testPathSecurityIsSubpath() {
        let parent = URL(fileURLWithPath: "/Volumes/BackupDrive/Backups")
        let child = URL(fileURLWithPath: "/Volumes/BackupDrive/Backups/Documents/file.pdf")
        let outside = URL(fileURLWithPath: "/Volumes/BackupDrive/System/file.pdf")
        let parentSelf = URL(fileURLWithPath: "/Volumes/BackupDrive/Backups")
        
        XCTAssertTrue(PathSecurity.isSubpath(of: child, inside: parent))
        XCTAssertFalse(PathSecurity.isSubpath(of: outside, inside: parent))
        XCTAssertFalse(PathSecurity.isSubpath(of: parentSelf, inside: parent))
    }

    // MARK: - 2. Hash Verification & EOF Bug Defense

    func testHashFileEmptyFileTerminatesWithoutHanging() throws {
        // Verifies the critical EOF infinite loop bug is resolved:
        // Hashing an empty 0-byte file must terminate immediately.
        let emptyFile = tempDirectory.appendingPathComponent("empty.txt")
        try Data().write(to: emptyFile)

        let manager = BackupManager()
        let hash = manager.hashFile(url: emptyFile)
        
        XCTAssertNotNil(hash)
        // SHA-256 of empty string is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHashFileContentDeterminism() throws {
        let file = tempDirectory.appendingPathComponent("hello.txt")
        let content = "Hello, MacBackup v2.3.0!"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let manager = BackupManager()
        let hash1 = manager.hashFile(url: file)
        let hash2 = manager.hashFile(url: file)

        XCTAssertNotNil(hash1)
        XCTAssertEqual(hash1, hash2, "Hashing identical content must produce deterministic SHA-256")
    }

    func testHashFileMultiMegabyteChunking() throws {
        // Verifies 1 MB buffer chunking across a 2.5 MB file
        let largeFile = tempDirectory.appendingPathComponent("large.bin")
        let data = Data(repeating: 0xAB, count: Int(2.5 * 1024 * 1024))
        try data.write(to: largeFile)

        let manager = BackupManager()
        let hash = manager.hashFile(url: largeFile)
        XCTAssertNotNil(hash)
        XCTAssertEqual(hash?.count, 64, "SHA-256 hex string must be 64 characters")
    }

    // MARK: - 3. Manifest Serialization & Machine Lifecycle

    func testManifestSaveAndLoad() throws {
        let manifest = BackupManifest(
            version: "2.5.0",
            friendlyName: "Samsung T7",
            sources: [
                SourceMapping(folderName: "Documents", relativeHomePath: "Documents", lastKnownPath: "/Users/test/Documents")
            ]
        )

        try ManifestManager.save(manifest, to: tempDirectory)
        let loaded = ManifestManager.load(from: tempDirectory)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, "2.5.0")
        XCTAssertEqual(loaded?.friendlyName, "Samsung T7")
        XCTAssertEqual(loaded?.sources.count, 1)
        XCTAssertEqual(loaded?.sources.first?.folderName, "Documents")
        XCTAssertEqual(loaded?.lastBackupMachine.machineId, MachineMetadata.current().machineId)
    }

    func testManifestMigrationModeDetection() throws {
        // Manifest created with a different machine ID
        let foreignMachine = MachineMetadata(machineId: "FOREIGN_MACHINE_UUID", hostname: "MacBookPro-Other", username: "alex")
        let manifest = BackupManifest(
            version: "2.5.0",
            friendlyName: "External Drive",
            lastBackupMachine: foreignMachine
        )

        try ManifestManager.save(manifest, to: tempDirectory)
        let loaded = ManifestManager.load(from: tempDirectory)

        XCTAssertNotNil(loaded)
        XCTAssertNotEqual(loaded?.lastBackupMachine.machineId, MachineMetadata.current().machineId, "Foreign machine ID should not match local machine")
    }

    // MARK: - 4. Storage Metrics Arithmetic

    func testStorageMetricsUsedSpace() {
        var metrics = StorageMetrics()
        metrics.totalDriveCapacity = 1_000_000_000 // 1 GB
        metrics.freeDriveSpace = 400_000_000      // 400 MB
        metrics.orphanedFilesSize = 50_000_000    // 50 MB

        XCTAssertEqual(metrics.usedDriveSpace, 600_000_000)
        XCTAssertFalse(metrics.reclaimableSpaceFormatted.isEmpty)
    }

    func testFormattedByteCountExtension() {
        let oneKB: Int64 = 1024
        let oneMB: Int64 = 1024 * 1024
        let oneGB: Int64 = 1024 * 1024 * 1024

        XCTAssertTrue(oneKB.formattedBytes.contains("KB") || oneKB.formattedBytes.contains("kB"))
        XCTAssertTrue(oneMB.formattedBytes.contains("MB"))
        XCTAssertTrue(oneGB.formattedBytes.contains("GB"))
    }

    // MARK: - 5. Conflict Policy & Registration State

    func testConflictPolicyEnum() {
        XCTAssertEqual(ConflictPolicy.allCases.count, 3)
        XCTAssertEqual(ConflictPolicy.keepBoth.id, ConflictPolicy.keepBoth.rawValue)
        XCTAssertEqual(ConflictPolicy.overwrite.id, ConflictPolicy.overwrite.rawValue)
        XCTAssertEqual(ConflictPolicy.skip.id, ConflictPolicy.skip.rawValue)
    }

    func testDriveRegistrationStateEquality() {
        XCTAssertEqual(DriveRegistrationState.pairedThisMac, DriveRegistrationState.pairedThisMac)
        XCTAssertNotEqual(DriveRegistrationState.pairedThisMac, DriveRegistrationState.pairedOtherMac)
        XCTAssertNotEqual(DriveRegistrationState.unregistered, DriveRegistrationState.disconnected)
    }

    // MARK: - 6. File System Node & Hierarchy

    func testFileSystemNodeCreation() {
        let node = FileSystemNode(
            url: tempDirectory,
            name: tempDirectory.lastPathComponent,
            isDirectory: true,
            modificationDate: Date(),
            size: 1024,
            isOrphaned: false,
            isVersionedArchive: false
        )

        XCTAssertEqual(node.id, tempDirectory.path)
        XCTAssertTrue(node.isDirectory)
        XCTAssertFalse(node.isOrphaned)
        XCTAssertFalse(node.isVersionedArchive)
    }

    // MARK: - 7. Discovered Backup Model

    // MARK: - 7. Discovered Backup Model

    func testDiscoveredBackupStructure() {
        let manifest = BackupManifest(friendlyName: "SanDisk Extreme")
        let backupFolder = tempDirectory.appendingPathComponent("MacBackup")
        let discovered = DiscoveredBackup(
            volumeURL: tempDirectory,
            backupFolderURL: backupFolder,
            manifest: manifest,
            isSameMachine: true,
            volumeName: "ExtremeSSD"
        )

        XCTAssertEqual(discovered.id, backupFolder.path)
        XCTAssertEqual(discovered.volumeURL, tempDirectory)
        XCTAssertEqual(discovered.backupFolderURL, backupFolder)
        XCTAssertEqual(discovered.volumeName, "ExtremeSSD")
        XCTAssertTrue(discovered.isSameMachine)
        XCTAssertEqual(discovered.manifest.friendlyName, "SanDisk Extreme")
    }

    // MARK: - 8. Folder Restore Mapping

    func testFolderRestoreMappingStructure() {
        let sourceURL = tempDirectory.appendingPathComponent("Documents")
        let destURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        
        var mapping = FolderRestoreMapping(
            folderName: "Documents",
            sourceFolderURL: sourceURL,
            destinationURL: destURL,
            isSelected: true,
            totalSize: 1048576,
            fileCount: 42,
            originalPath: "/Users/test/Documents"
        )

        XCTAssertEqual(mapping.id, sourceURL.path)
        XCTAssertEqual(mapping.folderName, "Documents")
        XCTAssertEqual(mapping.sourceFolderURL, sourceURL)
        XCTAssertEqual(mapping.destinationURL, destURL)
        XCTAssertTrue(mapping.isSelected)
        XCTAssertEqual(mapping.totalSize, 1048576)
        XCTAssertEqual(mapping.fileCount, 42)
        XCTAssertEqual(mapping.originalPath, "/Users/test/Documents")

        // Test mutating destination
        let customDest = tempDirectory.appendingPathComponent("RestoredDocs")
        mapping.destinationURL = customDest
        XCTAssertEqual(mapping.destinationURL, customDest)

        // Test toggle selection
        mapping.isSelected = false
        XCTAssertFalse(mapping.isSelected)
    }

    func testFolderRestoreMappingGeneration() throws {
        // Create simulated backup folders
        let docsFolder = tempDirectory.appendingPathComponent("Documents")
        let desktopFolder = tempDirectory.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: docsFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktopFolder, withIntermediateDirectories: true)

        let manager = BackupManager()
        manager.targetFolder = tempDirectory
        manager.targetNodes = [
            FileSystemNode(url: docsFolder, name: "Documents", isDirectory: true, modificationDate: Date(), size: 500, isOrphaned: false, isVersionedArchive: false),
            FileSystemNode(url: desktopFolder, name: "Desktop", isDirectory: true, modificationDate: Date(), size: 300, isOrphaned: false, isVersionedArchive: false)
        ]

        manager.refreshRestoreFolderMappings()

        // Wait a brief tick for main thread update
        let expectation = XCTestExpectation(description: "Wait for mappings refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.restoreFolderMappings.count, 2)
            let folderNames = Set(manager.restoreFolderMappings.map { $0.folderName })
            XCTAssertTrue(folderNames.contains("Documents"))
            XCTAssertTrue(folderNames.contains("Desktop"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testFolderRestoreMappingActiveAndOrphanMetrics() {
        let sourceURL = tempDirectory.appendingPathComponent("Projects")
        let destURL = tempDirectory.appendingPathComponent("RestoredProjects")
        
        let mapping = FolderRestoreMapping(
            folderName: "Projects",
            sourceFolderURL: sourceURL,
            destinationURL: destURL,
            isSelected: true,
            totalSize: 2000,
            fileCount: 4,
            activeSize: 1500,
            activeFileCount: 3,
            orphanCount: 1,
            orphanSize: 500,
            originalPath: "/Users/test/Projects"
        )
        
        XCTAssertEqual(mapping.totalSize, 2000)
        XCTAssertEqual(mapping.fileCount, 4)
        XCTAssertEqual(mapping.activeSize, 1500)
        XCTAssertEqual(mapping.activeFileCount, 3)
        XCTAssertEqual(mapping.orphanCount, 1)
        XCTAssertEqual(mapping.orphanSize, 500)
    }

    func testRestoreExcludesOrphansByDefault() throws {
        let backupDir = tempDirectory.appendingPathComponent("BackupDir")
        let restoreDir = tempDirectory.appendingPathComponent("RestoreDir")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        
        // Active file
        let activeFile = backupDir.appendingPathComponent("active.txt")
        try "active content".data(using: .utf8)!.write(to: activeFile)
        
        // Orphaned file
        let orphanFile = backupDir.appendingPathComponent("deleted_on_mac.txt")
        try "orphan content".data(using: .utf8)!.write(to: orphanFile)
        
        let activeNode = FileSystemNode(url: activeFile, name: "active.txt", isDirectory: false, modificationDate: Date(), size: 14, isOrphaned: false, isVersionedArchive: false)
        let orphanNode = FileSystemNode(url: orphanFile, name: "deleted_on_mac.txt", isDirectory: false, modificationDate: Date(), size: 14, isOrphaned: true, isVersionedArchive: false)
        let rootNode = FileSystemNode(url: backupDir, name: "BackupDir", isDirectory: true, modificationDate: Date(), size: 28, isOrphaned: false, isVersionedArchive: false, children: [activeNode, orphanNode])
        
        let manager = BackupManager()
        manager.targetFolder = tempDirectory
        manager.targetNodes = [rootNode]
        
        let mapping = FolderRestoreMapping(
            folderName: "BackupDir",
            sourceFolderURL: backupDir,
            destinationURL: restoreDir,
            isSelected: true,
            totalSize: 28,
            fileCount: 2,
            activeSize: 14,
            activeFileCount: 1,
            orphanCount: 1,
            orphanSize: 14
        )
        
        let exp = XCTestExpectation(description: "Restore completes without orphans")
        manager.performMappedRestore(mappings: [mapping], conflictPolicy: .overwrite, includeOrphans: false, includeArchives: false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let restoredActive = restoreDir.appendingPathComponent("active.txt")
            let restoredOrphan = restoreDir.appendingPathComponent("deleted_on_mac.txt")
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: restoredActive.path), "Active file should be restored")
            XCTAssertFalse(FileManager.default.fileExists(atPath: restoredOrphan.path), "Orphan file must NOT be restored when includeOrphans is false")
            exp.fulfill()
        }
        
        wait(for: [exp], timeout: 3.0)
    }

    // MARK: - 9. Backup Catalog Index

    func testCatalogSaveAndLoad() throws {
        let catalog = BackupCatalog(
            version: "2.5.0",
            activeFiles: ["Documents/active.txt", "Desktop/notes.txt"],
            archivedVersions: ["Documents/active_20261108_120000.txt"]
        )

        try CatalogManager.save(catalog, to: tempDirectory)
        let loaded = CatalogManager.load(from: tempDirectory)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, "2.5.0")
        XCTAssertEqual(loaded?.activeFiles.count, 2)
        XCTAssertTrue(loaded?.activeFiles.contains("Documents/active.txt") == true)
        XCTAssertTrue(loaded?.archivedVersions.contains("Documents/active_20261108_120000.txt") == true)
    }

    func testCatalogOrphanAndArchiveDetectionOnNewMac() throws {
        let backupDir = tempDirectory.appendingPathComponent("TestCatalogBackup")
        let docsDir = backupDir.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        let activeURL = docsDir.appendingPathComponent("report.pdf")
        let archiveURL = docsDir.appendingPathComponent("report_20261108_120000.pdf")
        let orphanURL = docsDir.appendingPathComponent("old_deleted.txt")

        try "active".data(using: .utf8)!.write(to: activeURL)
        try "archived".data(using: .utf8)!.write(to: archiveURL)
        try "orphan".data(using: .utf8)!.write(to: orphanURL)

        // Save catalog identifying report.pdf as active and report_20261108_120000.pdf as archive
        let catalog = BackupCatalog(
            version: "2.5.0",
            activeFiles: ["Documents/report.pdf"],
            archivedVersions: ["Documents/report_20261108_120000.pdf"]
        )
        try CatalogManager.save(catalog, to: backupDir)

        let manager = BackupManager()
        manager.targetFolder = backupDir
        manager.isMigrationMode = true // Simulating New Mac
        manager.sourceFolders = []     // No local folders configured on new Mac
        manager.currentCatalog = catalog

        let exp = XCTestExpectation(description: "Scan target files with catalog on new Mac")
        manager.refreshTargetFiles()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let activeNode = manager.findNode(by: activeURL.path)
            let archiveNode = manager.findNode(by: archiveURL.path)
            let orphanNode = manager.findNode(by: orphanURL.path)

            XCTAssertNotNil(activeNode)
            XCTAssertFalse(activeNode?.isOrphaned ?? true, "Active file must not be orphaned on new Mac")
            XCTAssertFalse(activeNode?.isVersionedArchive ?? true, "Active file must not be archive")

            XCTAssertNotNil(archiveNode)
            XCTAssertTrue(archiveNode?.isVersionedArchive ?? false, "Archive file must be recognized as archive on new Mac")
            XCTAssertFalse(archiveNode?.isOrphaned ?? true, "Archive file must not be treated as orphan")

            XCTAssertNotNil(orphanNode)
            XCTAssertTrue(orphanNode?.isOrphaned ?? false, "File missing from catalog must be recognized as orphan on new Mac")
            XCTAssertFalse(orphanNode?.isVersionedArchive ?? true, "Orphan file must not be treated as archive")

            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
    }
}
