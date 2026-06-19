# VisionPlay App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the generated/plain app icon with a custom VisionPlay A3-style asset: full VisionPlay wordmark, retro striped mark, and deep teal slate background.

**Architecture:** Add a real `Assets.xcassets` catalog under the app target, containing an `AppIcon.appiconset` and `AccentColor.colorset`. Generate a deterministic 1024×1024 PNG app icon from vector-like drawing code so the asset can be regenerated and reviewed. Wire the asset catalog into the existing Xcode project resources without touching unrelated app code.

**Tech Stack:** Python 3 + Pillow for PNG generation, Xcode asset catalogs, visionOS SwiftUI app target.

---

### Task 1: Generate and wire VisionPlay app icon assets

**Files:**
- Create: `VisionPlay/Assets.xcassets/Contents.json`
- Create: `VisionPlay/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `VisionPlay/Assets.xcassets/AppIcon.appiconset/VisionPlay-AppIcon-1024.png`
- Create: `VisionPlay/Assets.xcassets/AccentColor.colorset/Contents.json`
- Modify: `VisionPlay.xcodeproj/project.pbxproj`

- [ ] **Step 1: Confirm current asset catalog state**

Run:

```bash
find VisionPlay -maxdepth 3 -name '*.xcassets' -o -name 'AppIcon.appiconset'
rg -n "Assets.xcassets|AppIcon|AccentColor" VisionPlay.xcodeproj/project.pbxproj
```

Expected: no existing asset catalog path in the project file; `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` already exists.

- [ ] **Step 2: Create the asset catalog directories**

Run:

```bash
mkdir -p VisionPlay/Assets.xcassets/AppIcon.appiconset VisionPlay/Assets.xcassets/AccentColor.colorset
```

- [ ] **Step 3: Generate the A3 icon PNG**

Run a Python script that draws a 1024×1024 rounded-square deep teal slate background, glass inset, retro three-stripe mark, and `VisionPlay` wordmark. Use system fonts available on macOS if present, falling back to DejaVu/Sans.

- [ ] **Step 4: Write asset catalog JSON**

`AppIcon.appiconset/Contents.json` should reference `VisionPlay-AppIcon-1024.png` as a universal 1024×1024 marketing image. `AccentColor.colorset/Contents.json` should provide the amber Plex accent.

- [ ] **Step 5: Add the asset catalog to the Xcode project**

Add a `PBXFileReference` for `Assets.xcassets`, add it to the app group, and add a corresponding `PBXBuildFile` to the resources build phase. Keep existing app icon build settings unchanged.

- [ ] **Step 6: Verify asset file shape**

Run:

```bash
python3 - <<'PY'
from PIL import Image
img = Image.open('VisionPlay/Assets.xcassets/AppIcon.appiconset/VisionPlay-AppIcon-1024.png')
print(img.mode, img.size)
assert img.size == (1024, 1024)
PY
```

Expected: `RGBA (1024, 1024)`.

- [ ] **Step 7: Verify Xcode build accepts the catalog**

Run:

```bash
xcodebuild build -project VisionPlay.xcodeproj -scheme VisionPlay -destination 'generic/platform=visionOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: build succeeds or only unrelated existing warnings remain.
