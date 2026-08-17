//
//  SL_Link_MainstageApp.swift
//  SL-Link-Mainstage
//
//  Created by Jeroen van Veldhuizen on 16/08/2026.
//

import SwiftUI

/// Calls `SLLinkController.shutdown()` explicitly on quit rather than
/// relying on `deinit` ordering against in-flight CoreMIDI callbacks - see
/// bug 7 in the project plan and the note on `SLLinkController`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: SLLinkController?

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

@main
struct SL_Link_MainstageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SLLinkController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .onAppear { appDelegate.controller = controller }
        }
    }
}
