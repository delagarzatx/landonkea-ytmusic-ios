// YTMusicWidgetBundle.swift, Entry point for the widget extension process.
//
// A WidgetKit extension is its own tiny app-like process (separate from
// YTMusicApp) launched by the system to render one or more widgets. This
// `@main` struct is where the OS starts, analogous to `YTMusicApp.swift`'s
// `@main App` for the main app, but for widget kinds instead of scenes.
//
// Currently there's a single widget kind (`NowPlayingWidget`). `WidgetBundle`
// is written as a list so adding a second widget later (e.g. a "Recently
// Played" widget) is just another line in `body`.

import WidgetKit
import SwiftUI

@main
struct YTMusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}
