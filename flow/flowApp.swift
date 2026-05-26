//
//  flowApp.swift
//  flow
//

import SwiftUI

@main
struct flowApp: App {

    /// One library per app instance. Lives on `Application Support`
    /// and survives launches. If we can't open that directory we have
    /// no place to put boards — fatalError is acceptable here because
    /// the user can't do anything useful in that state.
    @StateObject private var library: BoardLibrary = {
        do {
            return try BoardLibrary()
        } catch {
            fatalError("Failed to open BoardLibrary: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            BoardListView()
                .environmentObject(library)
        }
    }
}
