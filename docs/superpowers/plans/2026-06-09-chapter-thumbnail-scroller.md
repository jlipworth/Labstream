# Chapter Thumbnail Scroller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain `ChaptersTabView` list with a Plex-style horizontal thumbnail rail inside the existing native ⓘ Chapters info tab, highlighting and auto-scrolling to the current chapter.

**Architecture:** Fully additive — native AVKit chrome (`showsPlaybackControls = true`) is untouched; only the contents of the already-registered Chapters info tab change. The one piece of pure logic (current-chapter selection) lives in PlexKit so it is unit-testable; the rail and card are SwiftUI views in the app. Thumbnails reuse the existing `PosterImage` loader (Plex `/photo/:/transcode`), so there is no new networking.

**Tech Stack:** Swift 6, SwiftUI, AVKit (visionOS 26), PlexKit (local SPM package), swift-testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-06-09-chapter-thumbnail-scroller-design.md`

---

### Task 1: Current-chapter selection (pure logic in PlexKit)

**Files:**
- Modify: `PlexKit/Sources/PlexKit/Models/Library.swift` (add an extension after the `Chapter` struct, which ends at line 272)
- Test: `PlexKit/Tests/PlexKitTests/ChapterSelectionTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `PlexKit/Tests/PlexKitTests/ChapterSelectionTests.swift`:

```swift
import Testing
@testable import PlexKit

// Three chapters starting at 0ms, 12_000ms, 28_000ms.
private let chapters: [Chapter] = [
    Chapter(id: 1, tag: "Cold Open", startTimeOffset: 0,      endTimeOffset: 12_000),
    Chapter(id: 2, tag: "The Heist",  startTimeOffset: 12_000, endTimeOffset: 28_000),
    Chapter(id: 3, tag: "Aftermath",  startTimeOffset: 28_000, endTimeOffset: 41_000),
]

@Test func midChapterReturnsThatChapter() {
    #expect(chapters.indexOfChapter(at: 15_000) == 1)
}

@Test func exactBoundaryReturnsThatChapter() {
    #expect(chapters.indexOfChapter(at: 12_000) == 1)
}

@Test func firstChapterStartReturnsZero() {
    #expect(chapters.indexOfChapter(at: 0) == 0)
}

@Test func pastLastStartReturnsLast() {
    #expect(chapters.indexOfChapter(at: 999_999) == 2)
}

@Test func beforeFirstChapterReturnsNil() {
    let later = [Chapter(id: 1, tag: "Late", startTimeOffset: 5_000, endTimeOffset: 9_000)]
    #expect(later.indexOfChapter(at: 1_000) == nil)
}

@Test func emptyListReturnsNil() {
    #expect([Chapter]().indexOfChapter(at: 0) == nil)
}

@Test func skipsChaptersWithNilStart() {
    let mixed = [
        Chapter(id: 1, tag: "A", startTimeOffset: nil),
        Chapter(id: 2, tag: "B", startTimeOffset: 10_000),
    ]
    #expect(mixed.indexOfChapter(at: 12_000) == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path PlexKit --filter ChapterSelectionTests`
Expected: FAIL to compile — `value of type '[Chapter]' has no member 'indexOfChapter'`.

- [ ] **Step 3: Write minimal implementation**

In `PlexKit/Sources/PlexKit/Models/Library.swift`, immediately after the closing brace of the `Chapter` struct (line 272), add:

```swift
public extension Array where Element == Chapter {
    /// Index of the chapter the playhead `ms` (milliseconds) currently sits in:
    /// the last chapter whose `startTimeOffset <= ms`. Chapters are strictly
    /// ordered by start, so we stop at the first start that exceeds `ms`.
    /// Returns `nil` when there are no chapters or `ms` precedes the first
    /// chapter's start. Chapters with a `nil` start are skipped.
    /// `endTimeOffset` is intentionally not used — PMS data for it is unreliable.
    func indexOfChapter(at ms: Int) -> Int? {
        var match: Int?
        for (index, chapter) in enumerated() {
            guard let start = chapter.startTimeOffset else { continue }
            if start <= ms { match = index } else { break }
        }
        return match
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path PlexKit --filter ChapterSelectionTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add PlexKit/Sources/PlexKit/Models/Library.swift PlexKit/Tests/PlexKitTests/ChapterSelectionTests.swift
git commit -m "feat(player): add current-chapter selection helper for chapter scroller"
```

---

### Task 2: `ChapterCard` view (single chapter in the rail)

**Files:**
- Modify: `PlexAVPApp/Player/PlayerControlSurface.swift` (add a new private view; the existing `ChaptersTabView` is at lines 331-366 and `timecode(_:)` lives inside it at 360-365)

- [ ] **Step 1: Add the `ChapterCard` view**

In `PlexAVPApp/Player/PlayerControlSurface.swift`, add this private view directly above the existing `ChaptersTabView` (line 331). It owns one chapter's thumbnail + title + timecode and the tap-to-seek button. It reuses `PosterImage` (defined in `PlexAVPApp/UI/PosterImage.swift`), which builds the `/photo/:/transcode` URL, shows a shimmer skeleton, and falls back to a film glyph when `thumb` is nil.

```swift
/// One chapter in the horizontal scroller: a 16:9 thumbnail with the chapter
/// title and start timecode stacked below. The current chapter is ringed in the
/// accent color; non-current cards are slightly dimmed. Tapping seeks the
/// playhead to the chapter start. Disabled when the chapter has no start offset.
private struct ChapterCard: View {
    let chapter: Chapter
    let index: Int
    let isCurrent: Bool
    var onTap: (Int) -> Void

    private static let thumbWidth: CGFloat = 200
    private static let thumbHeight: CGFloat = 112  // 16:9

    var body: some View {
        Button {
            if let startMs = chapter.startTimeOffset { onTap(startMs) }
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                PosterImage(path: chapter.thumb,
                            width: Self.thumbWidth,
                            height: Self.thumbHeight,
                            cornerRadius: DS.Radius.poster)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: isCurrent ? 3 : 0)
                    )

                Text(chapter.tag ?? "Chapter \(index + 1)")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let startMs = chapter.startTimeOffset {
                    Text(Self.timecode(startMs))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.thumbWidth, alignment: .leading)
            .opacity(isCurrent ? 1.0 : 0.7)
        }
        .buttonStyle(.plain)
        .disabled(chapter.startTimeOffset == nil)
    }

    /// Milliseconds → `m:ss` (or `h:mm:ss`). Mirrors the helper in `ChaptersTabView`.
    static func timecode(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
```

> Note: `DS.Space.xs` (4) and `DS.Radius.poster` (16) are defined in `PlexAVPApp/UI/DesignSystem.swift` — confirmed present.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -destination 'platform=visionOS Simulator,name=Apple Vision Pro'`
Expected: BUILD SUCCEEDED. (`ChapterCard` is unused so far — a Swift warning about it is acceptable at this step.)

- [ ] **Step 3: Commit**

```bash
git add PlexAVPApp/Player/PlayerControlSurface.swift
git commit -m "feat(player): add ChapterCard view for chapter thumbnail rail"
```

---

### Task 3: Rewrite `ChaptersTabView` as a horizontal rail + wire the call site

**Files:**
- Modify: `PlexAVPApp/Player/PlayerControlSurface.swift` — replace `ChaptersTabView` body (lines 331-366) and update its call site (lines 80-88)

- [ ] **Step 1: Replace `ChaptersTabView`**

Replace the entire existing `ChaptersTabView` struct (lines 331-366) with:

```swift
/// Chapters info-panel tab: a Plex-style horizontal thumbnail rail. Tapping a
/// card seeks the playhead to that chapter's start. On appear we read the live
/// playhead once (`currentMs`), highlight the chapter it sits in, and auto-scroll
/// that card to center. The panel is transient, so a one-shot read is enough — we
/// deliberately do not observe the playhead continuously.
private struct ChaptersTabView: View {
    let chapters: [Chapter]
    /// Reads the live playhead in milliseconds at appear time.
    var currentMs: () -> Int
    var onJump: (Int) -> Void

    @State private var currentIndex: Int?

    var body: some View {
        Group {
            if chapters.isEmpty {
                Text("No chapters")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: DS.Space.md) {
                            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                                ChapterCard(chapter: chapter,
                                            index: index,
                                            isCurrent: index == currentIndex,
                                            onTap: onJump)
                                    .id(index)
                            }
                        }
                        .padding(DS.Space.md)
                    }
                    .onAppear {
                        currentIndex = chapters.indexOfChapter(at: currentMs())
                        if let target = currentIndex {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}
```

> Note: `id: \.element.id` uses `Chapter`'s synthesized stable identity (keyed on `startTimeOffset`) to avoid the duplicate-row bug fixed in #26, while `.id(index)` gives `ScrollViewReader` an integer anchor matching `indexOfChapter`'s return. `DS.Space.md` is already used in this file; verify in the `DS` file if unsure.

- [ ] **Step 2: Update the call site to pass `currentMs`**

In `PlexAVPApp/Player/PlayerControlSurface.swift`, replace the Chapters tab block (lines 80-88):

```swift
        if !controller.chapters.isEmpty {
            let chapters = ChaptersTabView(chapters: controller.chapters) { [weak self] startMs in
                let target = CMTime(value: CMTimeValue(startMs), timescale: 1000)
                self?.controller.player.seek(to: target,
                                             toleranceBefore: .zero,
                                             toleranceAfter: .zero)
            }
            tabs.append(makeTab(chapters, title: "Chapters", systemImage: "list.bullet"))
        }
```

with:

```swift
        if !controller.chapters.isEmpty {
            let chapters = ChaptersTabView(
                chapters: controller.chapters,
                currentMs: { [weak self] in self?.controller.currentResumeMs ?? 0 },
                onJump: { [weak self] startMs in
                    let target = CMTime(value: CMTimeValue(startMs), timescale: 1000)
                    self?.controller.player.seek(to: target,
                                                 toleranceBefore: .zero,
                                                 toleranceAfter: .zero)
                })
            tabs.append(makeTab(chapters, title: "Chapters", systemImage: "list.bullet"))
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -destination 'platform=visionOS Simulator,name=Apple Vision Pro'`
Expected: BUILD SUCCEEDED, with no remaining "unused `ChapterCard`" warning.

- [ ] **Step 4: Run the full PlexKit test suite (no regressions)**

Run: `swift test --package-path PlexKit`
Expected: PASS (all existing tests + the 7 new ChapterSelection tests).

- [ ] **Step 5: Commit**

```bash
git add PlexAVPApp/Player/PlayerControlSurface.swift
git commit -m "feat(player): replace chapter list with horizontal thumbnail rail (#10)"
```

---

### Task 4: Manual verification in the player

**Files:** none (manual smoke test on device/simulator)

- [ ] **Step 1: Verify behavior**

Build/run, play an item that has chapters, open the ⓘ menu → Chapters tab, and confirm:
- Thumbnails load (and chapters without art show the film-glyph placeholder, not a broken image).
- The chapter the playhead is currently in is ringed and centered when the panel opens.
- Tapping a card seeks playback to that chapter's start.
- An item with no chapters never shows the tab (the call-site guard), and the native chrome / other info tabs (Quality, Subtitles, Speed, Stats) are unchanged.

- [ ] **Step 2: Update task tracker**

Mark task #27 / issue #10 done once verified.

---

## Self-Review

**Spec coverage:**
- Surfacing in existing Chapters tab → Task 3 (rewrite in place, call site unchanged location). ✓
- `ChaptersTabView` signature change `(chapters, currentMs, onJump)` → Task 3 Step 1-2. ✓
- `ChapterCard` reusing `PosterImage` + title + timecode + ring + dim + disabled → Task 2. ✓
- One-shot `currentMs()` read on appear, current index, `scrollTo(.center)` → Task 3 Step 1. ✓
- Pure `indexOfChapter` + the six+ test cases from the spec → Task 1. ✓
- Empty/`thumb==nil`/`startTimeOffset==nil`/before-first edge handling → Tasks 1-3 (placeholder, disabled, "No chapters", nil index). ✓
- Native chrome untouched / other tabs unchanged → Task 4 verification. ✓

**Placeholder scan:** No TBD/TODO; all code shown in full. The two `DS` token caveats are explicit fallback instructions, not placeholders.

**Type consistency:** `indexOfChapter(at:)` defined in Task 1 is the exact name called in Task 3. `ChapterCard(chapter:index:isCurrent:onTap:)` defined in Task 2 matches the call in Task 3. `currentMs: () -> Int` / `onJump: (Int) -> Void` consistent between view definition (Task 3 Step 1) and call site (Task 3 Step 2). `PosterImage(path:width:height:cornerRadius:)` matches its definition in `PosterImage.swift`.
