# Handoff Notes

Rolling notes for picking this project back up in a new agent / new machine.
Sessions are appended in reverse chronological order at the top. For the
one-paste session-start prompt, see `NEXT_SESSION.md`.

**Current branch: `main`**.
The previous `work/compB-20260422` work has been merged back into `main`;
future sessions can start from `main` unless the user asks for a feature branch.

---

## Session 4 — 2026-08-16 · commits `25d3efc..ab675a7`

Triggered by "무겁고 느린 게 젤 큰 문제". Started as a performance pass, then
widened into persistence safety, a RightFont library migration, a
Projects/Palettes merge, basic list interaction (multi-select, live source
status), a rewrite of the Duplicates tool's deletion safety model, and a
validation pass on the Fork tool's UFO output. All seven commits below landed
on `main`; nothing from this session is uncommitted.

| Commit | Summary |
|--------|---------|
| `25d3efc` | perf(library): fix 6.8s sidebar render; split published state; cache I/O off main |
| `0651669` | fix(persistence): stop `--bench` from wiping state.json; add rolling backups |
| `7dc4330` | fix(rightfont): correct UUID matching, add headless import, drop attribution fields |
| `c6ea80a` | refactor(collections): merge Palettes into Projects |
| `997eb4c` | feat: multi-select fonts (cmd/shift) and live source availability |
| `afdee88` | feat(duplicates): replace name-based deletion with byte-identical matching |
| `ab675a7` | test(fork): add `--fork` CLI that exports and validates the UFO it produces |

### 1. Performance pass #3 (`25d3efc`)

**Reference machine**: `~/Library/Fonts` holds 6 904 files, which expand to
**77 837 faces / 4 136 families / 546 foundries**. The old `library-cache.json`
was 60 MB. Every number below is a **release** build on that library — debug
numbers are meaningless here.

**New: `--bench` harness** (`Services/Benchmark.swift`):

```bash
swift build -c release && ./.build/arm64-apple-macosx/release/SaewooFont --bench
```

Runs headless before any window is created (hooked from `SaewooFontApp.init()`)
and prints a table of the paths that dominate perceived latency. `FontLibrary`
gained three `…ForBenchmark` methods so the harness can install items and force
cold caches without touching disk or Core Text. **Keep the harness in sync with
what the views actually call** — the `sourcesSection` measurement is a hand-written
mirror of `SidebarView.sourcesSection`, so if that view changes, change this too
or the number silently starts lying.

**The actual bug**: `SidebarView.sourcesSection` called `itemsInSource()` about
**nine times per body evaluation**, and `itemsInSource` filtered all 77 837
items while calling `standardizedFileURL` on each one (419 ms per pass, vs
54 ms for raw `.path`). That alone was **6 775 ms per sidebar render**. And
because `searchInput` was `@Published` on `FontLibrary` — which all 14 views
observe via `@EnvironmentObject` — *every keystroke* re-evaluated that body.
Typing one character cost ~7 s. The 180 ms search debounce added in Session 2
was therefore dead code: it debounced `searchQuery`, but publishing
`searchInput` had already invalidated the whole UI.

**Results**:

| path | before | after |
|------|--------|-------|
| full `sourcesSection` (~9 passes) | 6 775.0 ms | **0.1 ms** |
| `displayableDefaultSources` | 1 696.4 ms | **0.0 ms** |
| 30 visible foundry rows | 252.9 ms | **9.1 ms** |
| `toggleFavorite` → next sidebar render | 169.9 ms | **6.6 ms** |
| search commit + regroup | 196.9 ms | 172.2 ms |
| cache decode (launch) | 1 313.7 ms | 1 227.4 ms, now **off the main actor** |
| cache encode (delete/move) | 1 016.6 ms | 977.9 ms, now **debounced + detached** |
| settled `phys_footprint` | 437 MB | **364 MB** |
| peak `phys_footprint` | 549 MB | **712 MB** ⚠️ regression, see Known issues |

**What changed**:

1. **Source/foundry buckets** (`FontLibrary`). `itemsInSource` / `itemsInFoundry`
   are now dictionary lookups built in one pass and cached by `derivedVersion`.
   Buckets store **indices, not `FontItem` copies** — a struct-copy bucket map
   duplicates ~17 MB per map at this library size. Added `itemCountInSource`
   (the sidebar only ever needed counts) and `foundryActivation` (computes
   all/any-active off indices so 546 rows never materialize item arrays).
2. **URLs standardized once, at scan time** (`FontScanner.buildItem`). Everything
   downstream compares raw `.path`.
3. **`@Published` churn split out** (new `Services/UIState.swift`).
   `SelectionModel` owns `selectedFontID`; `PreviewSettings` owns preview text +
   size with a 400 ms coalesced save; the search field owns its text as plain
   `@State`. `FontLibrary` no longer publishes any of them, so slider drags,
   row taps and keystrokes cannot invalidate the sidebar.
4. **Invalidation split**: `invalidateDerived()` (items changed → clear
   everything) vs `invalidateMembership()` (favorites/collections/instances →
   clear only `missingRefs`). Starring a font used to recompute `duplicateGroups`,
   `itemsByFileSize` and `foundryCounts` for no reason.
5. **Cache I/O off the main actor**: `loadCachedLibraryOffMain()` at bootstrap;
   `scheduleCacheSave()` (800 ms debounce, detached) for delete/move;
   `saveCacheNow()` on rescan completion.
6. **`FontItem` shrunk**: `format: String` → `formatKind: FontFormat` (enum),
   `panose: [Int]` → `[UInt8]`, `displayName` stored only when it differs from
   the derived "Family Style". Decoding accepts both old and new cache layouts,
   so **no forced rescan** — and uses `decodeIfPresent` rather than `try?`
   (a caught throw per absent key across 78 k items is not free; that mistake
   cost ~90 ms until it was spotted).
7. **`FontListView` uses `List`** instead of `ScrollView` + `LazyVStack`, which
   never released realized rows.
8. **`FontPreviewCache` descriptor cache**: `CTFontDescriptor`s are now cached
   per file+face, independent of size, with failures negative-cached. Previously
   an *inactive* font missed the `NSFont(name:)` fast path and re-parsed its file
   from disk inside a SwiftUI body on every cache miss — so dragging the preview
   size slider re-read every visible font file on every tick.
9. **`migrateReferences` — data-loss fix.** `FontItem.id` hashes the absolute
   path, so Organize's move changed it. `moveFontFile` patched the in-memory
   record, but the *next rescan* regenerated the ID from the new path and
   silently dropped the font out of every Favorite / Project / Palette. Rescan
   now remaps references using an identity that survives a move
   (PostScript name + filename + byte size), skipping ambiguous matches.

### 2. Persistence hardening — `--bench` wiped `state.json` (`0651669`)

⛔️ **Data-loss incident caused by this session — read before writing tools.**
The `--bench` harness (added in commit 1, above) built a `FontLibrary` directly
and never called `bootstrap()`, so its `favorites` / `collections` /
`customScanPaths` were all empty. It then called `toggleFavorite` to measure
the invalidation cascade — which reaches `persist()` — and wrote that **empty
state over the user's real `state.json`**, once per benchmark run.

Lost: every `customScanPath` (~69 700 of the user's 77 837 faces came from
Dropbox / Google Drive / RightFont folders registered there), all favorites,
and any collection that existed at the time. `library-cache.json` was
untouched, so the *font list* still looked fine — which is exactly why it went
unnoticed for hours. Recovered by reconstructing the scan roots from the file
paths inside `library-cache.json`. Favorites were not recoverable.

Two guards now exist, both in `Services/Persistence.swift`:

- **`Persistence.readOnly`** — a hard write-lock. `Benchmark.run()` sets it on
  its very first line, and `DuplicateAuditCLI.run()` (added later this session,
  see `--scan-duplicates` below) does the same. Any future tool that constructs
  a `FontLibrary` without `bootstrap()` must do the same.
- **Rolling backups** — `saveState` copies the previous `state.json` to
  `StateBackups/state-<epoch>.json` before overwriting, keeping the last 30.
  `Persistence.stateBackups()` returns them newest-first for a future restore UI.

Verified: `state.json` md5 is unchanged across a full `--bench` run.

### 3. RightFont import — UUID fix, merge fix, headless import (`7dc4330`)

Found while migrating a real 313-fontlist library out of a `.rightfontlibrary`
package.

1. **UUID normalisation was wrong and silently ate most of the import.**
   `parseAllFontEntries` keys its map with `normalizeUUID` (hyphens stripped,
   uppercased), but both lookup sites used only `.uppercased()`. Fontlists
   store hyphenated UUIDs, so only the minority of lists whose UUIDs happened
   to already be hyphen-less ever matched. On the reference library this
   imported 90 of 225 non-empty fontlists; with the fix, 155.
2. **Same-named fontlists overwrote each other.** RightFont fontlists are a
   folder tree, so the same leaf name can appear under several parents.
   `importPalettes` now merges same-named entries within a run instead of
   replacing, which was collapsing 155 imported lists into 88 palettes and
   discarding the membership of whichever lost the race.
3. `createdBy` / `modifiedBy` are no longer decoded — they held the personal
   names of whoever built the library at the originating studio and were never
   stored by this app.

Adds `--import-rightfont <library> <map.json>`: a headless import that
resolves each font through a `location -> new absolute path` map, because the
in-app importer resolves locations *inside* the package, which stops working
once fonts have been lifted out and reorganised — but the collections are only
readable while the package still exists.

Also removes the unused `allExtrasCount` path and drops the Google Drive scan
root the user retired.

### 4. Projects/Palettes merge (`c6ea80a`)

Projects and Palettes were the same data type and behaviour — a named,
togglable set of faces — distinguished only by a `Kind` tag, which bought a
duplicated sidebar section, two identical "Add to…" menus, and a "which one
was it?" decision on every collection created. Now there is one concept,
Projects:

- `FontCollection.Kind.palette` is retained **only** for decoding existing
  `state.json`. `bootstrap()` folds any stored palette into `.project` and
  persists once; nothing creates `.palette` any more.
- Sidebar has a single Projects section; the context menu has a single
  "Add to Project".
- The RightFont importer now creates projects, and its report counts projects.

### 5. Multi-select and live source availability (`997eb4c`)

**Multi-select**: the list only ever held one selection, so activating twenty
fonts meant twenty clicks. `SelectionModel` now owns a `selectedIDs` set with
the standard macOS idioms — plain click replaces the selection, cmd-click
toggles one row, shift-click extends from the last anchor, cmd-A selects
everything visible, Esc clears. Shift-ranges run over a flattened
`visibleOrder` built from the family groups plus whichever families are
expanded, so a range means what the user sees rather than what the model
happens to store; the anchor is deliberately left alone when extending, so
successive shift-clicks re-range from the same origin instead of creeping down
the list. A selection bar appears above the list for multi-row selections with
Activate / Deactivate / Add to Project. Right-clicking inside an existing
multi-selection acts on the whole selection; right-clicking outside it acts on
just that row, per platform convention. `selectedFontID` is now
`private(set)` and always a member of `selectedIDs`.

**Source availability**: scan roots live on external drives and cloud mounts
that disappear mid-session; nothing checked for that, so a disconnected source
kept showing its last-known count and Reveal in Finder silently failed.
`SourceStatusChecker` (new `Services/SourceStatus.swift`) classifies a root as
available / unavailable / empty using a single
`fileExists(atPath:isDirectory:)` stat — no directory walk, since these roots
hold tens of thousands of files. `FontLibrary` caches the result in a
`sourceStatuses` map, refreshed at bootstrap, after every rescan, and on a
~10s timer that only republishes when something actually changed. The sidebar
greys offline rows, badges them "Offline", and disables Reveal in Finder and
the bulk activate/deactivate items for them. The cached count is still shown
rather than hidden, and `refreshSourceStatuses` never touches `items` —
unplugging a drive must not wipe the library.

### 6. Duplicates — byte-identical matching replaces name-based deletion (`afdee88`)

The Duplicates tool grouped files by PostScript name and offered to delete the
"extras". Measured against the real library, that was unsafe:

- 21,949 groups / 71,701 "extras" were offered for deletion.
- Opening 400 of those groups and comparing contents showed only 66% were
  actually the same font; the other 34% were different typefaces reusing a
  name — different versions, weight sets, language cuts.
- Worse, it counted faces but deleted files. 25,686 offered "extras" lived
  inside multi-face files, and one file here holds 252 faces, so a single
  click could take 251 unrelated faces with it.
- 133 groups had the keeper and the "extra" inside the *same file*, so
  deleting the extra would delete what it was meant to preserve.

Now nothing destructive is offered unless the files hash identically.
`DuplicateScanner` (new `Services/DuplicateScanner.swift`) compares in three
stages so this stays cheap: size buckets (free, from cached `FontItem`s), then
a SHA-256 of the first and last 16 KB, then a full hash only for what still
collides. 81,507 files scan in ~10s.

Deletion is lossless by construction — every face in a removed file still
exists byte-for-byte in the kept copy — and the API takes a group plus its
keeper, so "delete every copy" is not expressible. Protected system fonts are
skipped, cloud-synced paths are flagged, and a manifest of deleted → kept is
written to `DeletionManifests/`.

Favorites and projects pointing at a removed copy are re-pointed at the
identical face in the keeper. Matching is by PostScript name, falling back to
position when the names are unusable: Core Text invents placeholders like
`font0000000030329341` for fonts with no name table, and the number differs
per registration, so 806 faces in byte-identical files reported different
names. Without the fallback those references would have silently dangled.

Also fixes `itemsAtPath`, which filtered the whole library on every call —
the duplicates screen calls it per row and the audit once per copy per group,
about 7 billion comparisons at this library size, which presented as a hang.
It is now a cached path → faces map.

Adds `--scan-duplicates`, a read-only audit that runs the real scan and
asserts the safety property. Current result:

```
identical groups 23,644 · removable 44,159 · reclaimable 5.92 GB
groups with no valid keeper ............ 0
faces with no twin in the keeper ....... 0
faces paired by position ............... 806
multi-face files among deletions ....... 969  (identical copy kept)
protected files among deletions ........ 1,140 (skipped at delete time)
VERDICT: SAFE
```

### 7. Fork tool — `--fork` CLI validates the UFO it produces (`ab675a7`)

"Does Fork work?" is not answerable by reading `UFOExporter` — you have to
look at the bytes. `--fork` runs the real exporter on a real font, then checks
the bundle against the parts of UFO 3 that Glyphs / RoboFont / fontmake
refuse to open without, and for variable fonts checks that the masters
actually differ rather than being the default outlines written N times.

Findings on a 657-glyph, 6-axis variable font and a 253-glyph static OTF:

**Works**: metainfo/fontinfo/layercontents/contents.plist all present and
consistent, no case-insensitive `.glif` collisions, correct advance widths and
unicodes, cubic curves for CFF and qcurve for TrueType, 18 fvar named
instances read correctly, and all 18 masters carrying genuinely distinct
outlines (variation coordinates are applied).

**Gaps, all confirmed against the output** — this is now the top open item,
see `NEXT_SESSION.md`:

- **140 of 657 glyphs dropped.** `writeAllGlyphs` walks the character set and
  maps unicode → glyph, so anything reachable only through GSUB — alternates,
  ligatures, small caps — never gets exported.
- **No `kerning.plist`, `features.fea`, `groups.plist` or `lib.plist`**, so
  all GPOS/GSUB data is discarded.
- **No `<component>` in any glif**: composites are flattened, so accents stop
  tracking their base glyph.
- Glyph filenames use a leading underscore (`_Ccedilla.glif`) where the spec
  asks for one after each uppercase character (`C_cedilla.glif`). Harmless
  while `contents.plist` is authoritative, but not conforming.
- The designspace has `<source>` elements but no `<instance>` elements.

### CLI entry points

All wired in `SaewooFontApp.init()`, checked and `exit(0)`'d before any window
is created:

| Flag | Does | Source |
|------|------|--------|
| `--bench` | Headless perf harness; prints the latency table in section 1 above. Sets `Persistence.readOnly`. | `Services/Benchmark.swift` |
| `--scan-duplicates` | Read-only audit of the identical-file duplicate scan (section 6). Sets `Persistence.readOnly`. | `Services/RightFontImportCLI.swift` (`DuplicateAuditCLI`) |
| `--import-rightfont <library> <map.json>` | Headless RightFont library import (section 3). | `Services/RightFontImportCLI.swift` |
| `--fork <font> <outdir> [--variable]` | Exports and validates a UFO/Designspace bundle (section 7). | `Services/ForkCLI.swift` |

`--scan-duplicates` and `--import-rightfont` are `@MainActor` work; the app
pumps the run loop (`while !done.value { RunLoop.main.run(until:) }`) rather
than blocking on a semaphore, because parking the main thread on Swift
concurrency work that itself needs the main actor would deadlock. Any new CLI
entry point that touches `FontLibrary` must use the same pattern, not
`Task { … }` plus a blocking wait.

### Known issues

- ⚠️ **Peak footprint regressed 549 → 712 MB** (section 1). Settled memory
  improved, but launch peak is worse: the cache decode now runs on a
  background thread *concurrently* with SwiftUI building the UI, instead of
  blocking the main thread until it finished. An `autoreleasepool` around the
  decode was tried and did not help. The real fix is to stop shipping a 60 MB
  JSON blob — a binary/streaming format (or SQLite) would cut decode time,
  peak memory and file size together. **Still the single highest-value next
  perf task.**
- ⚠️ **`WARNING: Application performed a reentrant operation in its
  NSTableView delegate`** appears once at launch, new with the `List` change
  in `FontListView`. Harmless today; the message says it will become an
  assert in a future macOS. Worth tracking down before it does.
- `search commit` (172 ms) is now dominated by `familyGroups` regrouping
  (`Dictionary(grouping:)` + sort over 4 136 families), not by filtering. It
  runs once per debounce pause, not per keystroke.
- **Fork tool fidelity gaps** (section 7) — 140/657 glyphs dropped, no
  kerning/features/groups/lib, composites flattened, non-conforming glyph
  filenames, no designspace `<instance>` elements. In progress, see
  `NEXT_SESSION.md`.

### Audited but not changed

A read-only pass over the remaining views found these; none were touched:

- `ProofSheetView.swift:370,447` — `supportedCharacters()` reaches
  `CTFontManagerCreateFontDescriptorsFromURL` from inside a `@ViewBuilder`,
  i.e. synchronous font parsing during body evaluation.
- `ProofSheetView.swift:146` — `ForEach(lib.items)` builds a menu over the
  entire library.
- `InspectorView.swift:11`, `ProofSheetView.swift:71` — `lib.items.first(where:)`
  linear scan in `body`; wants an id→item dictionary.

---

## Session 3 — merged to `main`

`main` now includes the Session 2 branch plus two follow-up commits:

| Commit     | Summary |
|------------|---------|
| `633b379`  | Proof Sheet glyph-detail popover, plus `.vscode/launch.json` for local launch/debug. |
| `9b56ab3`  | Cloud section: Google Fonts browse/download/install/remove, Adobe Fonts filtered view, Google Fonts cache scan root. |

### Google Fonts + Adobe Fonts status

The Google Fonts connector from the old queued list is **shipped**:
- `GoogleFontsClient` fetches `https://fonts.google.com/metadata/fonts`,
  strips the XSSI prefix, caches the catalog for 24h, downloads CSS2 font
  URLs, and stores local files under
  `~/Library/Application Support/SaewooFont/GoogleFonts/`.
- `GoogleFontsView` adds catalog search, category filter, sort, per-family
  download/remove, and triggers a library rescan after changes.
- `FontScanner.defaultSearchRoots` always includes the Google Fonts cache.
- `AdobeFontsView` shows only fonts already synced locally by Creative Cloud;
  there is no public Adobe download/browse API in the app.

### Current next work

**Duplicates tool — three explicit user requests still open:**
1. Backup-before-delete system with a reversible manifest.
   Suggested location: `~/Library/Application Support/SaewooFont/DuplicateBackups/{timestamp}/`
   with a `manifest.json` recording original paths so a "Restore last delete"
   button can move files back. Trash works but isn't atomic with our state.
2. Duplicate list filters/sorts: path, filename, size.
3. Per-source delete-lock so some folders are never targeted regardless of
   Keep strategy. Lock state is orthogonal to Keep priority — either
   per-source toggles in Sources, or a broader "options" panel.

**Cloud follow-ups from `9b56ab3`:**

4. **WOFF2 → TTF fallback for Google Fonts.** `GoogleFontsClient.download`
   currently registers whatever the CSS2 endpoint returns (woff2 by default).
   If `CTFontManagerRegisterFontURLs` rejects a woff2 file on the user's
   macOS version, no fallback happens. Add a TTF retry that pulls from
   `github.com/google/fonts/raw/main/ofl/{slug}/{slug}-{variant}.ttf` when
   woff2 registration produces errors.

5. **Adobe Fonts metadata enrichment.** Files in `.../CoreSync/plugins/livetype/.r/`
   are numerically named (`1234`, `5678`, …); we lean on Core Text for the
   family name only. Adobe drops `AdobeFnt*.lst` plist files in the same
   tree with prettier metadata (postScriptFontName, copyright, version, …).
   Parse those and merge into the FontItem at scan time so Adobe Fonts show
   up with their original family/style names.

6. **Google Fonts variable-axis discovery.** The CSS2 endpoint returns
   wght-only URLs unless we encode the axis range. For variable families
   like Inter or Recursive, fetch a single woff2 covering the axis range
   instead of N static variants. Detect "is variable" from the metadata's
   `axes` field (already in the JSON, just not yet decoded).

7. **Bulk download** — "Download top N popular families" button so users
   can seed a working library in one click. Wire to the existing download
   pipeline; honor a concurrency limit so we don't slam gstatic.com.

8. **Catalog endpoint fallback.** `fonts.google.com/metadata/fonts` is
   undocumented — if Google changes it, browse breaks. Add a fallback
   to the official developer API
   (`https://www.googleapis.com/webfonts/v1/webfonts`) when an explicit
   key is set in Settings (or env var). Surface a clear error otherwise.

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
   Partially addressed by Session 4 (`afdee88`): deletion is now
   content-identical and lossless by construction (the deleted face still
   exists byte-for-byte in the kept file), and a deleted→kept manifest is
   written to `DeletionManifests/`. That is not the same as a restore-the-
   original-file backup — it only helps if the keeper survives — so this
   item is still open.

2. **Duplicates tool — list filters** (path / name / size sort).
   The full-list view should let users sort or filter by file path, by
   filename alphabetically, and by size.

3. **Duplicates tool — per-source delete-lock.**
   User wants to mark certain sources as "never delete from here,
   regardless of Keep strategy". Lock status is orthogonal to Keep
   priority. Either add per-source lock toggles, or propose a broader
   options system that captures the same idea.

4. **Done — Google Fonts connector.**
   Shipped in `9b56ab3` with catalog fetch/cache, per-family download/remove,
   local Google Fonts scan root, and Cloud > Google Fonts UI.

5. **Done — Adobe Fonts local read.**
   Shipped in `96445ac` / refined in `9b56ab3`.

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
**Status: root cause fixed in `9a74015`. Re-check only if the user reports a regression.**

Earlier failed attempts, each more AppKit-native than the last:
1. SwiftUI `TextField` + `@FocusState` + dispatch delay — user reported still can't type
2. NSTextField via NSViewRepresentable + `makeFirstResponder` — still broken
3. Same as #2 + `EditableTextField` subclass + retry loop — still broken
4. `NSAlert` with custom `AccessoryView` NSView subclass (name field + color swatches) — still broken
5. `NSAlert` with plain `NSTextField` as `accessoryView`, no custom subclass; also insufficient by itself.

The actual fix was app-wide: `SaewooFontApp` now installs an
`NSApplicationDelegate` and calls `NSApp.setActivationPolicy(.regular)` plus
`NSApp.activate(ignoringOtherApps: true)` on launch. SPM-built SwiftUI apps
without a bundle/Info.plist can show windows while not receiving key events.

File: `Views/AddCollectionSheet.swift`.

### Session / activation caveat
`CTFontManagerRegisterFontURLs(.session)` scope is auto-cleared on logout — by
design. Activation state persists across relaunches within a login session only.

---

## Architecture reminders

```
Sources/SaewooFont/
├── App/SaewooFontApp.swift           @main + AppDelegate (activation policy fix)
│                                     + CLI dispatch (--bench/--scan-duplicates/
│                                       --import-rightfont/--fork), all exit(0) before UI
├── Models/
│   ├── FontItem.swift                one-row-per-face + VariationAxis
│   └── FontCollection.swift          Projects (Kind.palette decode-only legacy) +
│                                       VariableInstance + LibraryState
├── Services/
│   ├── FontScanner.swift             filesystem walk → items + orphanURLs (parallel)
│   │                                 + scanAvailableInSystem + Adobe & Google cache roots
│   ├── FontClassifier.swift          traits + PANOSE + name → [FontCategory] + [FontMood]
│   ├── FontActivator.swift           CTFontManager .session scope (actor)
│   ├── Persistence.swift             state.json + library-cache.json; readOnly write-lock
│   │                                 + StateBackups/ rolling backups
│   ├── FontLibrary.swift             @MainActor coordinator; derivedVersion + caches
│   ├── SystemFontGuard.swift         essentials + SIP-protection rules for Duplicates/Organize
│   ├── RightFontImporter.swift       .rightfontlibrary parser → projects + favorites
│   ├── RightFontImportCLI.swift      --import-rightfont + --scan-duplicates (DuplicateAuditCLI)
│   ├── DuplicateScanner.swift        3-stage byte-identical matcher (size → edge hash → SHA-256)
│   ├── UFOExporter.swift             CGPath → GLIF + designspace XML writer (Fork tool)
│   ├── ForkCLI.swift                 --fork headless export + UFO-fidelity validator
│   ├── Benchmark.swift               --bench headless perf harness
│   ├── UIState.swift                 SelectionModel (multi-select) + PreviewSettings
│   ├── SourceStatus.swift            SourceStatusChecker — available/unavailable/empty
│   └── GoogleFontsClient.swift       /metadata/fonts catalog + CSS2 download + cache
└── Views/
    ├── ContentView.swift             NavigationSplitView + tool/cloud routing
    ├── SidebarView.swift             4-tier hierarchy: Sources / Cloud / Library / Tools
    ├── FontListView.swift            family-grouped List; multi-select bar; FontPreviewCache
    ├── InspectorView.swift           metadata + classification + variable section
    ├── VariablePlaygroundView.swift  axis sliders + instance save
    ├── AddCollectionSheet.swift      AppKit sheet (beginSheet) + NewCollectionPrompt
    ├── DuplicatesView.swift          byte-identical groups; bulk trash + keep strategies
    ├── OrganizeView.swift            Move / Sort-into-subfolders
    ├── ProofSheetView.swift          Type / Glyphs / Coverage + export + GlyphDetail popover
    ├── OrphansView.swift             unparseable files
    ├── MissingRefsView.swift         dangling favorite/collection refs
    ├── LargeFilesView.swift          biggest files first
    ├── ForkView.swift                UFO/Designspace exporter UI
    ├── GoogleFontsView.swift         catalog browse + per-family download
    └── AdobeFontsView.swift          CC cache filtered list + empty states
```

### Critical invariants
- **FontItem.id** = `SHA.short("\(fileURL.path)::\(postScriptName)")`. Moving a
  file changes its ID — `moveFontFile` preserves the old ID by replacing the
  stored `FontItem` in place instead of regenerating. That is not sufficient on
  its own: the next `rescan()` regenerates IDs from disk, so `migrateReferences`
  (Session 4) re-points favorites / collections / instances using
  PostScript name + filename + byte size. **Don't remove it** without changing
  how IDs are derived.
- **Item `fileURL`s are standardized at scan time** (`FontScanner.buildItem`).
  Downstream code must compare raw `.path`; calling `standardizedFileURL` per
  element in a loop or a view body is an ~8× penalty and is how the sidebar
  ended up costing 6.8 s per render.
- **Two invalidation levels** (Session 4). `invalidateDerived()` when `items`
  changes — clears every cache including the source/foundry buckets and the
  search index. `invalidateMembership()` for favorites / collections /
  variable-instance edits — clears only `missingRefs`. Using the heavy one for
  a membership edit is a correctness-neutral but expensive mistake.
- **`FontLibrary` must not gain high-frequency `@Published` properties.** All 14
  views observe it, and SwiftUI has no per-property granularity: one published
  mutation re-evaluates every observing body. Selection, preview text/size and
  search text live in `Services/UIState.swift` for exactly this reason.
- **`FontItem` decoding must stay tolerant** of both old and new cache layouts
  (`format` as enum rawValue *or* legacy label; absent `displayName`/`panose`).
  Use `decodeIfPresent`, never `try?`, for optional keys — a caught throw per
  key across 78 000 items is measurable.
- **Activation state persistence** uses `activeFontIDs: Set<String>`. On
  bootstrap, `reapplyActivations()` re-registers those URLs so Core Text sees
  them again this session.
- **Cache staleness** is detected in `cacheLooksStale` — if all items have
  `foundry == "Unknown"` the cache predates foundry extraction, so we rescan.
  Same pattern for future schema changes.
- **`Persistence.readOnly`** is a hard write-lock on `saveState` /
  `saveCachedLibrary`. Any code path that builds a `FontLibrary` without going
  through `bootstrap()` — a benchmark, an audit, any future headless CLI tool —
  **must** set it before doing anything else. This exists because `--bench`
  once wrote an empty state over the user's real `state.json` (Session 4,
  commit `0651669`); see that section for the full incident.
- **`state.json` is the only irreplaceable file in this app.**
  `library-cache.json` can always be rebuilt by rescanning; `state.json`
  cannot — it holds scan roots, favorites, projects and variable instances.
  `saveState` backs up the previous file to `StateBackups/state-<epoch>.json`
  (last 30 kept) before every write; treat any code path that can write it as
  dangerous regardless.
- **Duplicate deletion is content-identical, not name-based.** Measured
  against the real library, grouping by PostScript name and offering the
  "extras" for deletion was unsafe — only 66% of same-named groups were
  actually the same font (Session 4, commit `afdee88`). `DuplicateScanner`
  groups only by matching hash (size bucket → 16 KB edge hash → full SHA-256).
  **Don't reintroduce a name-based or metadata-based match as grounds for
  deletion** — only byte-identical files may be offered as removable, and the
  API must take a group plus its keeper so "delete every copy" stays
  inexpressible.
- **Projects and Palettes are one concept now** (`c6ea80a`).
  `FontCollection.Kind.palette` exists **only** to decode old `state.json`
  entries; `bootstrap()` folds any stored palette into `.project` on load.
  Nothing should construct `.palette` going forward.
- **RightFont UUID matching must use `normalizeUUID`** (hyphens stripped,
  uppercased) at every lookup site, not `.uppercased()` alone. Fontlists store
  hyphenated UUIDs; using the wrong normalisation silently drops most of an
  import (was 90/225 fontlists, should be 155/225 on the reference library —
  commit `7dc4330`).
- **CLI entry points must not block the main thread on `Task { … }`.**
  `--scan-duplicates` and `--import-rightfont` do `@MainActor` work reached
  from `SaewooFontApp.init()`, before the run loop is pumping normally.
  Blocking on a semaphore there deadlocks, because the work itself needs the
  main actor to proceed. The existing pattern —
  `while !done.value { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }`
  — keeps the run loop alive long enough for the cooperative thread pool to
  make progress. Follow it for any new headless entry point.

---

## Roadmap — next obvious picks

Re-ranked after Sessions 2 + 3. Top items duplicate the Session 3 "Current
next work" list above (Duplicates backup, list filters, source-lock, the
five cloud follow-ups). Beyond those:

1. **Local cloud-folder picker shortcuts** — different from the Cloud section
   we shipped. The "+" Add Source button could become a menu with
   `Local folder… / Google Drive / Dropbox / iCloud Drive / OneDrive / Other…`
   that pre-navigates `NSOpenPanel` to common File Provider mount points.
   No API integration needed — those are regular folders once the sync app
   has them mounted. Useful for users who keep font archives in cloud sync
   apps.

2. **Waterfall view in Proof Sheet** — render one line at 8–10 different
   sizes (8/10/12/14/18/24/36/48/72/96pt) for comparing rendering at
   different scales. Would slot in as a fourth tab next to Type / Glyphs /
   Coverage.

3. **Source-file support (the hard one)** — Python bridge to
   `fontmake` / `glyphsLib` if the user has them installed, compiling `.ufo` /
   `.glyphs` / `.designspace` on-the-fly to a temp `.otf` for proofing. Would
   enable FontGoggle-level source-file support without writing our own
   parser. Needs: Python discovery, shell helper, temp-file lifecycle, UI
   for "compiled proof" state. Note: the **Fork tool already writes** UFO
   and designspace; this would be the read direction.

4. **Activation-history tool** — track when a font was last activated so an
   "Unused Fonts" tool can surface zombies. Would need a new `@Published`
   map in `LibraryState` keyed by FontItem.id, persisted via Persistence.
   Could become a sixth Tools entry alongside Largest Files.

5. **iCloud / Dropbox sync of state.json** — share Projects across
   machines. Trivial if sync folder is already mounted; harder for
   seamless conflict resolution. Also useful for the Google Fonts catalog
   cache so multiple machines don't each re-fetch.

6. **Recently downloaded** Google Fonts filter — tracks the last 20 families
   downloaded via `GoogleFontsClient` so users can quickly find what they
   just installed. Cheap; lives next to the existing Sort modes.

7. **Settings panel** — there isn't one yet. Will eventually need one for:
   Google Fonts API key (for catalog fallback), default download location,
   activation policy, IME / keyboard accessibility hints. Currently
   everything is implicit / hardcoded.

### Done in past sessions (do not re-add)

- Glyph detail popover in Proof Sheet (`633b379`).
- Cloud section with Google Fonts + Adobe Fonts (`9b56ab3`).
- All keyboard input bugs (resolved by activation-policy fix in `9a74015`).
- Three-tier sidebar with collapsibles (Session 1, plus Cloud added in
  Session 3 making it four-tier).
- Multi-category tags (Session 1, `cb3abb4`).

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
2. `main`에 최신 작업이 병합돼 있는지 확인. 낡은 `work/compB-*` 지침은
   역사 기록으로만 취급.
3. HANDOFF.md "Queued for the next session" 또는 "Roadmap" 섹션에서 내가
   다음 항목을 골라주면 그걸 진행.

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
