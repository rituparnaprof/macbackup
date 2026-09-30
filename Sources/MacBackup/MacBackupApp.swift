//
//  MacBackupApp.swift
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
import AppKit

@main
struct MacBackupApp: App {
    @StateObject private var backupManager = BackupManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Settings {
            EmptyView()
        }

        MenuBarExtra {
            Button("Show Mac Backup UI") {
                showWindow()
            }
            
            if backupManager.isDriveConnected {
                Button("Start Backup Now") {
                    backupManager.performBackup()
                }
            }
            
            Divider()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "externaldrive")
                if backupManager.isDriveConnected {
                    Image(systemName: "circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red)
                }
            }
        }

        Window("Mac SSD Backup", id: "main") {
            ContentView()
                .environmentObject(backupManager)
        }
        .handlesExternalEvents(matching: ["show"])
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as an accessory app (Menu Bar only)
        NSApp.setActivationPolicy(.accessory)
        
        // Ensure no windows are open on launch
        for window in NSApp.windows {
            window.orderOut(nil)
        }
        
        // Listen for window visibility changes to toggle Dock icon
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            self.updateActivationPolicy()
        }
        
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            self.updateActivationPolicy()
        }
        
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // Delay slightly to allow the window list to update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.updateActivationPolicy()
            }
        }
        
        // Listen for drive mount to show window
        NotificationCenter.default.addObserver(forName: Notification.Name("RegisteredDriveMounted"), object: nil, queue: .main) { _ in
            if let url = URL(string: "macbackup://show") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    private func updateActivationPolicy() {
        let visibleWindows = NSApplication.shared.windows.filter { window in
            // Filter for 'real' app windows: visible, can become key, and has a title
            window.isVisible && window.canBecomeKey && !window.title.isEmpty
        }
        
        if visibleWindows.isEmpty {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }
}
