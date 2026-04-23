# Handoff Notes

Rolling notes for picking this project back up in a new agent / new machine.
Sessions are appended in reverse chronological order at the top. For the
one-paste session-start prompt, see `NEXT_SESSION.md`.

**Current branch: `work/compB-20260422`** (8 commits ahead of `main`).
Do not land on `main` directly — see "Cross-machine workflow" at the bottom.

---

## Session 2 — 2026-04-23 (compB)

Started from `main` @ `cb3abb4` (Session 1 end), branched to
`work/compB-20260422` to keep new work isolated from any potentially
unpushed Session 1 work on the other machine. Commits pushed in order:

| Commit     | Summary |
|------------|---------|
| `120551e`  | `DuplicatesView` — new "Minimize system folders" Keep strategy + `SystemFontGuard` (essentials + SIP-locked protection). Protected badges in UI, checkboxes disabled for essentials, location badges (`/System` · `/Library` · `~/Library` · Custom). |
| `20f41e3`  | Drop unused `import AppKit` from `FontScanner`. (Pure cleanup; was not the Xcode build-error fix — that one was a build-destination issue in Xcode's scheme picker.) |
| `16caeec`  | Attempt to fix New Project/Palette name-field input by wrapping `NewCollectionPrompt.show()` in `Task { @MainActor }` + explicit `makeFirstResponder`. **Did not work.** |
| `792ceb9`  | Replace `NSAlert` entirely with a bespoke `NSWindow` + `NSApp.runModal(for:)`. **Still did not work.** |
| `e8310fe`  | Attach prompt as AppKit **sheet** to the SwiftUI host window via `parent.beginSheet(window, completionHandler:)`. Made `show` async. **Still did not work** — because the real cause was elsewhere. |
| `197a73d`  | **`.rightfontlibrary` import** — new `RightFontImporter` service parses `manifest.rightfontmetadata`, per-font metadata, and fontlists. `FontScanner` descends into `.rightfontlibrary` packages transparently. Sidebar picker accepts both folders and `.rightfontlibrary` bundles. Right-click source → "Import RightFont Collections as Palettes" creates Palettes from each non-empty fontlist, auto-favorites starred fonts. |
| `9a74015`  | **THE real input fix + perf pass + Fork tool.** See details below. |
| `96445ac`  | System-active scan + Adobe Fonts local cache auto-detection. See details below. |

### 5. Keyboard input — root cause finally identified (commit `9a74015`)

All five earlier sheet-focused attempts failed because the SwiftUI input
bug was **app-wide**, not sheet-specific. Symptom: search box AND every
NSTextField showed a blinking cursor but keyboard events never landed.

Root cause: SwiftUI `@main App` compiled as an **SPM executable** (not a
proper `.app` bundle) runs with no activation policy set, so macOS never
treats the process as a real foreground app. Windows are visible, the
cursor blinks, but key events are dropped.

Fix: `@NSApplicationDelegateAdaptor(AppDelegate.self)` in
`SaewooFontApp.swift`, with the delegate calling
`NSApp.setActivationPolicy(.regular)` and `NSApp.activate(ignoringOtherApps: true)`
in `applicationDidFinishLaunching`.

Keeping the sheet-based NewCollectionPrompt because it's still the most
robust native-looking dialog — only now it actually accepts keyboard input.

### 6. Performance pass (commit `9a74015`)

For libraries with 45k+ faces the previous code was recomputing every
derived view on every SwiftUI render. Three changes:

- **Search is debounced (180 ms).** `searchInput` (the text-field
  binding) and `searchQuery` (what filtering uses) are now separate.
  Typing is instant even at 45k items.
- **`currentItems()` and `familyGroups` cache** by
  `(derivedVersion, sidebarSelection, searchQuery, activeVersion, favoritesVersion)`.
  Previously they re-iterated the whole library on every render.
- **`setActive*` and `toggleFavorite` bump lightweight version counters**
  (`activeVersion`, `favoritesVersion`) that invalidate only the view
  caches, not the expensive library-wide caches.

FontPreviewCache was already bounded by `NSCache(countLimit: 1000)`.

### 7. Fork tool — UFO / Designspace exporter (commit `9a74015`)

New tool sidebar entry under Tools. Turns existing fonts into
Glyphs.app / RoboFont-openable sources. License / copyright / trademark
are always stripped; unitsPerEm, ascender, descender, capHeight,
xHeight, italic angle, underline position/thickness are preserved.

Three scenarios, auto-detected from source selection:

- **Single static font → UFO 3** (`.ufo`) — one file, glyph outlines
  extracted via `CTFontCreatePathForGlyph` + `CGPath.applyWithBlock`.
  Glyph names come from `CGFont.name(for:)`, with `uni{HEX}` fallback.
- **Single variable font → Designspace** (`.designspace-output/` folder
  with `.designspace` + N UFO masters). Named instances parsed from
  the `fvar` table directly; if none exist we synthesise masters at
  each axis's min/default/max.
- **Multiple static styles → Designspace** — one UFO per style, with a
  Weight axis (100..900) inferred from each style's `kCTFontWeightTrait`.

Three orthogonal glyph modes:

- **Full** — all outlines in the default layer.
- **Empty** — font info + metrics only (single `.notdef`).
- **Background** — originals on `public.background` layer, default
  layer empty. Default mode — most useful for "forking to trace / start
  a new design with reference".

Optional "Reset identity" blanks familyName/styleName/postscriptFontName
so the fork is a clean starting point.

Source modes:
- Selected font
- All styles in selected font's family
- Current list in main pane (filter/collection/etc.)

Files:
- `Sources/SaewooFont/Services/UFOExporter.swift` (all writers +
  fvar parser + CGPath-to-GLIF converter + designspace XML writer)
- `Sources/SaewooFont/Views/ForkView.swift`
- `ToolKind.fork` added to `FontLibrary.swift`, wired in
  `ContentView` and `SidebarView` Tools section.

### 8. System-active scan + Adobe Fonts cache (commit `96445ac`)

Answers the question "do fonts activated by OTHER managers
(RightFont / FontBase / Typeface / Adobe CC) show up?" — now **yes**,
when the toggle is on.

- `FontScanner.scanAvailableInSystem(excluding:)` uses
  `CTFontCollectionCreateFromAvailableFonts` to enumerate every font
  CoreText currently knows about, regardless of filesystem location.
- `LibraryState.includeSystemActive` (default **on**) controls whether
  `rescan()` merges that enumeration with the filesystem walk. Toggle
  exposed in sidebar Sources section as "Other managers + Adobe CC".
- `FontScanner.adobeFontsCacheURL` detects
  `~/Library/Application Support/Adobe/CoreSync/plugins/livetype/.r/`
  and includes it in `defaultSearchRoots` when present.
- Scan status shows `"45 000 faces · +231 from other managers"`.

---

## Queued for the next session

Explicit user requests, in priority order:

1. **Duplicates tool — backup-before-delete system.**
   User wants deleted files sent to a reversible backup location so
   mistakes can be undone. Design the safest + most sensible approach
   (Trash works but not atomic with our state; consider a versioned
   snapshot under `~/Library/Application Support/SaewooFont/DuplicateBackups/{timestamp}/`
   with a `manifest.json` recording original paths for easy restore).

2. **Duplicates tool — list filters** (path / name / size sort).
   The full-list view should let users sort or filter by file path, by
   filename alphabetically, and by size.

3. **Duplicates tool — per-source delete-lock.**
   User wants to mark certain sources as "never delete from here,
   regardless of Keep strategy". Lock status is orthogonal to Keep
   priority. Either add per-source lock toggles, or propose a broader
   options system that captures the same idea.

4. **Google Fonts connector.**
   Mirror RightFont's connected-catalog feature. Plan:
   - Catalog fetch: `https://fonts.google.com/metadata/fonts`
     (undocumented but public, JSON with a `)]}'` XSS prefix; free).
   - Download: TTFs to
     `~/Library/Application Support/SaewooFont/GoogleFonts/`
     cache, add that dir as a source.
   - Browser UI: Tools section entry "Google Fonts" with search,
     per-family install / remove.

5. (Already shipped — Adobe Fonts local read is live.)

---

## What's shipped since the initial prototype

### 1. Variable Font Axis Playground
Modal-style playground for any variable font:
- Axis sliders for every variation axis the font exposes (`wght`, `opsz`, `wdth`, etc.)
- Editable sample text + size slider
- Named instances saved to `state.json` under `variableInstances`
- Copy-as CSS / Core Text literal / JSON clipboard actions
- Entry point: Inspector → "Playground" button (variable fonts only)

Files: `Sources/SaewooFont/Views/VariablePlaygroundView.swift`,
`Models/FontItem.swift` (`VariationAxis`), `Services/FontScanner.swift` (`VariationAxisReader`).

### 2. Foundry classification
Reads manufacturer name (name table ID 8) + OS/2 `achVendID` vendor code
+ PostScript prefix fallback. Normalizes suffixes (`, Inc.`, ` Ltd`, ...) and
maps known vendor codes (`ADBE` → Adobe, `APPL` → Apple, etc.).

Files: `Services/FontScanner.swift` (`FoundryReader`), `Models/FontItem.swift`.

### 3. Multi-category tags
`FontItem.categories: [FontCategory]` replaces the single `category`.
A font can be `[.serif, .monospace]` (Courier), `[.sansSerif, .monospace]` (Menlo), etc.
Monospace and display are orthogonal — added as additional tags on top of the shape class.

Old caches (single-value `category`) auto-migrate via `LegacyKeys` in `FontItem.init(from:)`.
Derived `primaryCategory` prefers shape class over monospace for single-label UIs.

Files: `Models/FontItem.swift`, `Services/FontClassifier.swift`, `Services/FontLibrary.swift`.

### 4. Sidebar — 3-tier hierarchy
Top-level collapsible sections with prominent 14pt semibold headers + colored glyphs:
- **Sources** — scan-root folders (user can hide, auto-hide <2 font ones)
- **Library** — Overview / Categories / Moods / Foundries / Projects / Palettes
  (each sub-section is independently collapsible)
- **Tools** — library-maintenance actions

Collapse state persists via `@AppStorage("sidebar.collapsedSections")`.

Dropped the VSplitView drag-to-resize in favor of the clearer 3-tier hierarchy.

Files: `Views/SidebarView.swift`.

### 5. Sources distinguishing + clickable
- `~/Library/Fonts` → "User Fonts", `/Library/Fonts` → "Shared Fonts"
- Folders with <2 fonts auto-hide (surfaced under "Hidden sources (N)" menu)
- Clicking a source row filters the list to that folder
- Right-click: Reveal / Activate All / Deactivate All / Hide

Files: `Services/FontLibrary.swift` (`label(for:)`, `displayableDefaultSources`),
`Views/SidebarView.swift`.

### 6. Tools (full set)

| Tool | What it does |
|------|--------------|
| **Find Duplicates** | Groups fonts by PostScript name; bulk-select winners by strategy (Smart / Newest / User-folder / Largest); trash extras |
| **Organize** | Move / Sort-into-subfolders between folders. Filters by category/foundry/mood, skips Apple system essentials, preserves favorites & collection membership across file moves |
| **Proof Sheet** | FontGoggle-lite. 3 tabs: **Type** (editable canvas + OT feature toggles + axes), **Glyphs** (full character grid), **Coverage** (Unicode-block heat map). PDF/PNG/Copy-image export. Source files (.ufo/.glyphs) not supported — needs compile step. |
| **Orphan Files** | Files the scanner couldn't parse. Bulk trash. |
| **Missing References** | Dangling favorite/collection/instance IDs pointing at vanished fonts. One-click cleanup. |
| **Largest Files** | Top N by size. Bulk trash. Essentials marked. |

Files: `Views/DuplicatesView.swift`, `OrganizeView.swift`, `ProofSheetView.swift`,
`OrphansView.swift`, `MissingRefsView.swift`, `LargeFilesView.swift`.

### 7. Figma design mirror
The current app UI is mirrored into the Figma file at
`https://www.figma.com/design/kJvsCxSYPOBe3iaoGPDnJI/saewoo-font-manager?node-id=8-2`.
Built via Figma MCP `use_figma`. Use that as the canvas for future design edits.

### 8. Performance pass
- **Derived-data memoization**: `categoryCounts`, `moodCounts`, `foundryCounts`,
  `variableCount`, `duplicateGroups`, `itemsByFileSize`, `missingReferences`
  are cached by a `derivedVersion` tag. Invalidated only when `items` / `favorites`
  / `collections` / `variableInstances` actually change.
- **Parallel scanner**: `FontScanner.scanParallel(roots:)` partitions the file
  list into 8 chunks and parses via `TaskGroup`. 3–4× faster first scan.
- **FontPreviewCache → NSCache** with `countLimit = 1000` and quantized size
  keys. Fixes unbounded memory growth during long sessions.

Files: `Services/FontLibrary.swift`, `Services/FontScanner.swift`,
`Views/FontListView.swift` (`FontPreviewCache`).

---

## Known broken / in-flight

### ⚠️ New Project / New Palette name typing
**Status: 4 attempts failed, 5th attempt (minimal NSAlert) deployed but unverified.**

Five progressive attempts, each more AppKit-native than the last:
1. SwiftUI `TextField` + `@FocusState` + dispatch delay — user reported still can't type
2. NSTextField via NSViewRepresentable + `makeFirstResponder` — still broken
3. Same as #2 + `EditableTextField` subclass + retry loop — still broken
4. `NSAlert` with custom `AccessoryView` NSView subclass (name field + color swatches) — still broken
5. **Current**: `NSAlert` with plain `NSTextField` as `accessoryView`, no custom subclass; `alert.layout()` before `initialFirstResponder`; color picker moved to a "Change Color" submenu on each collection's right-click menu

If #5 still fails on the user's machine, suspect environmental causes — in priority order:
- **Korean IME**: try Ctrl+Space to force English input while testing
- **Xcode debugger**: run via `⌘⇧R` (Run Without Debugging) or `swift run -c release SaewooFont` from terminal
- **Keyboard-hooking apps**: Karabiner-Elements, BetterTouchTool, Alfred hotkeys
- **Accessibility permissions** in System Settings → Privacy & Security

If environmental is ruled out, next attempt = move to a dedicated `NSWindow` (not a sheet, not an alert) presented modally via `NSApp.runModal(for:)`. That's the last-resort AppKit pattern.

File: `Views/AddCollectionSheet.swift`.

### Session / activation caveat
`CTFontManagerRegisterFontURLs(.session)` scope is auto-cleared on logout — by
design. Activation state persists across relaunches within a login session only.

---

## Architecture reminders

```
Sources/SaewooFont/
├── App/SaewooFontApp.swift           @main + window + commands
├── Models/
│   ├── FontItem.swift                one-row-per-face + VariationAxis
│   └── FontCollection.swift          Projects/Palettes + VariableInstance + LibraryState
├── Services/
│   ├── FontScanner.swift             filesystem walk → items + orphanURLs (parallel)
│   ├── FontClassifier.swift          traits + PANOSE + name → [FontCategory] + [FontMood]
│   ├── FontActivator.swift           CTFontManager .session scope (actor)
│   ├── Persistence.swift             state.json + library-cache.json
│   └── FontLibrary.swift             @MainActor coordinator; owns derivedVersion + caches
└── Views/
    ├── ContentView.swift             NavigationSplitView shell + tool routing
    ├── SidebarView.swift             3-tier collapsible hierarchy
    ├── FontListView.swift            family-grouped list; FontPreviewCache
    ├── InspectorView.swift           metadata + classification + variable section
    ├── VariablePlaygroundView.swift  axis sliders + instance save
    ├── AddCollectionSheet.swift      NSAlert-based project/palette prompt
    ├── DuplicatesView.swift          PS-name collisions; bulk trash with strategy
    ├── OrganizeView.swift            Move / Sort-into-subfolders
    ├── ProofSheetView.swift          Type / Glyphs / Coverage + export
    ├── OrphansView.swift             unparseable files
    ├── MissingRefsView.swift         dangling favorite/collection refs
    └── LargeFilesView.swift          biggest files first
```

### Critical invariants
- **FontItem.id** = `SHA.short("\(fileURL.path)::\(postScriptName)")`. Moving a
  file changes its ID — `moveFontFile` preserves the old ID by replacing the
  stored `FontItem` in place instead of regenerating.
- **Derived caches must be invalidated** on every mutation that affects them.
  Search `invalidateDerived()` — call sites are `rescan`, `bootstrap`, `deleteFontFile`,
  `moveFontFile`, `toggleFavorite`, collection mutations, variable-instance
  mutations, `cleanupMissingReferences`.
- **Activation state persistence** uses `activeFontIDs: Set<String>`. On
  bootstrap, `reapplyActivations()` re-registers those URLs so Core Text sees
  them again this session.
- **Cache staleness** is detected in `cacheLooksStale` — if all items have
  `foundry == "Unknown"` the cache predates foundry extraction, so we rescan.
  Same pattern for future schema changes.

---

## Roadmap — next obvious picks

In priority order based on what's been asked or lightly scoped:

1. **Cloud folders UX** — the "+" button becomes a menu with
   `Local folder… / Google Drive / Dropbox / iCloud Drive / OneDrive / Other…`
   shortcuts that navigate the picker to the common File Provider mount points.
   Technical: no API integration needed — those are regular folders once the
   user's sync app has them mounted.

2. **Glyph detail popover** — in Proof Sheet's Glyphs tab, click a glyph →
   popover with glyph name (from 'post' table), Unicode category, vector outline.

3. **Waterfall view** — a Proof Sheet mode that renders one line at 8–10
   different sizes (8/10/12/14/18/24/36/48/72/96pt) for comparing rendering at
   different scales.

4. **Source-file support (the hard one)** — Python bridge to
   `fontmake` / `glyphsLib` if the user has them installed, compiling `.ufo` /
   `.glyphs` / `.designspace` on-the-fly to a temp `.otf` for proofing. Would
   enable FontGoggle-level source-file support. Needs: Python discovery, shell
   helper, temp-file lifecycle, UI for "compiled proof" state.

5. **Activation-history tool** — track when a font was last activated so an
   "Unused Fonts" tool can surface zombies. Would need a new `@Published`
   map in `LibraryState`.

6. **iCloud / Dropbox sync of state.json** — share Projects + Palettes
   across machines. Trivial if sync folder is already mounted; harder for
   seamless conflict resolution.

---

## Copy-paste prompt for the next session

```
Saewoo Font macOS 폰트매니저 프로젝트 이어서 작업할게.

리포: https://github.com/frognation/saewoo-font-font-manager
로컬 경로: ~/Documents/GitHub/Projects/saewoo-font-font-manager

먼저 README.md 와 HANDOFF.md 를 읽고 전체 현황을 파악해줘. HANDOFF.md에
지금까지 뭐가 구현됐고, 뭐가 막혀있고, 다음에 할 만한 것들이 정리돼 있어.
아키텍처 상기 필요하면 Sources/SaewooFont/ 구조도 훑어봐.

확인 체크리스트:
1. 현재 브랜치 상태 (git status / git log)
2. HANDOFF.md의 "Known broken / in-flight" 섹션 — 특히 New Project 이름
   입력 버그가 5번째 시도(NSAlert with plain NSTextField)에서 해결됐는지
   내가 확인했는지 물어봐. 안 됐으면 그 해결부터.
3. HANDOFF.md "Roadmap" 섹션에서 내가 다음 항목을 골라주면 그걸 진행.

작업 방식:
- 네이티브 macOS SwiftUI 앱이라 수정해도 Hot Reload 안 돼. 내가 Xcode에서
  ⌘R (또는 ⌘⇧R run-without-debugger)로 재실행해야 반영됨.
- Claude Code는 파일만 수정함. 돌고 있는 앱은 메모리에 고정이니 내가
  매번 ⌘Q → ⌘R 해야 해.
- swift build 는 터미널에서 돌려도 되고 Xcode가 자동으로 재빌드해도 됨.
- 큰 변경은 Build & verify 단계로 마무리해줘.

시작하기 전에 위 3개 체크 확인하고, 내 결정 기다려줘.
```

---

*Last updated at commit time — see `git log` for the exact commit.*
