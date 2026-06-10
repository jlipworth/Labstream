# Signing and Repo Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make VisionPlex dev-ready for personal Vision Pro installs, repo hygiene, and local Woodpecker CI while preserving the current app implementation.

**Architecture:** Keep the existing Xcode target/scheme/source layout stable, but change the externally visible identity to VisionPlex through bundle/display settings and docs. Use committed shared config plus ignored local signing config for device signing. Add small Woodpecker pipelines that validate portable repo/package checks without pretending to build visionOS on non-macOS CI.

**Tech Stack:** Xcode 26.5, visionOS 26.5/XROS SDK, Swift 6, Swift Package Manager, Woodpecker CI YAML, GitHub remote, zsh.

---

## File map

- Modify: `PlexAVPApp.xcodeproj/project.pbxproj`
  - Set `PRODUCT_BUNDLE_IDENTIFIER = com.jlipworth.VisionPlex` for Debug and Release.
  - Set `INFOPLIST_KEY_CFBundleDisplayName = VisionPlex` for Debug and Release.
  - Keep target/scheme/internal product structure otherwise stable.
- Modify: `README.md`
  - Replace stale bundle ID references.
  - Document personal-device signing setup and Apple trust/developer-mode friction.
  - Add Woodpecker CI coverage note.
  - Mention future TestFlight/App Store path without making it current scope.
- Modify: `docs/DEVELOPMENT.md`
  - Update build/install/log commands for `com.jlipworth.VisionPlex`.
  - Add concise signing runbook for `Signing.local.xcconfig`.
  - Add Woodpecker/local validation commands.
- Modify: `CLAUDE.md`
  - Update agent build/install commands and bundle ID.
  - Preserve existing unrelated user edits by patching only relevant command/bundle lines.
- Create: `.woodpecker/plexkit.yml`
  - Run `swift test` in `PlexKit` on push, pull request, and manual events.
- Create: `.woodpecker/hygiene.yml`
  - Run repository checks through `scripts/ci-hygiene.sh`.
- Create: `scripts/ci-hygiene.sh`
  - Put the hygiene logic in a local script so CI and local developers run the same checks.
- Modify: `.gitignore`
  - Confirm local signing and Xcode generated files remain ignored; add missing generated signing/profile patterns only if needed.
- Local-only, not committed: rename checkout folder from `/path/to/user/plex-avp-app` to `/path/to/user/visionplex` after implementation is committed/pushed or at a deliberate handoff point.

## Existing dirty tree rule

Before each commit, run:

```bash
git status --short
```

Only stage readiness files from this plan. Existing modified files currently include `.claude/skills/sim-driving/SKILL.md`, `CLAUDE.md`, `PlexAVPApp/Player/PlaybackController.swift`, and `PlexAVPApp/Player/PlayerControlSurface.swift`. `CLAUDE.md` is in scope for this plan; preserve unrelated edits inside it by using targeted patches and reviewing `git diff -- CLAUDE.md` before staging.

---

### Task 1: Update Xcode external identity to VisionPlex

**Files:**
- Modify: `PlexAVPApp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Inspect current bundle/display settings**

Run:

```bash
rg -n "PRODUCT_BUNDLE_IDENTIFIER|INFOPLIST_KEY_CFBundleDisplayName|PRODUCT_NAME|CODE_SIGN_STYLE|DEVELOPMENT_TEAM" PlexAVPApp.xcodeproj/project.pbxproj
```

Expected: two `PRODUCT_BUNDLE_IDENTIFIER = com.personal.PlexAVPApp;` entries and no existing `INFOPLIST_KEY_CFBundleDisplayName` entries.

- [ ] **Step 2: Patch only bundle ID and display name**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
p = Path('PlexAVPApp.xcodeproj/project.pbxproj')
text = p.read_text()
old = 'PRODUCT_BUNDLE_IDENTIFIER = com.personal.PlexAVPApp;'
new = 'PRODUCT_BUNDLE_IDENTIFIER = com.jlipworth.VisionPlex;'
count = text.count(old)
if count != 2:
    raise SystemExit(f'expected 2 bundle id entries, found {count}')
text = text.replace(old, new)
anchor = 'INFOPLIST_KEY_UILaunchScreen_Generation = YES;\n'
insert = 'INFOPLIST_KEY_CFBundleDisplayName = VisionPlex;\n\t\t\t\t'
count = text.count(anchor)
if count != 2:
    raise SystemExit(f'expected 2 launch screen anchors, found {count}')
text = text.replace(anchor, insert + anchor)
p.write_text(text)
PY
```

Expected: command exits 0.

- [ ] **Step 3: Verify build settings reflect new identity**

Run:

```bash
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -showBuildSettings 2>/dev/null \
  | rg "PRODUCT_BUNDLE_IDENTIFIER|INFOPLIST_KEY_CFBundleDisplayName|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|PRODUCT_NAME"
```

Expected includes:

```text
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = XXXXXXXXXX
INFOPLIST_KEY_CFBundleDisplayName = VisionPlex
PRODUCT_BUNDLE_IDENTIFIER = com.jlipworth.VisionPlex
PRODUCT_NAME = PlexAVPApp
```

`PRODUCT_NAME = PlexAVPApp` is acceptable in this pass because the external identity is bundle/display name.

- [ ] **Step 4: Build unsigned simulator target**

Run:

```bash
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit Xcode identity change**

Run:

```bash
git diff -- PlexAVPApp.xcodeproj/project.pbxproj
git add PlexAVPApp.xcodeproj/project.pbxproj
git diff --cached --check
git commit -m "Rename development bundle identity to VisionPlex"
```

Expected: commit contains only `PlexAVPApp.xcodeproj/project.pbxproj`.

---

### Task 2: Add portable CI hygiene script

**Files:**
- Create: `scripts/ci-hygiene.sh`

- [ ] **Step 1: Create the script**

Run:

```bash
mkdir -p scripts
cat > scripts/ci-hygiene.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

printf '== git whitespace check ==\n'
git diff --check

printf '== stale bundle id check ==\n'
if rg -n 'com\.personal\.PlexAVPApp' README.md docs CLAUDE.md PlexAVPApp.xcodeproj 2>/dev/null; then
  fail 'stale com.personal.PlexAVPApp reference found'
fi

printf '== local signing file check ==\n'
if git ls-files --error-unmatch Signing.local.xcconfig >/dev/null 2>&1; then
  fail 'Signing.local.xcconfig is tracked'
fi
if git ls-files | rg -n '(^|/)Signing\.[^.]+\.xcconfig$|\.mobileprovision$|\.p12$|\.cer$'; then
  fail 'signing credential/profile artifact is tracked'
fi

printf '== obvious secret placeholder check ==\n'
if git ls-files | rg -v '(^|/)\.gitignore$|(^|/)ci-hygiene\.sh$' | xargs rg -n --hidden --no-ignore-vcs \
  'X-Plex-Token:|PLEX_TOKEN=|plex01\.example\.org|10\.42\.1\.224' 2>/dev/null; then
  fail 'forbidden Plex token/server string found'
fi

printf '== required docs check ==\n'
test -f README.md || fail 'README.md missing'
test -f docs/DEVELOPMENT.md || fail 'docs/DEVELOPMENT.md missing'
test -f Signing.xcconfig || fail 'Signing.xcconfig missing'

printf 'ci-hygiene: ok\n'
SH
chmod +x scripts/ci-hygiene.sh
```

Expected: script is executable.

- [ ] **Step 2: Run script and confirm current expected failure or pass**

Run:

```bash
./scripts/ci-hygiene.sh
```

Expected at this point: it may fail if docs still contain `com.personal.PlexAVPApp`. If it fails only for stale docs, continue to Task 3 and re-run after docs are updated. If it fails for tracked secrets/signing artifacts, stop and inspect before continuing.

- [ ] **Step 3: Stage script only when its contents are correct**

Run:

```bash
git diff -- scripts/ci-hygiene.sh
git add scripts/ci-hygiene.sh
git diff --cached --check
```

Expected: no whitespace errors.

Do not commit yet if Task 3 docs are needed for the script to pass; commit CI hygiene with the Woodpecker task.

---

### Task 3: Update README and development docs

**Files:**
- Modify: `README.md`
- Modify: `docs/DEVELOPMENT.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace stale bundle ID references in docs**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
for name in ['README.md', 'docs/DEVELOPMENT.md', 'CLAUDE.md']:
    p = Path(name)
    text = p.read_text()
    text = text.replace('com.personal.PlexAVPApp', 'com.jlipworth.VisionPlex')
    p.write_text(text)
PY
```

Expected: command exits 0.

- [ ] **Step 2: Patch README Build & run section**

Edit `README.md` so `## Build & run` contains this content, preserving the rest of the README:

````markdown
## Build & run

This is currently a **personal-device sideload** project, not an App Store/TestFlight release. The app identity is **VisionPlex** with development bundle id `com.jlipworth.VisionPlex`.

Build the app for the visionOS 26.5 simulator without signing:

```bash
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Run the `PlexKit` test suite:

```bash
cd PlexKit && swift test
```

For a physical Apple Vision Pro, sign in to your Apple account in Xcode and create an ignored local signing file:

```bash
cat > Signing.local.xcconfig <<'SIGNING_EOF'
DEVELOPMENT_TEAM = YOUR_TEAM_ID
SIGNING_EOF
```

Xcode automatic signing then manages the development provisioning profile. The first local install may require enabling Developer Mode / trusting the developer on the Vision Pro; that is Apple's security gate for locally installed development apps, not a project setting we can remove. Free/personal-team development profiles may still require periodic rebuilds from Xcode.

Local validation and Woodpecker CI run the portable checks:

```bash
./scripts/ci-hygiene.sh
cd PlexKit && swift test
```

A future App Store/TestFlight pass would add App Store Connect metadata, distribution signing, privacy labels, screenshots, and archive/upload docs. That is intentionally not part of the current readiness pass.
````

Expected: README no longer mentions the old bundle ID.

- [ ] **Step 3: Patch `docs/DEVELOPMENT.md` build/test/run section**

Update the top build/test block so it includes these commands:

````markdown
## Build, test, run

```sh
# Build (visionOS 26.5 simulator, unsigned)
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# PlexKit unit tests
cd PlexKit && swift test

# Repo hygiene checks used by Woodpecker
./scripts/ci-hygiene.sh

# Install + launch on a booted sim
APP="$HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-<hash>/Build/Products/Debug-xrsimulator/PlexAVPApp.app"
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.jlipworth.VisionPlex

# After-the-fact logs
xcrun simctl spawn booted log show --last 5m --predicate 'process == "PlexAVPApp"' --style compact
```

- App bundle id: `com.jlipworth.VisionPlex` · Sim: "Apple Vision Pro" (visionOS 26.5).
- New Swift files are auto-included (Xcode file-system-synchronized groups + SPM
  `PlexKit/Sources`, `PlexKit/Tests`) — no `project.pbxproj` edits needed.
````

Expected: command examples use the new bundle ID.

- [ ] **Step 4: Add physical-device signing notes to `docs/DEVELOPMENT.md`**

Add this section after the build/test/run section:

````markdown
## Personal-device signing

`Signing.xcconfig` is committed and optionally includes ignored local values from `Signing.local.xcconfig`. For device installs, create:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Do not commit `Signing.local.xcconfig`, `.mobileprovision`, `.p12`, `.cer`, Plex tokens, or machine-local account data. Xcode should stay on automatic signing for this project.

If visionOS asks you to enable Developer Mode or trust the developer, accept that flow on the device. That prompt is expected for locally installed development apps. It is separate from whether the Xcode project is configured correctly.
````

Expected: signing setup is documented without exposing the real local Team ID.

- [ ] **Step 5: Patch `CLAUDE.md` command references only**

Update `CLAUDE.md` command snippets so simulator launch/terminate uses:

```sh
xcrun simctl terminate booted com.jlipworth.VisionPlex; xcrun simctl launch booted com.jlipworth.VisionPlex
```

Also ensure any bundle ID prose says:

```markdown
Bundle ID: `com.jlipworth.VisionPlex`.
```

Expected: no unrelated `CLAUDE.md` edits are introduced.

- [ ] **Step 6: Run stale reference check**

Run:

```bash
rg -n 'com\.personal\.PlexAVPApp|bundle id `com\.personal' README.md docs CLAUDE.md PlexAVPApp.xcodeproj || true
```

Expected: no output.

- [ ] **Step 7: Review docs diff carefully**

Run:

```bash
git diff -- README.md docs/DEVELOPMENT.md CLAUDE.md
```

Expected: changes are limited to signing, bundle ID, validation, and CI docs. Unrelated user edits in `CLAUDE.md` are preserved.

---

### Task 4: Add Woodpecker CI pipelines

**Files:**
- Create: `.woodpecker/plexkit.yml`
- Create: `.woodpecker/hygiene.yml`
- Stage: `scripts/ci-hygiene.sh` from Task 2

- [ ] **Step 1: Create `.woodpecker/plexkit.yml`**

Run:

```bash
mkdir -p .woodpecker
cat > .woodpecker/plexkit.yml <<'YAML'
# .woodpecker/plexkit.yml
# Portable Swift package tests. The full visionOS app build remains a local macOS/Xcode check.

when:
  event: [push, pull_request, manual]

steps:
  - name: plexkit-tests
    image: swift:6.0
    commands:
      - cd PlexKit
      - swift test
YAML
```

Expected: file exists.

- [ ] **Step 2: Create `.woodpecker/hygiene.yml`**

Run:

```bash
cat > .woodpecker/hygiene.yml <<'YAML'
# .woodpecker/hygiene.yml
# Repo hygiene checks that do not require Apple signing credentials or a macOS runner.

when:
  event: [push, pull_request, manual]

steps:
  - name: repo-hygiene
    image: alpine:3.20
    commands:
      - apk add --no-cache bash git ripgrep
      - ./scripts/ci-hygiene.sh
YAML
```

Expected: file exists.

- [ ] **Step 3: Run local hygiene script**

Run:

```bash
./scripts/ci-hygiene.sh
```

Expected:

```text
ci-hygiene: ok
```

- [ ] **Step 4: Run PlexKit tests locally**

Run:

```bash
cd PlexKit && swift test
```

Expected: test suite passes.

- [ ] **Step 5: Inspect Woodpecker YAML**

Run:

```bash
sed -n '1,120p' .woodpecker/plexkit.yml
sed -n '1,120p' .woodpecker/hygiene.yml
```

Expected: both files use simple `when` and `steps` blocks matching the user's other Woodpecker repos.

- [ ] **Step 6: Commit CI and docs together**

Run:

```bash
git add README.md docs/DEVELOPMENT.md CLAUDE.md scripts/ci-hygiene.sh .woodpecker/plexkit.yml .woodpecker/hygiene.yml
git diff --cached --check
git diff --cached --stat
git commit -m "Add VisionPlex signing docs and Woodpecker CI"
```

Expected: commit includes only docs, CI files, and `scripts/ci-hygiene.sh`.

---

### Task 5: Final verification and readiness summary

**Files:**
- No planned file changes unless verification reveals a readiness bug.

- [ ] **Step 1: Run unsigned visionOS simulator build**

Run:

```bash
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run package tests**

Run:

```bash
cd PlexKit && swift test
```

Expected: all tests pass.

- [ ] **Step 3: Run repo hygiene**

Run:

```bash
./scripts/ci-hygiene.sh
```

Expected: `ci-hygiene: ok`.

- [ ] **Step 4: Confirm Xcode identity/signing settings**

Run:

```bash
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -showBuildSettings 2>/dev/null \
  | rg "PRODUCT_BUNDLE_IDENTIFIER|INFOPLIST_KEY_CFBundleDisplayName|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|PRODUCT_NAME|SUPPORTED_PLATFORMS"
```

Expected includes:

```text
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = XXXXXXXXXX
INFOPLIST_KEY_CFBundleDisplayName = VisionPlex
PRODUCT_BUNDLE_IDENTIFIER = com.jlipworth.VisionPlex
PRODUCT_NAME = PlexAVPApp
SUPPORTED_PLATFORMS = xros xrsimulator
```

- [ ] **Step 5: Confirm no local signing/secrets are staged or tracked**

Run:

```bash
git ls-files | rg 'Signing\.local\.xcconfig|\.mobileprovision$|\.p12$|\.cer$' || true
git status --short --branch
```

Expected: first command has no output. `git status` may still show unrelated pre-existing dirty files, but no uncommitted readiness files.

- [ ] **Step 6: Push if requested or already implied by the current workflow**

If the user asks to publish the readiness commits, run:

```bash
git push origin main
```

Expected: GitHub `main` receives the new readiness commits. If not pushing yet, explicitly report that local `main` is ahead of `origin/main`.

---

### Task 6: Local checkout folder rename to `visionplex`

**Files:**
- No committed repo files.
- Local filesystem path change only.

- [ ] **Step 1: Stop any running processes using the old checkout path**

Run from the repo:

```bash
pwd
procs plex-avp-app || true
```

Expected: current path is `/path/to/user/plex-avp-app`; no critical process is using it. If a process is using the path, stop it or defer the rename.

- [ ] **Step 2: Move from parent directory**

Run:

```bash
cd /path/to/user
if [ -e visionplex ]; then
  echo 'ERROR: /path/to/user/visionplex already exists' >&2
  exit 1
fi
mv plex-avp-app visionplex
cd /path/to/user/visionplex
pwd
git status --short --branch
```

Expected: `pwd` prints `/path/to/user/visionplex`; git still works.

- [ ] **Step 3: Search for hard-coded local path references**

Run:

```bash
rg -n '/path/to/user/plex-avp-app|plex-avp-app' . --hidden -g '!DerivedData' -g '!.git' || true
```

Expected: either no output or only historical docs/spec references. If active scripts/docs contain the old local path, patch them in a small follow-up commit.

- [ ] **Step 4: Report new working directory**

Final response should say:

```text
Repo folder renamed locally: /path/to/user/visionplex
```

Also note that any already-open terminal/editor windows pointed at `/path/to/user/plex-avp-app` should be reopened in the new path.
