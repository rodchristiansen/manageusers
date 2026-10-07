//
//  ManagedUsersCleanupApp.swift
//  Managed Users Cleanup
//
//  SwiftUI window for manageusers: its preferences, a simulated or live run with live
//  output, and the log of every run.
//

import SwiftUI

@main
struct ManagedUsersCleanupApp: App {
    @State private var xpcClient = XPCClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(xpcClient)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 850, height: 748)
    }
}
