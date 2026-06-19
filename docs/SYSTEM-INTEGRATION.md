# System integration

## Single-window routing

System entries route through `SystemEntryRouter` into the existing app window. They should not create a second playback/window stack.

`ContentView` registers `AppModel` and `AuthManager` before restore completes so cold-launch intents and Spotlight opens can queue safely until browsing is ready.

## App Intents

VisionPlay exposes intents for:

- Play Media
- Open Media
- Continue Watching

Intents resolve through current backend browse context and push the normal detail/player paths. Signed-out or not-ready states should return a clear failure instead of partially opening UI.

## Spotlight

Spotlight indexing is best effort:

- index video items as they are browsed
- namespace identifiers by server/backend context where possible
- avoid thumbnails and sensitive server/title-adjacent metadata beyond what the system result requires
- delete the app’s index on sign-out and from the Settings maintenance action

Spotlight hits open the app and navigate to the detail page. They do not autoplay unless explicitly routed through a play intent.

## Deep links and user activities

Deep links/user activities should use the same router and Home-stack detail navigation as App Intents/Spotlight. Keep the routing centralized so restore, sign-out, and backend switching behavior stays consistent.
