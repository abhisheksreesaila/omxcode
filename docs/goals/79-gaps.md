# Goal 79: what the web app has that the native one doesn't (the everyday gaps)

Continuation 20, 2026-11-24 (01:10). Walked in the code, not from memory: Personal
Note's markup and every key handler, menu, button and drop target in `src/main.js`, `src/page/`, `src/mindmap/`,
`src/modules/`, its services (`services.py`, `routes.py`) and its Mac menu (`desktop_menu.py`), against
`examples/pnote/webshell.mojo`, `mojoui/pagesheet.mojo`, `pagedesk.mojo` (BoardTools), `buzanmap.mojo`, `notesshell.mojo`,
`islandcard.mojo`, `settingswin.mojo`, `omnibar.mojo`. Nothing of the web's was run for this list. "Component" = does mojoui
have the generic piece already. Size: S (hours), M (a day), L (more). **State** is kept up to date as they are built.

## Getting started

| # | Gap | What the web does | Component in mojoui | Size | State |
|---|---|---|---|---|---|
| 1 | The packaged app opens goal 74's look on its own store | one look; notes in `~/.local/share/personal-note` (Mac: Application Support) | yes (the web look itself); a notes file with Personal Note's schema isn't made | S | |
| 2 | An empty database shows an empty screen | makes a canvas note, opens it | yes | S | |

## Notes

| # | Gap | What the web does | Component | Size | State |
|---|---|---|---|---|---|
| 3 | Quick note (the panel's button, Alt+N) | a canvas note "Untitled note" in the Inbox, opened | button yes, row insert with its change log: RowSave only updates | S | |
| 4 | New page / New canvas / New mind map (omnibar actions; hold the button for a menu) | as 3 with that kind, in the selected notebook | yes (omnibar rows); hold-menu: menus.mojo | S | |
| 5 | "Create …" when a search finds nothing | a canvas note with that title | yes | S | |
| 6 | Delete a note (properties card → Delete note) | gone from the list at once, a toast with Undo for 8 s, then the row deleted | confirm/toast: mojoui.letgo, overlays; the web-look toast isn't drawn | M | |
| 7 | Move a note to a notebook (properties card; drag a row onto a notebook) | menu of notebooks; drag and drop with a drop line | dragdrop.mojo, menus.mojo; the web look's menu isn't drawn | M | |
| 8 | New notebook, rename, colour, icon, category, delete (its notes return to the Inbox), drag between shelves | inline namer, dialog | no (namer in the panel) | M | |
| 9 | A notebook in the panel opens to its notes; click one | its rows under it, folded state kept | yes, the panel draws the count only | S | |
| 10 | Change a note's icon (emoji picker) | picker with search and tints | no (an emoji grid) | M | |
| 11 | "Save a copy" when another app changed the note (review 3) | the web merges (pages: text merge; canvases: object merge) | docstore holds the edits; no copy or merge | M | |
| 12 | Changes made by another app (or the web) show without reopening | a change feed is polled (workspace_changes) | watch.mojo; no merge into an open note | M | |
| 13 | Secure notes: unlock, make secure, ordinary again | passphrase / Touch ID, sealed words | no | L | |
| 14 | Backups and exports (JSON, Markdown zip, Obsidian vault, PNG of a note), import | menu entries | png.mojo; no zip of Markdown | M | |
| 15 | Print preview and printing | pages, A4/Letter, the system's print | no | L | |
| 16 | Links between notes (a card on a canvas, `[[ ]]` in a page, backlinks) | drop or pick a note; a click opens it | no | L | |

## Pages

| # | Gap | What the web does (CodeMirror: defaultKeymap, historyKeymap, indentWithTab, line wrapping) | Component | Size | State |
|---|---|---|---|---|---|
| 17 | **Long lines don't wrap**: they run off the sheet | wraps at the sheet's width | TextEdit wraps; PageSheet draws a line as one run | M | |
| 18 | **The page doesn't scroll** (wheel, and the caret leaves the window) | scrolls, the caret kept in view | TextEdit; not in PageSheet | S | |
| 19 | Selection: Shift+arrows, drag, double-click a word, triple-click a line, Ctrl+A; typing over it | all of them | TextEdit (the model), PageSheet doesn't use it | M | |
| 20 | Up, Down, PageUp, PageDown, Ctrl+arrows by word, Ctrl+Home/End, Shift+Home/End | all | TextEdit | M | |
| 21 | Copy, cut, paste (paste only arrives from the host's paste event) | all | Clipboard view, PASTE event | S | |
| 22 | Undo, redo (Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y), words and ink in one history | CodeMirror history | history.mojo | M | |
| 23 | Tab indents, Shift+Tab outdents; Enter continues nothing (the web's neither) | indentWithTab | no | S | |
| 24 | Ctrl+Backspace/Delete by word, Alt+Up/Down moves a line, Ctrl+D etc. | defaultKeymap | TextEdit has words | S (words), M (lines) | |
| 25 | Find in the page | none of its own: the browser's Ctrl+F | no | M | |
| 26 | Task boxes, links, strikethrough, tables, code blocks styled | Markdown highlighting; tasks tick | mdedit.mojo draws them | M | |
| 27 | "Page N" marks where paper breaks, the sheet grows | drawn | no | S | |
| 28 | The page's Red, Highlighter, Eraser, Rectangle, Ellipse and Text tools; ink already in a page isn't drawn | all draw; ink shown | pen marks only; **saved ink is kept but not shown** | M | |
| 29 | Spellcheck | the browser's | no | L | |

## Canvas

| # | Gap | What the web does | Component | Size | State |
|---|---|---|---|---|---|
| 30 | Ctrl+A, arrow nudges (1 px, Shift 10), Escape clears, Ctrl+[ ] (Shift: to the end) reorder, Ctrl+Shift+L lock, Ctrl+Y, Space pans while held | all | ObjectLayer has selection, move, order, lock? (see state) | S | |
| 31 | Copy, cut, paste, duplicate objects | the web has none (paste: pictures only) | — | — | not a gap |
| 32 | Caret inside canvas text (arrows, selection, copy/paste, undo, IME) | a textarea | the box edits at its end only | M | |
| 33 | Double-click empty page makes a text there; double-click text edits it | both | tap with the Text tool only | S | |
| 34 | Resize handles and rotation of a selected object | Leafer's editor | not in the web look | M | |
| 35 | Tools in the dock: hand, highlighter, connect, image, prettify by the + flyout; hold for colours and widths | flyout, ink options popover | tools exist by key (h, m, c); flyout and options not drawn | M | |
| 36 | Pictures: import, drop, paste | media library | picture.mojo, dragdrop; not in the web look's store | M | |
| 37 | Selection bar: back, forward, lock, link to words, delete | five buttons | drawn? (delete by key only) | S | |
| 38 | Reset to 100 % on the zoom number; fit all pages; keyboard panning | all | fit yes, reset not wired | S | |
| 39 | Typography card (family, size of a text) | properties card | no | M | |
| 40 | Link objects to words (fold, unfold), Fold all | yes | no | L | |
| 41 | Voice notes, Speak, Jam, agents (Ask, agent edits with Undo) | plugins | no | L | |

## Mind map

| # | Gap | What the web does | Component | Size | State |
|---|---|---|---|---|---|
| 42 | A click selects an idea; drag moves it; double-click renames | all | mindmap.mojo has them; BuzanMap here has none | M | |
| 43 | Delete, undo, redo (Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y) | yes | history.mojo | M | |
| 44 | Wheel zoom, drag to pan, Fit | yes | no camera in BuzanMap | M | |
| 45 | Side actions: image, import, export JSON/PNG, clean, fit; inspector (colour, size, bold, curve, due, tags, notes); to-dos; reminders | yes | drawn only | L | |

## Shell

| # | Gap | What the web does | Component | Size | State |
|---|---|---|---|---|---|
| 46 | Ctrl/⌘+K opens and closes search | yes | yes | S | |
| 47 | Escape closes the panel, menus, cards in the web's order | yes | partly (card, settings, search) | S | |
| 48 | Omnibar: actions run (New…, Open settings, Switch skin); pills filter (click, Tab); click a row; notebooks, words inside notes, by meaning | all | rows drawn; only notes open, with Enter | S (actions, clicks), M (words), L (meaning) | |
| 49 | Settings: nine pages (general, skins, plugins, AI, sync, storage…) | all work | the skins page only | L | |
| 50 | Title island: the card's other actions (focus, print, picture, backup, icon, link, properties, clear) | all | rename, properties→settings | S each; focus M | |
| 51 | Focus mode (Ctrl+.) | yes | no | M | |
| 52 | Menus on the Mac (File, Edit, View, Window, Help), with ⌘ shortcuts | pywebview's native menu | menus.mojo; the app has none in the web look | M | |
| 53 | Folded shelves and the open panel are remembered | yes | settings (read_setting) | S | |
| 54 | Double tap Ctrl switches writing and the pen | yes | no | S | |
| 55 | Speed meter, speed test | yes | meter.mojo | S | |
| 56 | Phone layout | yes | not in this goal | L | |
