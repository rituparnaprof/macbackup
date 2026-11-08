//
//  ContentView.swift
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

import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case backup = "Backup"
    case restore = "Restore"
    case orphans = "Orphan Cleanup"

    var id: String { rawValue }
    var iconName: String {
        switch self {
        case .backup: return "arrow.up.circle"
        case .restore: return "arrow.down.circle"
        case .orphans: return "trash.circle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var backupManager: BackupManager
    @State private var selectedTab: MainTab = .backup
    @State private var selectedNodeID: String?
    
    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
        } detail: {
            VStack(spacing: 0) {
                // Migration Assistant Banner
                if backupManager.isMigrationMode {
                    MigrationBannerView(selectedTab: $selectedTab)
                }
                
                // Tab Content (Expands to fill available space)
                Group {
                    switch selectedTab {
                    case .backup:
                        BackupDetailView(selectedNodeID: $selectedNodeID)
                    case .restore:
                        RestoreDetailView()
                    case .orphans:
                        OrphanCleanupView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Divider()
                
                // Permanent Global Footer (Always visible across all tabs)
                GlobalStatusFooterView()
            }
        }
        .navigationTitle("Mac SSD Backup")
        .sheet(isPresented: $backupManager.showingSetupAssistant) {
            if let discovered = backupManager.activeSetupBackup {
                SetupAssistantView(discovered: discovered, selectedTab: $selectedTab)
            }
        }
        .alert("Backup Drive Detected", isPresented: $backupManager.showingBackupPrompt) {
            Button("Start Backup") {
                backupManager.performBackup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your registered backup drive has been connected. Would you like to sync now?")
        }
    }
}

// MARK: - Migration Banner

struct MigrationBannerView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Binding var selectedTab: MainTab
    @State private var showingAdoptAlert = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("New Mac Detected (Migration Mode)")
                    .font(.headline)
                    .foregroundColor(.orange)
                if let manifest = backupManager.currentManifest {
                    Text("This backup originated from '\(manifest.lastBackupMachine.hostname)' (\(manifest.lastBackupMachine.username)).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button("Auto-Link Folders") {
                backupManager.autoLinkStandardFolders()
            }
            .buttonStyle(.bordered)
            .help("Match backup folders to standard folders on this Mac (~/Documents, ~/Desktop, etc.)")
            
            Button("Restore to this Mac") {
                selectedTab = .restore
            }
            .buttonStyle(.borderedProminent)
            
            Button("Pair with this Mac") {
                showingAdoptAlert = true
            }
            .buttonStyle(.bordered)
            .confirmationDialog("Pair Drive with this Mac?", isPresented: $showingAdoptAlert) {
                Button("Pair and Update Machine Info") {
                    backupManager.adoptBackupForThisMac()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will designate your current Mac as the active source for future backups. Orphan detection will adapt to this machine.")
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.orange.opacity(0.3)), alignment: .bottom)
    }
}

// MARK: - Sidebar View

struct SidebarView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Binding var selectedTab: MainTab
    @State private var showingDeregisterLocalAlert = false
    @State private var showingDeregisterWipeAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // View Navigation
            VStack(alignment: .leading, spacing: 4) {
                Text("Views")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                
                ForEach(MainTab.allCases) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack {
                            Image(systemName: tab.iconName)
                            Text(tab.rawValue)
                            Spacer()
                            if tab == .orphans && !backupManager.allOrphans.isEmpty {
                                Text("\(backupManager.allOrphans.count)")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.2))
                                    .foregroundColor(.red)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Divider()

            // Target Drive
            VStack(alignment: .leading, spacing: 8) {
                Text("Target Drive")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                
                Button("Select & Register Target Folder") {
                    backupManager.selectTargetFolder()
                }
                
                if let first = backupManager.discoveredBackups.first, !backupManager.isDriveConnected {
                    Button(action: {
                        backupManager.activeSetupBackup = first
                        backupManager.showingSetupAssistant = true
                    }) {
                        Label("Set Up \(first.volumeName)", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(driveStatusColor)
                        .frame(width: 8, height: 8)
                    Text(driveStatusText)
                        .font(.caption)
                        .foregroundColor(driveStatusColor)
                }
                
                if let target = backupManager.targetFolder, backupManager.isDriveConnected {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(target.path)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        // Storage Metrics Indicator
                        if backupManager.storageMetrics.totalDriveCapacity > 0 {
                            VStack(alignment: .leading, spacing: 3) {
                                ProgressView(value: Double(backupManager.storageMetrics.usedDriveSpace), total: Double(backupManager.storageMetrics.totalDriveCapacity))
                                    .tint(.blue)
                                HStack {
                                    Text("\(backupManager.storageMetrics.freeDriveSpace.formattedBytes) free")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(backupManager.storageMetrics.totalDriveCapacity.formattedBytes)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        
                        HStack {
                            Menu {
                                Button("Eject Drive") {
                                    backupManager.ejectDrive()
                                }
                                Divider()
                                Button("Deregister on this Mac") {
                                    showingDeregisterLocalAlert = true
                                }
                                Button("Deregister & Erase Metadata...", role: .destructive) {
                                    showingDeregisterWipeAlert = true
                                }
                            } label: {
                                Label("Manage Drive", systemImage: "gearshape")
                                    .font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                            
                            Spacer()
                            
                            Button("Eject") {
                                backupManager.ejectDrive()
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                            .font(.caption)
                        }
                    }
                }
            }
            
            Divider()

            // Source Folders
            VStack(alignment: .leading, spacing: 8) {
                Text("Source Folders (Mac SSD)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                
                Button("Select Source Folders") {
                    backupManager.selectSourceFolders()
                }
                
                if backupManager.sourceFolders.isEmpty {
                    Text("No folders configured")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(backupManager.sourceFolders, id: \.self) { url in
                            HStack {
                                Image(systemName: "folder")
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(5)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Backup Trigger
            Button(action: {
                backupManager.performBackup()
            }) {
                Text(backupManager.isBackingUp ? "Backing up..." : "Start Backup")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(backupManager.sourceFolders.isEmpty || backupManager.targetFolder == nil || backupManager.isBackingUp || backupManager.isRestoring)
            
            if !backupManager.backupStatus.isEmpty {
                Text(backupManager.backupStatus)
                    .font(.caption2)
                    .foregroundColor(backupManager.backupStatus.contains("Error") ? .red : .green)
            }
        }
        .padding()
        .frame(minWidth: 220, maxWidth: 300)
        .confirmationDialog("Deregister Drive on this Mac?", isPresented: $showingDeregisterLocalAlert) {
            Button("Deregister on this Mac") {
                backupManager.deregisterFromThisMac()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the drive pairing from this computer. Your backup files and metadata on the drive will not be modified.")
        }
        .confirmationDialog("Deregister & Erase Metadata?", isPresented: $showingDeregisterWipeAlert) {
            Button("Erase Metadata & Unlink", role: .destructive) {
                backupManager.deregisterAndWipeMetadata()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete the .macbackup container configuration on the drive. Backed up files will remain, but the drive will be treated as completely new.")
        }
    }
    
    private var driveStatusColor: Color {
        switch backupManager.driveState {
        case .pairedThisMac: return .green
        case .pairedOtherMac: return .orange
        case .unregistered: return .yellow
        case .disconnected: return .red
        }
    }
    
    private var driveStatusText: String {
        switch backupManager.driveState {
        case .pairedThisMac: return "Connected & Paired"
        case .pairedOtherMac: return "Migration Mode"
        case .unregistered: 
            return backupManager.isDriveConnected ? "Unregistered Drive Connected" : "No Drive Configured"
        case .disconnected: return "Drive Disconnected"
        }
    }
}

// MARK: - Backup Detail View

struct BackupDetailView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Binding var selectedNodeID: String?
    @State private var showingBulkDeleteConfirmation = false
    
    var selectedNode: FileSystemNode? {
        guard let id = selectedNodeID else { return nil }
        return backupManager.findNode(by: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if backupManager.targetFolder == nil {
                Text("Select a Target Folder to view backed up files")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !backupManager.checkedNodes.isEmpty {
                    HStack {
                        Button(role: .destructive, action: {
                            showingBulkDeleteConfirmation = true
                        }) {
                            Label("Delete Selected (\(backupManager.checkedNodes.count))", systemImage: "trash")
                        }
                        .disabled(backupManager.orphanSafetyLocked)
                        .confirmationDialog("Delete Multiple Items", isPresented: $showingBulkDeleteConfirmation) {
                            Button("Delete \(backupManager.checkedNodes.count) Items", role: .destructive) {
                                backupManager.deleteSelectedNodes()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will permanently delete the selected items from the backup drive. This action cannot be undone.")
                        }
                        
                        if backupManager.orphanSafetyLocked {
                            Text("(Locked: Orphan safety active)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
                }
                
                // Live Backup Progress & Cancel Bar
                if backupManager.isBackingUp {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Backing up files...")
                                .font(.subheadline)
                                .bold()
                            Spacer()
                            if !backupManager.transferRateFormatted.isEmpty {
                                Text(backupManager.transferRateFormatted)
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(.blue)
                            }
                            if !backupManager.estimatedTimeRemainingFormatted.isEmpty {
                                Text("ETA: \(backupManager.estimatedTimeRemainingFormatted)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Button("Cancel", role: .destructive) {
                                backupManager.cancelTransfer()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        ProgressView(value: backupManager.pendingBackupPercentage, total: 100)
                        if !backupManager.currentFileName.isEmpty {
                            Text(backupManager.currentFileName)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                
                VSplitView {
                    List(backupManager.targetNodes, children: \.children, selection: $selectedNodeID) { node in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { backupManager.checkedNodes.contains(node.id) },
                                set: { isSelected in
                                    if isSelected {
                                        backupManager.checkedNodes.insert(node.id)
                                    } else {
                                        backupManager.checkedNodes.remove(node.id)
                                    }
                                }
                            ))
                            .labelsHidden()
                            .buttonStyle(PlainButtonStyle())
                            
                            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(node.name)
                                .foregroundColor(node.isOrphaned ? .red : .primary)
                            
                            if node.isOrphaned {
                                Text("(Orphaned)")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 4)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(4)
                            }
                            
                            if node.isVersionedArchive {
                                Text("(Archive)")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 4)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(4)
                            }
                            
                            Spacer(minLength: 20)
                            if !node.isDirectory {
                                Text(node.size.formattedBytes)
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .frame(minWidth: 300, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                    
                    if let node = selectedNode {
                        FilePreviewView(node: node)
                            .frame(minHeight: 150, maxHeight: .infinity)
                    } else {
                        Text("Select a file or folder to preview")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Restore Detail View

enum RestoreTabMode: String, CaseIterable, Identifiable {
    case folderMapping = "Folder Mappings"
    case selectiveBrowser = "Browse & Selective Files"
    var id: String { rawValue }
}

struct RestoreDetailView: View {
    @EnvironmentObject var backupManager: BackupManager
    @State private var restoreMode: RestoreTabMode = .folderMapping
    @State private var conflictPolicy: ConflictPolicy = .keepBoth
    @State private var includeOrphans: Bool = false
    @State private var includeArchives: Bool = false
    @State private var selectiveDestination: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var selectedRestoreNodeID: String?
    @State private var searchFilter: String = ""
    @State private var showingMappedRestoreConfirm = false
    @State private var showingSelectiveRestoreConfirm = false
    @State private var showingInsufficientSpaceAlert = false
    @State private var spaceAlertMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Data Recovery & Restore")
                        .font(.title2)
                        .bold()
                    Text("Select source backup folders and map where each folder should be restored on this Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                if backupManager.targetFolder != nil {
                    Button(action: {
                        chooseBackupFolder()
                    }) {
                        Label("Switch Backup...", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
            
            if backupManager.targetFolder == nil {
                // Empty state when no target folder is set
                RestoreEmptyStateView()
            } else {
                // Active Restore Interface
                VStack(spacing: 0) {
                    // Backup Source Card
                    RestoreSourceHeaderView()
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    
                    // Live Transfer Progress Banner (if active)
                    if backupManager.isRestoring {
                        RestoreProgressBannerView()
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                    } else if !backupManager.restoreStatus.isEmpty {
                        HStack {
                            Image(systemName: backupManager.restoreStatus.contains("Failed") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundColor(backupManager.restoreStatus.contains("Failed") ? .red : .green)
                            Text(backupManager.restoreStatus)
                                .font(.caption)
                                .foregroundColor(backupManager.restoreStatus.contains("Failed") ? .red : .green)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    
                    // Mode Picker
                    Picker("Restore Mode", selection: $restoreMode) {
                        ForEach(RestoreTabMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    
                    // Main Mode Content
                    if restoreMode == .folderMapping {
                        FolderMappingRestoreView(
                            conflictPolicy: $conflictPolicy,
                            includeOrphans: $includeOrphans,
                            includeArchives: $includeArchives,
                            showingMappedRestoreConfirm: $showingMappedRestoreConfirm,
                            showingInsufficientSpaceAlert: $showingInsufficientSpaceAlert,
                            spaceAlertMessage: $spaceAlertMessage
                        )
                    } else {
                        SelectiveFileRestoreView(
                            selectiveDestination: $selectiveDestination,
                            conflictPolicy: $conflictPolicy,
                            includeOrphans: $includeOrphans,
                            includeArchives: $includeArchives,
                            selectedRestoreNodeID: $selectedRestoreNodeID,
                            searchFilter: $searchFilter,
                            showingSelectiveRestoreConfirm: $showingSelectiveRestoreConfirm,
                            showingInsufficientSpaceAlert: $showingInsufficientSpaceAlert,
                            spaceAlertMessage: $spaceAlertMessage
                        )
                    }
                }
            }
        }
        .alert("Insufficient Disk Space", isPresented: $showingInsufficientSpaceAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(spaceAlertMessage)
        }
        .confirmationDialog("Confirm Folder Restore Mapping", isPresented: $showingMappedRestoreConfirm) {
            Button("Start Mapped Restore") {
                backupManager.performMappedRestore(
                    mappings: backupManager.restoreFolderMappings,
                    conflictPolicy: conflictPolicy,
                    includeOrphans: includeOrphans,
                    includeArchives: includeArchives
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let active = backupManager.restoreFolderMappings.filter { $0.isSelected }
            let summary = active.map { "• \($0.folderName) ➔ \($0.destinationURL.path)" }.joined(separator: "\n")
            let orphanNote = includeOrphans ? "Including orphaned files" : "Excluding all orphaned files"
            let archiveNote = includeArchives ? "Including version archives" : "Excluding version archives"
            Text("The following \(active.count) folder(s) will be restored (\(orphanNote), \(archiveNote)):\n\n\(summary)")
        }
        .confirmationDialog("Restore Checked Items?", isPresented: $showingSelectiveRestoreConfirm) {
            Button("Restore \(backupManager.restoreCheckedNodes.count) Items") {
                let nodes = backupManager.restoreCheckedNodes.compactMap { backupManager.findNode(by: $0) }
                backupManager.performSelectiveRestore(
                    nodes: nodes,
                    destinationURL: selectiveDestination,
                    conflictPolicy: conflictPolicy,
                    includeOrphans: includeOrphans,
                    includeArchives: includeArchives
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let orphanNote = includeOrphans ? "including orphans" : "excluding orphans"
            Text("Selected \(backupManager.restoreCheckedNodes.count) item(s) will be restored to '\(selectiveDestination.path)' (\(orphanNote)).")
        }
        .onAppear {
            if backupManager.restoreFolderMappings.isEmpty {
                backupManager.refreshRestoreFolderMappings()
            }
        }
    }
    
    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Backup Folder or Drive"
        panel.prompt = "Select"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            backupManager.selectBackupFolder(url)
        }
    }
}

// MARK: - Restore Subviews

struct RestoreEmptyStateView: View {
    @EnvironmentObject var backupManager: BackupManager

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "externaldrive.badge.questionmark")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundColor(.secondary.opacity(0.6))
            
            Text("No Backup Source Selected")
                .font(.title2)
                .bold()
            
            Text("Connect your external backup drive, or choose a backup folder on your Mac to restore files.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            
            Button(action: {
                let panel = NSOpenPanel()
                panel.title = "Select Backup Folder or Drive"
                panel.prompt = "Select"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    backupManager.selectBackupFolder(url)
                }
            }) {
                Label("Choose Backup Folder...", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            if !backupManager.discoveredBackups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Discovered Backups on External Volumes:")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    ForEach(backupManager.discoveredBackups) { discovered in
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                                .foregroundColor(.blue)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(discovered.volumeName)
                                    .font(.headline)
                                Text("Origin: \(discovered.manifest.lastBackupMachine.hostname) • \(discovered.manifest.sources.count) folder(s) • Updated \(discovered.manifest.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("Restore from This Drive") {
                                backupManager.prepareRestoreFromDiscoveredBackup(discovered)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(8)
                    }
                }
                .frame(maxWidth: 540)
                .padding(.top, 16)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct RestoreSourceHeaderView: View {
    @EnvironmentObject var backupManager: BackupManager

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("BACKUP REPOSITORY:")
                        .font(.caption2)
                        .bold()
                        .foregroundColor(.secondary)
                    Text(backupManager.targetFolder?.lastPathComponent ?? "Backup")
                        .font(.headline)
                    if backupManager.isMigrationMode {
                        Text("Migration Mode")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
                
                if let manifest = backupManager.currentManifest {
                    Text("Original Mac: \(manifest.lastBackupMachine.hostname) (\(manifest.lastBackupMachine.username)) • Last updated: \(manifest.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(backupManager.targetFolder?.path ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

struct RestoreProgressBannerView: View {
    @EnvironmentObject var backupManager: BackupManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Restoring Files...")
                    .font(.subheadline)
                    .bold()
                Spacer()
                if !backupManager.transferRateFormatted.isEmpty {
                    Text(backupManager.transferRateFormatted)
                        .font(.caption)
                        .bold()
                        .foregroundColor(.blue)
                }
                if !backupManager.estimatedTimeRemainingFormatted.isEmpty {
                    Text(backupManager.estimatedTimeRemainingFormatted)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("Cancel", role: .destructive) {
                    backupManager.cancelTransfer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            ProgressView(value: backupManager.restoreProgress)
            
            if !backupManager.currentFileName.isEmpty {
                Text(backupManager.currentFileName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(8)
    }
}

struct FolderMappingRestoreView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Binding var conflictPolicy: ConflictPolicy
    @Binding var includeOrphans: Bool
    @Binding var includeArchives: Bool
    @Binding var showingMappedRestoreConfirm: Bool
    @Binding var showingInsufficientSpaceAlert: Bool
    @Binding var spaceAlertMessage: String

    var body: some View {
        VStack(spacing: 8) {
            // Quick Batch Actions Bar
            HStack(spacing: 12) {
                Button("Select All") {
                    backupManager.selectAllRestoreMappings(true)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                
                Button("Deselect All") {
                    backupManager.selectAllRestoreMappings(false)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                
                Spacer()
                
                Button(action: {
                    backupManager.autoMapRestoreDestinationsToStandardFolders()
                }) {
                    Label("Auto-Map to This Mac", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Automatically map to matching standard folders (~/Documents, ~/Desktop, etc.) on this Mac")
                
                Button(action: {
                    chooseCommonParentDestination()
                }) {
                    Label("Set Common Destination...", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Direct all selected folders into a chosen common destination folder")
            }
            .padding(.horizontal, 16)
            
            // Options Bar (Exclude / Include Orphans & Archives)
            HStack(spacing: 16) {
                Toggle(isOn: $includeOrphans) {
                    HStack(spacing: 4) {
                        Image(systemName: includeOrphans ? "exclamationmark.triangle.fill" : "checkmark.shield")
                            .foregroundColor(includeOrphans ? .orange : .secondary)
                        Text("Include Orphaned Files (deleted from Mac)")
                            .font(.caption)
                    }
                }
                .toggleStyle(.checkbox)
                
                Toggle(isOn: $includeArchives) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.secondary)
                        Text("Include Version Archives")
                            .font(.caption)
                    }
                }
                .toggleStyle(.checkbox)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.04))
            .cornerRadius(6)
            .padding(.horizontal, 16)
            
            // Scrollable List of Mappings
            ScrollView {
                VStack(spacing: 8) {
                    if backupManager.restoreFolderMappings.isEmpty {
                        VStack(spacing: 8) {
                            Text("No folders found in this backup.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button("Scan Again") {
                                backupManager.refreshRestoreFolderMappings()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(40)
                    } else {
                        ForEach($backupManager.restoreFolderMappings) { $mapping in
                            FolderMappingRowView(
                                mapping: $mapping,
                                includeOrphans: includeOrphans,
                                includeArchives: includeArchives
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            
            Divider()
            
            // Bottom Action Bar
            HStack(alignment: .center, spacing: 20) {
                HStack(spacing: 6) {
                    Text("Conflict:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $conflictPolicy) {
                        ForEach(ConflictPolicy.allCases) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                
                Spacer()
                
                let activeMappings = backupManager.restoreFolderMappings.filter { $0.isSelected }
                let totalBytes: Int64 = activeMappings.reduce(Int64(0)) { sum, m in
                    var bytes = m.activeSize
                    if includeOrphans { bytes += m.orphanSize }
                    if includeArchives { bytes += m.archiveSize }
                    return sum + bytes
                }
                let freeSSD = backupManager.storageMetrics.macSSDFreeSpace
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Restore: \(totalBytes.formattedBytes) (\(activeMappings.count) folders)")
                        .font(.caption)
                        .bold()
                    HStack(spacing: 4) {
                        if !includeOrphans {
                            let totalOrphans = activeMappings.reduce(0) { $0 + $1.orphanCount }
                            if totalOrphans > 0 {
                                Text("\(totalOrphans) orphan(s) excluded")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if !includeArchives {
                            let totalArchives = activeMappings.reduce(0) { $0 + $1.archiveCount }
                            if totalArchives > 0 {
                                Text("\(totalArchives) archive(s) excluded")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Text("Mac SSD Free: \(freeSSD.formattedBytes)")
                        .font(.caption2)
                        .foregroundColor(totalBytes > freeSSD ? .red : .secondary)
                }
                
                Button(action: {
                    let check = backupManager.canRestore(bytesNeeded: totalBytes)
                    if !check.allowed && totalBytes > 0 {
                        spaceAlertMessage = "Restore requires approximately \(check.neededFormatted), but your Mac SSD only has \(check.freeFormatted) available."
                        showingInsufficientSpaceAlert = true
                    } else {
                        showingMappedRestoreConfirm = true
                    }
                }) {
                    Label(
                        activeMappings.isEmpty ? "Select Folders to Restore" : "Restore \(activeMappings.count) Selected Folder\(activeMappings.count == 1 ? "" : "s")",
                        systemImage: "arrow.down.doc.fill"
                    )
                    .bold()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(activeMappings.isEmpty || backupManager.isRestoring)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
    
    private func chooseCommonParentDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Common Destination Folder"
        panel.prompt = "Select"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            backupManager.setCommonRestoreDestination(url)
        }
    }
}

struct FolderMappingRowView: View {
    @Binding var mapping: FolderRestoreMapping
    var includeOrphans: Bool = false
    var includeArchives: Bool = false
    let home = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $mapping.isSelected)
                .labelsHidden()
            
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundColor(.blue)
            
            // Source Info
            VStack(alignment: .leading, spacing: 2) {
                Text(mapping.folderName)
                    .font(.headline)
                    .lineLimit(1)
                
                let displayBytes = (includeOrphans && includeArchives) ? mapping.totalSize : (
                    mapping.activeSize + (includeOrphans ? mapping.orphanSize : 0) + (includeArchives ? mapping.archiveSize : 0)
                )
                let displayCount = (includeOrphans && includeArchives) ? mapping.fileCount : (
                    mapping.activeFileCount + (includeOrphans ? mapping.orphanCount : 0) + (includeArchives ? mapping.archiveCount : 0)
                )
                
                HStack(spacing: 6) {
                    Text(displayBytes.formattedBytes)
                        .font(.caption)
                        .bold()
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(displayCount) active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !includeOrphans && mapping.orphanCount > 0 {
                    Text("\(mapping.orphanCount) orphan(s) excluded")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                if !includeArchives && mapping.archiveCount > 0 {
                    Text("\(mapping.archiveCount) archive(s) excluded")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                
                if let orig = mapping.originalPath, !orig.isEmpty {
                    Text("From: \(orig)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 170, alignment: .leading)
            
            Image(systemName: "arrow.right")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // Destination Info
            VStack(alignment: .leading, spacing: 2) {
                Text("RESTORE DESTINATION:")
                    .font(.system(size: 9))
                    .bold()
                    .foregroundColor(.secondary)
                
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatPath(mapping.destinationURL))
                        .font(.caption)
                        .bold()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer()
            
            Button("Change...") {
                chooseCustomDestination()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            Button(action: {
                resetDefaultDestination()
            }) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to ~/\(mapping.folderName)")
        }
        .padding(10)
        .background(mapping.isSelected ? Color.blue.opacity(0.06) : Color.secondary.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(mapping.isSelected ? Color.blue.opacity(0.25) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private func formatPath(_ url: URL) -> String {
        let homePath = home.path
        if url.path == homePath {
            return "~"
        } else if url.path.hasPrefix(homePath + "/") {
            return "~" + url.path.dropFirst(homePath.count)
        }
        return url.path
    }

    private func chooseCustomDestination() {
        let panel = NSOpenPanel()
        panel.title = "Select Destination for '\(mapping.folderName)'"
        panel.prompt = "Select"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = mapping.destinationURL
        if panel.runModal() == .OK, let url = panel.url {
            mapping.destinationURL = url
        }
    }

    private func resetDefaultDestination() {
        mapping.destinationURL = home.appendingPathComponent(mapping.folderName)
    }
}

struct SelectiveFileRestoreView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Binding var selectiveDestination: URL
    @Binding var conflictPolicy: ConflictPolicy
    @Binding var includeOrphans: Bool
    @Binding var includeArchives: Bool
    @Binding var selectedRestoreNodeID: String?
    @Binding var searchFilter: String
    @Binding var showingSelectiveRestoreConfirm: Bool
    @Binding var showingInsufficientSpaceAlert: Bool
    @Binding var spaceAlertMessage: String

    var filteredNodes: [FileSystemNode] {
        if searchFilter.trimmingCharacters(in: .whitespaces).isEmpty {
            return backupManager.targetNodes.filter { $0.name != ManifestManager.manifestDirectoryName }
        }
        return backupManager.targetNodes.filter { $0.name != ManifestManager.manifestDirectoryName }.compactMap { filterNode($0, query: searchFilter) }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Destination Box
            HStack {
                Text("Restore Checked Items To:")
                    .font(.caption)
                    .bold()
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                Text(selectiveDestination.path)
                    .font(.caption)
                    .bold()
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                Button("Change Destination...") {
                    let panel = NSOpenPanel()
                    panel.title = "Select Restore Destination"
                    panel.prompt = "Select"
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        selectiveDestination = url
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            
            // Search / filter bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search files and folders in backup...", text: $searchFilter)
                    .textFieldStyle(.plain)
                if !searchFilter.isEmpty {
                    Button(action: { searchFilter = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(6)
            .padding(.horizontal, 16)
            
            // Options Bar (Exclude / Include Orphans & Archives in folder restores)
            HStack(spacing: 16) {
                Toggle(isOn: $includeOrphans) {
                    HStack(spacing: 4) {
                        Image(systemName: includeOrphans ? "exclamationmark.triangle.fill" : "checkmark.shield")
                            .foregroundColor(includeOrphans ? .orange : .secondary)
                        Text("Include Orphaned Files in folder restores")
                            .font(.caption)
                    }
                }
                .toggleStyle(.checkbox)
                
                Toggle(isOn: $includeArchives) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.secondary)
                        Text("Include Version Archives")
                            .font(.caption)
                    }
                }
                .toggleStyle(.checkbox)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.04))
            .cornerRadius(6)
            .padding(.horizontal, 16)
            
            // Tree List
            List(filteredNodes, children: \.children, selection: $selectedRestoreNodeID) { node in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { backupManager.restoreCheckedNodes.contains(node.id) },
                        set: { isChecked in
                            if isChecked {
                                backupManager.restoreCheckedNodes.insert(node.id)
                            } else {
                                backupManager.restoreCheckedNodes.remove(node.id)
                            }
                        }
                    ))
                    .labelsHidden()
                    .buttonStyle(PlainButtonStyle())
                    
                    Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    
                    Text(node.name)
                        .foregroundColor(node.isOrphaned ? .orange : .primary)
                    
                    if node.isOrphaned {
                        Text("Orphan")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(3)
                    }
                    if node.isVersionedArchive {
                        Text("Archive")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundColor(.secondary)
                            .cornerRadius(3)
                    }
                    
                    Spacer(minLength: 20)
                    
                    if !node.isDirectory {
                        Text(node.size.formattedBytes)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 16)
            
            Divider()
            
            // Selective Restore Bottom Bar
            let checkedCount = backupManager.restoreCheckedNodes.count
            let checkedNodes = backupManager.restoreCheckedNodes.compactMap { backupManager.findNode(by: $0) }
            let checkedBytes = checkedNodes.reduce(0) { $0 + $1.size }
            let freeSSD = backupManager.storageMetrics.macSSDFreeSpace
            
            HStack(alignment: .center, spacing: 16) {
                Button("Clear Checked") {
                    backupManager.restoreCheckedNodes.removeAll()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(checkedCount == 0)
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(checkedCount) item\(checkedCount == 1 ? "" : "s") selected (\(checkedBytes.formattedBytes))")
                        .font(.caption)
                        .bold()
                    Text("Mac SSD Free: \(freeSSD.formattedBytes)")
                        .font(.caption2)
                        .foregroundColor(checkedBytes > freeSSD ? .red : .secondary)
                }
                
                Button(action: {
                    let check = backupManager.canRestore(bytesNeeded: checkedBytes)
                    if !check.allowed && checkedBytes > 0 {
                        spaceAlertMessage = "Restore requires approximately \(check.neededFormatted), but your Mac SSD only has \(check.freeFormatted) available."
                        showingInsufficientSpaceAlert = true
                    } else {
                        showingSelectiveRestoreConfirm = true
                    }
                }) {
                    Label(
                        checkedCount == 0 ? "Select Items to Restore" : "Restore \(checkedCount) Item\(checkedCount == 1 ? "" : "s")",
                        systemImage: "checkmark.circle.fill"
                    )
                    .bold()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(checkedCount == 0 || backupManager.isRestoring)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
    
    private func filterNode(_ node: FileSystemNode, query: String) -> FileSystemNode? {
        if node.name.localizedCaseInsensitiveContains(query) {
            return node
        }
        if let children = node.children {
            let matched = children.compactMap { filterNode($0, query: query) }
            if !matched.isEmpty {
                var copy = node
                copy.children = matched
                return copy
            }
        }
        return nil
    }
}

// MARK: - Orphan Cleanup View

struct OrphanCleanupView: View {
    @EnvironmentObject var backupManager: BackupManager
    @State private var showingBulkDeleteConfirmation = false
    @State private var orphanFilter: OrphanFilter = .orphans
    
    enum OrphanFilter: String, CaseIterable, Identifiable {
        case orphans = "Orphaned Files"
        case archives = "Versioned Archives"
        var id: String { rawValue }
    }

    var displayNodes: [FileSystemNode] {
        switch orphanFilter {
        case .orphans: return backupManager.allOrphans
        case .archives: return backupManager.allVersionedArchives
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Safety Lock Alert
            if backupManager.orphanSafetyLocked {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Safety Guard Active")
                            .font(.headline)
                        Text("Orphan deletion is paused because the drive is in Migration Mode or source folders are not yet verified on this Mac.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
            }
            
            // Reclaimable Space Stats Header
            if backupManager.storageMetrics.orphanedFilesSize > 0 || backupManager.storageMetrics.archivedVersionsSize > 0 {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reclaimable Orphan Space")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text("\(backupManager.storageMetrics.reclaimableSpaceFormatted) (\(backupManager.storageMetrics.orphanCount) files)")
                            .font(.headline)
                            .foregroundColor(.red)
                    }
                    
                    Divider().frame(height: 24)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version Archives")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text("\(backupManager.storageMetrics.archivedVersionsSize.formattedBytes) (\(backupManager.storageMetrics.versionCount) archives)")
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 10)
            }
            
            // Header Controls
            HStack {
                Picker("Filter:", selection: $orphanFilter) {
                    ForEach(OrphanFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                
                Spacer()
                
                Button(action: {
                    backupManager.recoverSelectedOrphans(to: nil)
                }) {
                    Label("Recover Checked to Mac", systemImage: "arrow.uturn.backward.circle")
                }
                .disabled(backupManager.checkedNodes.isEmpty)
                
                Button(role: .destructive, action: {
                    showingBulkDeleteConfirmation = true
                }) {
                    Label("Delete Checked", systemImage: "trash")
                }
                .disabled(backupManager.checkedNodes.isEmpty || backupManager.orphanSafetyLocked)
            }
            .padding()
            
            // Table / List
            if displayNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text(orphanFilter == .orphans ? "No orphaned files detected!" : "No past version archives found.")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(displayNodes) { node in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { backupManager.checkedNodes.contains(node.id) },
                            set: { isSelected in
                                if isSelected {
                                    backupManager.checkedNodes.insert(node.id)
                                } else {
                                    backupManager.checkedNodes.remove(node.id)
                                }
                            }
                        ))
                        .labelsHidden()
                        .buttonStyle(PlainButtonStyle())
                        
                        Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                                .font(.body)
                            Text(node.url.path)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        
                        Spacer()
                        
                        Text(node.size.formattedBytes)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button("Recover") {
                            backupManager.recoverOrphan(node: node, to: nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button(role: .destructive, action: {
                            backupManager.deleteNode(node)
                        }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(backupManager.orphanSafetyLocked ? .secondary : .red)
                        .disabled(backupManager.orphanSafetyLocked)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .confirmationDialog("Delete Checked Items?", isPresented: $showingBulkDeleteConfirmation) {
            Button("Delete Permanently", role: .destructive) {
                backupManager.deleteSelectedNodes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These items will be permanently deleted from the external drive. This action cannot be undone.")
        }
    }
}

// MARK: - File Preview View

struct FilePreviewView: View {
    @EnvironmentObject var backupManager: BackupManager
    let node: FileSystemNode
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        HStack(spacing: 20) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 70, height: 70)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.headline)
                
                Text(node.url.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                
                Text("Modified: \(node.modificationDate.formatted())")
                    .font(.caption)
                
                if node.isOrphaned {
                    Text("Deleted from Mac SSD (Orphaned)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                if !node.isDirectory {
                    Text("Size: \(node.size.formattedBytes)")
                        .font(.caption)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    if node.isOrphaned {
                        Button("Recover to Mac") {
                            backupManager.recoverOrphan(node: node, to: nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Button(role: .destructive, action: {
                        showingDeleteConfirmation = true
                    }) {
                        Label(node.isDirectory ? "Delete Folder" : "Delete File", systemImage: "trash")
                    }
                    .disabled(backupManager.orphanSafetyLocked && node.isOrphaned)
                    .confirmationDialog("Are you sure you want to delete this from the backup?", isPresented: $showingDeleteConfirmation) {
                        Button("Delete", role: .destructive) {
                            backupManager.deleteNode(node)
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Stat Item View

struct StatItemView: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.subheadline)
                .bold()
        }
    }
}

// MARK: - Global Status Footer View

struct GlobalStatusFooterView: View {
    @EnvironmentObject var backupManager: BackupManager
    
    var body: some View {
        HStack(spacing: 24) {
            if let lastDate = backupManager.lastBackupDate {
                StatItemView(title: "Last Backup", value: lastDate.formatted(date: .abbreviated, time: .shortened))
            } else {
                StatItemView(title: "Last Backup", value: "Never")
            }
            StatItemView(title: "New Files", value: "\(backupManager.newFilesAdded)")
            StatItemView(title: "Modified Files", value: "\(backupManager.modifiedFilesUpdated)")
            
            Spacer()
            
            Text("Total Items: \(countItems(in: backupManager.targetNodes))")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider().frame(height: 12)
            
            VStack(alignment: .trailing, spacing: 0) {
                Text("v2.5.0")
                Text("Made for my Love - DG").italic()
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
    }
    
    private func countItems(in nodes: [FileSystemNode]) -> Int {
        var count = nodes.count
        for node in nodes {
            if let children = node.children {
                count += countItems(in: children)
            }
        }
        return count
    }
}

// MARK: - Setup Assistant View

struct SetupAssistantView: View {
    @EnvironmentObject var backupManager: BackupManager
    let discovered: DiscoveredBackup
    @Binding var selectedTab: MainTab
    @Environment(\.dismiss) private var dismiss
    @State private var showingPairConfirm = false

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("External Backup Drive Detected")
                        .font(.title2)
                        .bold()
                    Text("Mac Backup found an existing backup repository on '\(discovered.volumeName)'.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Divider()
            
            // Backup Details card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Original Mac:")
                        .bold()
                        .frame(width: 130, alignment: .leading)
                    Text("\(discovered.manifest.lastBackupMachine.hostname) (\(discovered.manifest.lastBackupMachine.username))")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Last Backup:")
                        .bold()
                        .frame(width: 130, alignment: .leading)
                    Text(discovered.manifest.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Mapped Folders:")
                        .bold()
                        .frame(width: 130, alignment: .leading)
                    Text("\(discovered.manifest.sources.count) folders configured")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Repository Path:")
                        .bold()
                        .frame(width: 130, alignment: .leading)
                    Text(discovered.backupFolderURL.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .truncationMode(.middle)
                }
            }
            .font(.callout)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
            
            Text("Is this Mac the same machine that created this backup, or a new Mac?")
                .font(.headline)
                .padding(.top, 4)
            
            HStack(spacing: 16) {
                // Same Mac Option
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.blue)
                        Text("Same Mac")
                            .font(.headline)
                    }
                    Text("Reconnect to this drive and resume regular incremental backups from this machine.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Spacer()
                    
                    Button(action: {
                        backupManager.reconnectDiscoveredBackup(discovered)
                        dismiss()
                    }) {
                        Text("Reconnect & Resume")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(Color.blue.opacity(0.06))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.2), lineWidth: 1))
                
                // New Mac Option
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundColor(.orange)
                        Text("New Mac")
                            .font(.headline)
                    }
                    Text("Restore data from this backup onto this new machine, or pair this drive to become this Mac's primary backup.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Spacer()
                    
                    HStack {
                        Button(action: {
                            backupManager.prepareRestoreFromDiscoveredBackup(discovered)
                            selectedTab = .restore
                            dismiss()
                        }) {
                            Text("Restore Files")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        
                        Button(action: {
                            showingPairConfirm = true
                        }) {
                            Text("Pair & Adopt")
                        }
                        .buttonStyle(.bordered)
                        .confirmationDialog("Adopt and Pair Backup Drive?", isPresented: $showingPairConfirm) {
                            Button("Pair with this Mac") {
                                backupManager.adoptAndPairDiscoveredBackup(discovered)
                                dismiss()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will designate this Mac as the primary source for future backups on this drive.")
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(Color.orange.opacity(0.06))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.2), lineWidth: 1))
            }
            
            HStack {
                Spacer()
                Button("Decide Later") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}
