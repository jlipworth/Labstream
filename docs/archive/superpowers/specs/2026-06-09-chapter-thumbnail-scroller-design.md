# Chapter thumbnail scroller — design

**Date:** 2026-06-09
**Issues:** #10 (Chapters UI: Plex-style horizontal thumbnail scroller), task #27
**Status:** Implemented. One change from this design: the thumbnail is loaded by
vending a `/photo/:/transcode` URL from `PlaybackController.chapterThumbnailURL(for:)`
into an `AsyncImage`, NOT via `PosterImage`. `PosterImage` reads `AppModel` from the
SwiftUI environment, which the bare `UIHostingController` hosting the info tab does not
inject, so it would have silently rendered placeholders. Everything else shipped as
designed.

## Goal

Replace the plain `ChaptersTabView` list with a Plex-style horizontal thumbnail
rail, rendered inside the existing native ⓘ **Chapters** info tab. The change is
**fully additive**: `showsPlaybackControls` stays `true` and the native AVKit
chrome (Quality / Subtitles / Speed / Stats info tabs) is untouched. We are
upgrading the contents of an info tab that already exists — not introducing a
new overlay layer.

### Why not a floating overlay / native trick-play

- A floating custom strip would compete with native chrome's show/hide and
  gesture handling — higher risk on visionOS, and unnecessary since chapters
  already have a native tab.
- Native scrub trick-play thumbnails are not achievable additively (see #4):
  AVKit's native scrubber only derives previews from an HLS I-frame playlist,
  which a live Plex transcode can't supply across the full timeline, and Plex's
  BIF sprites (JPEGs) can't be fed to the native scrubber. Drawing our own
  scrubber would mean `showsPlaybackControls = false`, amputating the native
  info tabs (rejected "approach B" — see `docs/DEVELOPMENT.md`).
- Chapter-level thumbnails come from `Chapter.thumb`, which Plex pre-generates,
  so the rail needs no scrubber and no trick-play stream.

## Components & boundaries

### `ChaptersTabView` (rewrite — same file & name)
`VisionPlay/Player/PlayerControlSurface.swift`

Public surface changes from:

```swift
ChaptersTabView(chapters: [Chapter], onJump: (Int) -> Void)
```

to:

```swift
ChaptersTabView(chapters: [Chapter], currentMs: () -> Int, onJump: (Int) -> Void)
```

Body becomes a horizontal `ScrollView(.horizontal)` wrapped in a
`ScrollViewReader`, laying out one `ChapterCard` per chapter. Keeps a graceful
"No chapters" text for the empty case (though the tab is normally not added when
there are zero chapters — see call site).

### `ChapterCard` (new private view)

One chapter:
- A 16:9 `PosterImage(path: chapter.thumb, width: ~200, height: ~112)` — reuses
  the existing loader, which already builds the `/photo/:/transcode` URL, fades
  in via a shimmer skeleton, and renders the film-glyph placeholder when
  `thumb == nil`. **No new networking code.**
- Title below: `chapter.tag ?? "Chapter \(index + 1)"`, `.lineLimit(1)`,
  truncating.
- Timecode below the title: secondary color, `.monospacedDigit()`, formatted by
  the existing `timecode(_:)` helper.
- Wrapped in a `Button` that calls `onJump(startMs)`.
- When it is the current chapter: accent-colored stroke ring + full-opacity
  title; non-current cards are slightly dimmed.
- Disabled when `chapter.startTimeOffset == nil` (matches today's behavior).

## Data flow

1. Call site (`PlayerControlSurface.swift`, where the Chapters tab is built)
   passes:
   - `currentMs: { [weak self] in self?.controller.currentResumeMs ?? 0 }`
   - the existing seek closure as `onJump`.
2. On `.onAppear`, `ChaptersTabView` reads `currentMs()` **once**, computes the
   current chapter index, stores it in `@State`, and calls
   `ScrollViewReader.scrollTo(currentIndex, anchor: .center)` to bring it into
   view. The panel is transient, so a one-shot read at open time is sufficient —
   we do not make the playhead continuously observable.
3. Tap → `onJump(startMs)` performs the seek (unchanged). The panel stays open,
   matching current native info-tab behavior.

## Current-chapter selection (the only pure logic)

Extract a small pure function:

```swift
/// Index of the chapter whose [startTimeOffset, nextStart) range contains `ms`,
/// or nil if `ms` precedes the first chapter / there are no chapters.
func indexOfChapter(at ms: Int, in chapters: [Chapter]) -> Int?
```

Selection rule: the current chapter is the last chapter whose `startTimeOffset
<= ms`. (Using next chapter's start as the upper bound; `endTimeOffset` is not
required and is often unreliable.)

## Layout specifics

- Thumbnail ~200×112 pt (16:9).
- Title: one line, truncating.
- Timecode: secondary, monospaced digits.
- Current card highlighted with an accent stroke ring; others slightly dimmed.
- Horizontal scroll within the info-tab panel.

## Error / edge handling

- `thumb == nil` → `PosterImage` placeholder (already built).
- `startTimeOffset == nil` → card disabled.
- 0 chapters → tab not added (existing call-site guard stays); defensive
  "No chapters" text remains in the view for safety.
- Playhead before first chapter → no current highlight, scroll rests at start.

## Testing

- Unit-test `indexOfChapter(at:in:)` against:
  - playhead before the first chapter → `nil`
  - exactly on a chapter boundary → that chapter
  - mid-chapter → that chapter
  - past the last chapter's start → last chapter
  - single-chapter list
  - empty list → `nil`
- The rest is view-layer SwiftUI/UIKit glue verified manually in the player
  (thumbnails load, current chapter highlighted + auto-scrolled, tap seeks).

## Out of scope

- Trick-play / scrub thumbnails (#4 — shelved, see issue note).
- Any change to native chrome or other info tabs.
- Continuously-live current-chapter highlight while the panel is open.
