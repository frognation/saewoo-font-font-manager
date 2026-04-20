# Saewoo Font — macOS Font Manager (Prototype)

A native macOS font manager built with Swift + SwiftUI. Inspired by RightFont, FontBase, and Typeface 3, with extra emphasis on **batch toggling** (Projects + Palettes) so you can keep your active font set lean and your system memory low.

> Status: **runnable prototype**. Scans your installed fonts, previews them, activates/deactivates via the OS without admin auth, auto-categorizes by style + mood, and lets you build togglable Project / Palette collections.

---

## Quick start

```bash
cd saewoo-font-font-manager
swift run SaewooFont
```

Requires macOS 13+ and Swift 5.9+ (ships with Xcode 15 / Command Line Tools).

First launch will scan `~/Library/Fonts` and `/Library/Fonts`. Add custom folders from the sidebar's **Sources** section.

---

## Why this exists

Most font managers either:
1. Activate everything → bloated memory, slow app launches, font menu chaos
2. Force you to activate one-by-one → tedious

This prototype's core idea: **named togglable collections**. Build a "Brand Palette" with 6 fonts, or a "Client X — Q2" project with 12 fonts — then activate/deactivate the whole set with one click. Only what you need is loaded at any time.

---

## Features

### Library
- Auto-scan of system + user font folders, plus user-added folders
- Per-face extraction (TTC/OTC expansion) with PostScript name, family, style, weight/width/slant
- Persistent JSON cache so subsequent launches start instantly

### Auto-categorization
- **Categories** (Google Fonts taxonomy): Serif · Sans Serif · Display · Handwriting · Monospace · Symbol
  - Decision pipeline: Core Text symbolic-trait class mask → PANOSE bytes from OS/2 table → name-token heuristics
- **Moods** (auto-tagged): Elegant · Modern · Playful · Technical · Vintage · Bold · Minimal · Decorative
  - Driven by name tokens, weight axis, and category fallback rules

### Activation
- Uses `CTFontManagerRegisterFontURLs` with **`.session` scope** — no admin prompt, auto-clears on logout, batch-fast for thousands of files.
- Activation state persists across app launches within a login session.
- One-click on:
  - individual face
  - entire family
  - entire project / palette / favorites set

### Organization
- ⭐ **Favorites** — star any face
- 📁 **Projects** — togglable per-job font sets (e.g. "Acme rebrand")
- 🎨 **Palettes** — reusable font kits (e.g. "Editorial", "Brand Guidelines")
- Right-click any font(s) → "Add to Project / Palette"

### Browsing
- Sidebar filters: All · Active · Inactive · Favorites · per-Category · per-Mood · per-Collection
- Live search across family, style, PS name
- Adjustable preview size (12–96pt) and custom preview text
- Family rows expand to show every face/style
- Inspector panel: full metadata + classifications + collection memberships

---

## Architecture

```
Sources/SaewooFont/
├── App/SaewooFontApp.swift           # @main, scene + commands
├── Models/
│   ├── FontItem.swift                # one face = one row
│   └── FontCollection.swift          # Project + Palette unified
├── Services/
│   ├── FontScanner.swift             # filesystem walk → CTFontDescriptors → FontItems
│   ├── FontClassifier.swift          # traits + PANOSE + name → category + moods
│   ├── FontActivator.swift           # CTFontManager .session scope (actor)
│   ├── Persistence.swift             # JSON state + library cache
│   └── FontLibrary.swift             # @MainActor coordinator (ObservableObject)
└── Views/
    ├── ContentView.swift             # NavigationSplitView shell
    ├── SidebarView.swift             # Library / Categories / Moods / Projects / Palettes / Sources
    ├── FontListView.swift            # family-grouped list with live previews
    ├── InspectorView.swift           # metadata + collection membership
    └── AddCollectionSheet.swift      # new project/palette modal
```

### Data flow

```
disk → FontScanner ──┐
                     ▼
             [FontItem]  →  FontLibrary  ←  LibraryState (favorites, collections, activeIDs)
                                │
                                ▼
                         FontActivator (CTFontManager .session)
                                │
                                ▼
                         all macOS apps see/lose the font
```

State lives in `~/Library/Application Support/SaewooFont/`:
- `state.json` — favorites, collections, active IDs, custom paths, preview prefs
- `library-cache.json` — extracted FontItem cache (rebuilt on Cmd-Shift-R rescan)

---

## Memory-efficiency rationale

`.session` scope registration is process-cheap: the font is mapped on demand and is unregistered immediately when you toggle it off. Apps launched **after** deactivation no longer see the face. Apps that already cached it (Adobe, etc.) keep their handle until relaunch — that's a CTFontManager constraint, not a workaround.

By keeping a small "always-on" baseline (Favorites) and toggling Project/Palette sets only while you work on them, the active font count stays in the dozens, not thousands.

---

## Known prototype limitations

- No `.persistent` (system-wide) install option yet — `.session` only. Add a future toggle for power users.
- No auto-activation plugin for Adobe / Figma — that needs Adobe's CSXS plugin protocol or a Figma plugin.
- No iCloud / team sync. Storage is single-user JSON.
- Variable font axis playground not yet implemented (Core Text exposes `kCTFontVariationAxesAttribute` — drop-in feature).
- No font conflict / duplicate PS-name resolver — currently the OS picks; an audit view is a small follow-up.
- Mood tagging is heuristic; an ML-driven version (style-embedding clustering) would be the long-term direction.

---

## Roadmap (next obvious wins)

1. **Smart collections** — saved searches with rule chains ("all sans-serif with weight ≥ Bold")
2. **Variable font playground** — sliders for each axis, save instances as palette entries
3. **Glyph & OpenType feature inspector** — per-character grid, ss01/ss02 toggles
4. **Adobe / Figma plugins** — auto-activate fonts referenced in open documents
5. **Conflict resolver** — duplicate PostScript-name detection with chooser UI
6. **iCloud / Dropbox sync** — share Projects + Palettes across machines
7. **Drag-out activation** — drag a font onto an app icon to scope it just for that app
