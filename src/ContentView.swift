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

struct ContentView: View {
    @EnvironmentObject var backupManager: BackupManager
    @State private var selectedNodeID: String?
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            MainDetailView(selectedNodeID: $selectedNodeID)
        }
        .navigationTitle("Mac SSD Backup")
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

struct SidebarView: View {
    @EnvironmentObject var backupManager: BackupManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Backup Settings")
                .font(.headline)
            
            VStack(alignment: .leading) {
                Text("Source Folders (Mac SSD)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("Select Source Folders") {
                    backupManager.selectSourceFolders()
                }
                
                if backupManager.sourceFolders.isEmpty {
                    Text("No folders selected")
                        .font(.caption)
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
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(statusColor.opacity(0.15))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            
            VStack(alignment: .leading) {
                Text("Target (USB Drive)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("Select & Register Target Folder") {
                    backupManager.selectTargetFolder()
                }
                
                HStack {
                    Circle()
                        .fill(backupManager.isDriveConnected ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(backupManager.isDriveConnected ? "Drive Connected" : "Drive Disconnected")
                        .font(.caption)
                        .foregroundColor(backupManager.isDriveConnected ? .green : .red)
                }
                
                if let target = backupManager.targetFolder, backupManager.isDriveConnected {
                    HStack {
                        Text(target.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
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
            
            Divider()
            
            Button(action: {
                backupManager.performBackup()
            }) {
                Text(backupManager.isBackingUp ? "Backing up..." : "Start Backup")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(backupManager.sourceFolders.isEmpty || backupManager.targetFolder == nil || backupManager.isBackingUp)
            
            if !backupManager.backupStatus.isEmpty {
                Text(backupManager.backupStatus)
                    .font(.caption)
                    .foregroundColor(backupManager.backupStatus.contains("Error") ? .red : .green)
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 200, maxWidth: 300)
    }
    
    private var statusColor: Color {
        if backupManager.pendingBackupPercentage > 0.5 {
            return .red
        } else if backupManager.pendingBackupPercentage > 0.2 {
            return .orange
        } else {
            return .green
        }
    }
}

struct MainDetailView: View {
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
                        .confirmationDialog("Delete Multiple Items", isPresented: $showingBulkDeleteConfirmation) {
                            Button("Delete \(backupManager.checkedNodes.count) Items", role: .destructive) {
                                backupManager.deleteSelectedNodes()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will permanently delete the selected items from the backup drive. This action cannot be undone.")
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
                }
                
                VSplitView {
                    // Hierarchical Tree View using List
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
                            .buttonStyle(PlainButtonStyle()) // Prevents the toggle from capturing the whole row tap
                            
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
                            
                            Spacer(minLength: 20)
                            if !node.isDirectory {
                                Text(formatBytes(node.size))
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
            
            Divider()
            
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
                
                Divider()
                    .frame(height: 12)
                
                VStack(alignment: .trailing, spacing: 0) {
                    Text("v1.0")
                    Text("Made for my Love - DG")
                        .italic()
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(statusColor.opacity(0.1))
        }
    }
    
    private var statusColor: Color {
        if backupManager.pendingBackupPercentage > 0.5 {
            return .red
        } else if backupManager.pendingBackupPercentage > 0.2 {
            return .orange
        } else {
            return .green
        }
    }
    
    func countItems(in nodes: [FileSystemNode]) -> Int {
        var count = nodes.count
        for node in nodes {
            if let children = node.children {
                count += countItems(in: children)
            }
        }
        return count
    }
    
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct FilePreviewView: View {
    @EnvironmentObject var backupManager: BackupManager
    let node: FileSystemNode
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        HStack(spacing: 20) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            
            VStack(alignment: .leading, spacing: 5) {
                Text(node.name)
                    .font(.title2)
                    .bold()
                
                Text(node.url.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                
                Text("Modified: \(node.modificationDate.formatted())")
                    .font(.subheadline)
                
                if node.isOrphaned {
                    Text("This item has been deleted from your Mac SSD.")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                if !node.isDirectory {
                    let formatter = ByteCountFormatter()
                    Text("Size: \(formatter.string(fromByteCount: node.size))")
                        .font(.subheadline)
                } else {
                    Text("Folder")
                        .font(.subheadline)
                }
                
                Spacer()
                
                Button(role: .destructive, action: {
                    showingDeleteConfirmation = true
                }) {
                    Label(node.isDirectory ? "Delete Folder" : "Delete File", systemImage: "trash")
                }
                .confirmationDialog("Are you sure you want to delete this from the backup?", isPresented: $showingDeleteConfirmation) {
                    Button("Delete", role: .destructive) {
                        backupManager.deleteNode(node)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

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
