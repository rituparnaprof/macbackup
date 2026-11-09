//
//  BackupManifest.swift
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

public struct MachineMetadata: Codable, Equatable, Sendable {
    public var machineId: String
    public var hostname: String
    public var username: String

    public static func current() -> MachineMetadata {
        let defaults = UserDefaults.standard
        let key = "MacBackupLocalMachineID"
        let machineId: String
        if let existing = defaults.string(forKey: key) {
            machineId = existing
        } else {
            let newId = UUID().uuidString
            defaults.set(newId, forKey: key)
            machineId = newId
        }
        let hostname = Host.current().localizedName ?? Host.current().name ?? "Mac"
        let username = NSUserName()
        return MachineMetadata(machineId: machineId, hostname: hostname, username: username)
    }
}

public struct SourceMapping: Codable, Identifiable, Equatable, Sendable {
    public var id: String { folderName }
    public var folderName: String
    public var relativeHomePath: String?
    public var lastKnownPath: String

    public init(folderName: String, relativeHomePath: String? = nil, lastKnownPath: String) {
        self.folderName = folderName
        self.relativeHomePath = relativeHomePath
        self.lastKnownPath = lastKnownPath
    }
}

public struct BackupManifest: Codable, Sendable {
    public var version: String
    public var backupContainerId: String
    public var friendlyName: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastBackupMachine: MachineMetadata
    public var sources: [SourceMapping]

    public init(
        version: String = "2.6.0",
        backupContainerId: String = UUID().uuidString,
        friendlyName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastBackupMachine: MachineMetadata = .current(),
        sources: [SourceMapping] = []
    ) {
        self.version = version
        self.backupContainerId = backupContainerId
        self.friendlyName = friendlyName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastBackupMachine = lastBackupMachine
        self.sources = sources
    }
}

public enum ManifestManager {
    public static let manifestDirectoryName = ".macbackup"
    public static let manifestFileName = "manifest.json"

    public static func manifestURL(for targetFolder: URL) -> URL {
        targetFolder.appendingPathComponent(manifestDirectoryName).appendingPathComponent(manifestFileName)
    }

    public static func load(from targetFolder: URL) -> BackupManifest? {
        let url = manifestURL(for: targetFolder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupManifest.self, from: data)
    }

    public static func save(_ manifest: BackupManifest, to targetFolder: URL) throws {
        let dir = targetFolder.appendingPathComponent(manifestDirectoryName)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        let url = dir.appendingPathComponent(manifestFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    public static func delete(from targetFolder: URL) throws {
        let dir = targetFolder.appendingPathComponent(manifestDirectoryName)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: - Backup Catalog Index (Self-Contained File Ground Truth)

public struct BackupCatalog: Codable, Sendable {
    public var version: String
    public var updatedAt: Date
    public var activeFiles: Set<String>
    public var archivedVersions: Set<String>

    public init(
        version: String = "2.6.0",
        updatedAt: Date = Date(),
        activeFiles: Set<String> = [],
        archivedVersions: Set<String> = []
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.activeFiles = activeFiles
        self.archivedVersions = archivedVersions
    }
}

public enum CatalogManager {
    public static let catalogFileName = "catalog.json"

    public static func catalogURL(for targetFolder: URL) -> URL {
        targetFolder.appendingPathComponent(ManifestManager.manifestDirectoryName).appendingPathComponent(catalogFileName)
    }

    public static func load(from targetFolder: URL) -> BackupCatalog? {
        let url = catalogURL(for: targetFolder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupCatalog.self, from: data)
    }

    public static func save(_ catalog: BackupCatalog, to targetFolder: URL) throws {
        let dir = targetFolder.appendingPathComponent(ManifestManager.manifestDirectoryName)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        let url = dir.appendingPathComponent(catalogFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)
        try data.write(to: url, options: .atomic)
    }

    public static func delete(from targetFolder: URL) throws {
        let url = catalogURL(for: targetFolder)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
