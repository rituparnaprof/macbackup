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

struct RestoreDetailView: View {
    @EnvironmentObject var backupManager: BackupManager
    @State private var restoreDestination: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var conflictPolicy: ConflictPolicy = .keepBoth
    @State private var showingFullRestoreConfirm = false
    @State private var showingSelectiveRestoreConfirm = false
    @State private var showingInsufficientSpaceAlert = false
    @State private var spaceAlertMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Data Recovery & Restore")
                .font(.title2)
                .bold()
                .padding(.horizontal)
                .padding(.top)
            
            // Configuration Box
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Restore Destination")
                        .font(.headline)
                    Spacer()
                    if backupManager.storageMetrics.macSSDFreeSpace > 0 {
                        Text("Mac SSD Free: \(backupManager.storageMetrics.macSSDFreeSpace.formattedBytes)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack {
                    Image(systemName: "folder")
                    Text(restoreDestination.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change Destination...") {
                        chooseCustomDestination()
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                
                Picker("Conflict Policy:", selection: $conflictPolicy) {
                    ForEach(ConflictPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .padding(.horizontal)
            
            // Actions
            HStack(spacing: 16) {
                Button(action: {
                    let needed = backupManager.storageMetrics.activeBackupSize
                    let check = backupManager.canRestore(bytesNeeded: needed)
                    if !check.allowed && needed > 0 {
                        spaceAlertMessage = "Restore requires approximately \(check.neededFormatted), but your Mac SSD only has \(check.freeFormatted) available (with 1 GB safety buffer)."
                        showingInsufficientSpaceAlert = true
                    } else {
                        showingFullRestoreConfirm = true
                    }
                }) {
                    Label("Restore All to This Mac", systemImage: "arrow.down.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(backupManager.targetNodes.isEmpty || backupManager.isRestoring)
                
                Button(action: {
                    let nodes = backupManager.checkedNodes.compactMap { backupManager.findNode(by: $0) }
                    let needed = nodes.reduce(0) { $0 + $1.size }
                    let check = backupManager.canRestore(bytesNeeded: needed)
                    if !check.allowed && needed > 0 {
                        spaceAlertMessage = "Restore requires approximately \(check.neededFormatted), but your Mac SSD only has \(check.freeFormatted) available (with 1 GB safety buffer)."
                        showingInsufficientSpaceAlert = true
                    } else {
                        showingSelectiveRestoreConfirm = true
                    }
                }) {
                    Label("Restore Checked (\(backupManager.checkedNodes.count))", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(backupManager.checkedNodes.isEmpty || backupManager.isRestoring)
            }
            .padding(.horizontal)
            
            // Status and Progress
            if backupManager.isRestoring {
                VStack(alignment: .leading, spacing: 8) {
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
                    ProgressView(value: backupManager.restoreProgress)
                    if !backupManager.currentFileName.isEmpty {
                        Text(backupManager.currentFileName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding()
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal)
            } else if !backupManager.restoreStatus.isEmpty {
                Text(backupManager.restoreStatus)
                    .font(.caption)
                    .foregroundColor(backupManager.restoreStatus.contains("Failed") ? .red : .green)
                    .padding(.horizontal)
            }
            
            Divider()
            
            // Instructions
            VStack(alignment: .leading, spacing: 6) {
                Text("How Restore Works:")
                    .font(.subheadline)
                    .bold()
                Text("• Files are verified with SHA-256 cryptographic checksums before write.")
                    .font(.caption).foregroundColor(.secondary)
                Text("• Sleep is disabled during restoration to prevent partial writes.")
                    .font(.caption).foregroundColor(.secondary)
                Text("• 'Keep Both' saves collisions with a '(Restored)' tag to prevent overwriting existing work.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .alert("Insufficient Disk Space", isPresented: $showingInsufficientSpaceAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(spaceAlertMessage)
        }
        .confirmationDialog("Start Full Restore?", isPresented: $showingFullRestoreConfirm) {
            Button("Restore All Files") {
                backupManager.performFullRestore(to: restoreDestination, conflictPolicy: conflictPolicy)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All folders and files from '\(backupManager.targetFolder?.lastPathComponent ?? "Backup")' will be safely copied and verified to '\(restoreDestination.path)'.")
        }
        .confirmationDialog("Restore Checked Files?", isPresented: $showingSelectiveRestoreConfirm) {
            Button("Restore \(backupManager.checkedNodes.count) Items") {
                let nodes = backupManager.checkedNodes.compactMap { backupManager.findNode(by: $0) }
                backupManager.performSelectiveRestore(nodes: nodes, destinationURL: restoreDestination, conflictPolicy: conflictPolicy)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Selected items will be copied and verified to '\(restoreDestination.path)'.")
        }
    }
    
    private func chooseCustomDestination() {
        let panel = NSOpenPanel()
        panel.title = "Select Restore Destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            restoreDestination = url
        }
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
                Text("v2.2.1")
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
