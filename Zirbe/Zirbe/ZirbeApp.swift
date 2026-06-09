// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The app entry point. Everything below RootView reads from ZirbeCore's store;
// the network only ever fills that store.

import SwiftUI

@main
struct ZirbeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
