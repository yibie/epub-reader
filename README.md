[English](README.md) | [中文](README_cn.md)

# epub-reader

`epub-reader` is a native Emacs reader for DRM-free, reflowable EPUB 2 and
EPUB 3 books. It parses the EPUB container, package, reading order, and table
of contents directly, converts XHTML into semantic blocks, and asks TextUI to
lay those blocks out for the current window.

The result is deliberately more reader-like than a buffer containing rendered
HTML: a centered reading column, automatic reflow, CJK-aware line breaking,
incremental rendering for long chapters, a hierarchical table of contents,
and reading positions that survive changes in window width and text scale.

Version 0.3.1 requires Emacs 29.1 or later. It does not support DRM or
fixed-layout EPUBs.

![Frankenstein in epub-reader: table of contents, reading column, and highlights list](screenshots/reader-frankenstein.png)

![紅樓夢 in epub-reader: grouped table of contents, reading column, and highlights list](screenshots/reader-hongloumeng.png)

Table of contents on the left, reading column in the centre, highlights list
on the right. The texts are *Frankenstein* from Standard Ebooks and 紅樓夢
from Project Gutenberg, both in the public domain.

## How it differs from nov.el

`nov.el` is established, widely packaged, and tested against a much larger
variety of books. It renders one XHTML document at a time with `shr`.
`epub-reader` uses its own publication and position models, then lays out a
small viewport through TextUI. That architectural difference matters most for
reflow, long chapters, and reliable reading positions.

| Area | nov.el 0.5 | epub-reader 0.2.0 |
|---|---|---|
| Rendering | Sends a complete spine document through `shr` | Converts XHTML to semantic blocks and renders a bounded chapter viewport |
| Resizing and text scale | Usually requires another render; buffer positions may move | Reflows automatically and restores the semantic reading position |
| CJK prose | Usable with a carefully assembled `nov-text-width`/visual-line/kinsoku setup | Common line-start and line-end restrictions, language-aware whitespace handling, and non-final-line justification are built in |
| Long or image-heavy chapters | Whole-chapter work can block the UI | Small first paint, on-demand resources, deferred images, and next-chapter prefetch |
| Saved position | Spine index plus a buffer position | Versioned locator with block, source offset, and quote-based fallback |
| Overall progress | Saves the last place, but has no dependable whole-book percentage | Shows a weighted whole-book estimate and reaches 100% at the end |
| Table of contents | Separate TOC view | Hierarchical, collapsible TOC with a current-chapter marker and remembered row |
| Archive handling | Relies on the external extractor | Checks paths, collisions, entry counts, sizes, and compression ratios before extracting members on demand |
| Annotations | No core annotation model; mature third-party workflows such as `org-remark` exist | Built-in bookmarks, highlights, plain-text notes, and chapter-grouped lists |
| Maturity | Mature package with broad real-world coverage and package-archive installation | Young project with extensive ERT and adversarial tests, but a smaller real-book corpus |

Choose `nov.el` when package-archive installation, its surrounding ecosystem,
or years of format-compatibility fixes matter most. Choose `epub-reader` when
you want its reflow, CJK defaults, responsive chapter loading, and stable
locators. Keeping both installed is reasonable.

## Installation

Requirements:

- Emacs 29.1 or later, built with libxml2 support;
- TextUI 0.7.1 or later;
- either `unzip` or `bsdtar` on `exec-path`.

Neither package is in a package archive yet. On Emacs 29.1 or later,
`package-vc-install` installs both straight from GitHub. Install TextUI first
so that `epub-reader` finds its dependency:

```elisp
(package-vc-install "https://github.com/yibie/textui")
(package-vc-install "https://github.com/yibie/epub-reader")
```

Alternatively, clone both repositories and add them to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/textui")
(add-to-list 'load-path "/path/to/epub-reader")
(require 'epub-reader)
```

If opening a book reports that no archive program is available, check one of
these expressions:

```elisp
(executable-find "unzip")
(executable-find "bsdtar")
```

At least one should return a path rather than `nil`.

## Quick start

Open a book with:

```text
M-x epub-reader-open RET /path/to/book.epub RET
```

The reader takes over the frame and shows the book in a centered column;
`q` closes it and brings the previous windows back. Resizing the window or
changing text scale reflows the visible content while keeping the same
semantic position.

Set `epub-reader-open-full-frame` to `nil` to open the book in the selected
window instead. In that mode, `q` closes the reader without removing the
surrounding user windows.

Progress saving is enabled by default. Unless
`epub-reader-store-directory` is set, reading progress, bookmarks, highlights,
and notes are stored beside the book as `BOOK.epub.epub-reader`. The EPUB file
itself is never modified.

## Key bindings

### Reader

| Key | Action |
|---|---|
| `n`, `]` | Next spine chapter |
| `p`, `[` | Previous spine chapter |
| `SPC` | Scroll forward; continue into the next chapter at the end |
| `S-SPC` | Scroll backward; continue at the end of the previous chapter |
| `b`, `f` | Move backward or forward through navigation history |
| `t` | Open the table of contents |
| `g` | Jump to a TOC entry by title |
| `m` | Add a named bookmark at point |
| `M` | Open the bookmark list |
| `h` | Highlight the selected text |
| `e` | View or edit the note on the highlight at point |
| `a` | Open the highlights and notes list |
| `RET` | Follow the internal link at point, or an allowed external link |
| `q` | Save progress, close the reader, and restore the previous window layout |

### Table of contents

| Key | Action |
|---|---|
| `RET` | Visit the current entry; toggle a group that has no destination |
| `TAB` | Collapse or expand the current group |
| `n`, `]` | Visit the next spine chapter and keep focus in the TOC |
| `p`, `[` | Visit the previous spine chapter and keep focus in the TOC |
| `t`, `q` | Hide the panel and return to the reader |

`RET` and mouse activation visit the entry and move focus to the reader.
Reopening the TOC restores its selected row.

### Panel tabs

The TOC, highlights, and bookmarks are three views of one panel buffer. Its
first line is a row of Contents, Highlights, and Bookmarks tab buttons: click
one, or press `RET` on it, to switch views. In every view, `1`, `2`, and `3`
switch to Contents, Highlights, and Bookmarks, and `t`, `a`, and `M` open the
matching view or close it when it is already shown.

### Bookmarks and highlights

Select text within one chapter and press `h` to highlight it. Press `e` while
point is on a highlight to add, read, or edit its plain-text note. The `M` and
`a` list buffers use these keys:

| List | `n` / `p` | `RET` | `d` | `e` | Close |
|---|---|---|---|---|---|
| Bookmarks | — | Jump to the bookmark | Delete it | — | `q` |
| Highlights | Next / previous highlight | Jump to the quoted text | Delete it | Edit its note | `a` or `q` |

Clicking an entry in either list jumps to it, like `RET`.

On graphical Emacs, the TOC, bookmarks, and highlights share one child-frame
panel over the top-right of each reader. Switching views reuses that panel, so
it does not resize or reflow the book. Terminal Emacs uses the same lifecycle
through one managed side/bottom-window fallback. Customize
`epub-reader-panel-display` to force `child-frame`, `side-window`, or `bottom`.
The Contents, Highlights, and Bookmarks tabs on the panel's first line switch
between the views.
Opening the list is also lazy: highlights in chapters you have not visited are
resolved only when you jump to them, and repeated opens reuse cached metadata.
Child frames are inset from the reader edge and re-constrained after their
parent is resized. The inset and border are customizable with
`epub-reader-panel-child-frame-horizontal-margin`,
`epub-reader-panel-child-frame-vertical-margin`, and
`epub-reader-panel-child-frame-border-width`. Child-frame mode lines are
hidden by default; set `epub-reader-panel-show-mode-line` non-nil to show them.
Tab bars and per-window tab lines are always suppressed in child-frame panels.

Notes open in a multiline editor below the reading area. Use `RET` for a new
line, `C-c C-c` to save and close the editor, or `C-c C-k` to discard the
changes. Closing a reader with an unsaved note asks for confirmation.

Highlights are restored from the saved quote when an exact source position is
no longer available. Such a match is shown with a wavy underline and a warning
in the highlights list so that you can review it.

## Customization

Run `M-x customize-group RET epub-reader RET` to browse all options and faces.
The settings most readers are likely to change are:

| Purpose | Options |
|---|---|
| Reading column and images | `epub-reader-reading-width`, `epub-reader-image-rows`, `epub-reader-text-wrap-strategy` |
| Fonts and spacing | `epub-reader-text-scale`, `epub-reader-line-spacing`, `epub-reader-paragraph-spacing` |
| Window layout | `epub-reader-open-full-frame`, `epub-reader-panel-display`, `epub-reader-panel-show-mode-line`, `epub-reader-panel-width`, `epub-reader-panel-height`, `epub-reader-panel-child-frame-horizontal-margin`, `epub-reader-panel-child-frame-vertical-margin`, `epub-reader-panel-child-frame-border-width`, `epub-reader-toc-width`, `epub-reader-list-width`, `epub-reader-reader-min-width`, `epub-reader-side-min-width`, `epub-reader-note-window-height` |
| Initial chapter paint | `epub-reader-first-paint-max-blocks`, `epub-reader-first-paint-max-characters` |
| Cold scrolling | `epub-reader-scroll-chunk-max-blocks`, `epub-reader-scroll-chunk-max-characters` |
| Background work | `epub-reader-background-idle-delay` |
| Long-chapter viewport | `epub-reader-chunk-max-blocks`, `epub-reader-chunk-max-characters`, `epub-reader-chunk-guard-blocks`, `epub-reader-chunk-overscan-screens` |
| Progress saving | `epub-reader-enable-progress`, `epub-reader-save-idle-delay`, `epub-reader-store-directory` |
| Sidecar locking | `epub-reader-store-lock-timeout`, `epub-reader-store-ownerless-lock-grace` |
| External links | `epub-reader-external-link-schemes` (defaults to `http`, `https`, and `mailto`) |
| Locator fallback | `epub-reader-locator-max-synthetic-distance`, `epub-reader-locator-max-synthetic-rows` |
| Archive program | `epub-reader-container-adapters` |
| Archive safety limits | `epub-reader-container-max-entries`, `epub-reader-container-max-files`, `epub-reader-container-max-directories`, `epub-reader-container-max-central-directory-bytes`, `epub-reader-container-max-path-bytes`, `epub-reader-container-max-entry-bytes`, `epub-reader-container-max-total-bytes`, `epub-reader-container-max-compression-ratio`, `epub-reader-container-member-timeout` |

### Fonts, size, and spacing

To change the reading font or its base size, run
`M-x customize-face RET epub-reader-prose-face RET`. Headings inherit that face
and keep their relative sizes. For a temporary size change, use `C-x C-+`,
`C-x C--`, or `C-x C-0`; the reader automatically reflows the text. Set
`epub-reader-text-scale` for the scale applied whenever a book opens,
`epub-reader-line-spacing` for prose line spacing,
`epub-reader-paragraph-spacing` for blank lines between blocks, and
`epub-reader-reading-width` for the column width.

```elisp
(setq epub-reader-text-scale 1
      epub-reader-line-spacing 0.2
      epub-reader-paragraph-spacing 1
      epub-reader-reading-width 72)
```

Emphasis, quotations, code, links, highlights, image messages, reader chrome,
and TOC state also have `epub-reader-*` faces that can be adjusted with
`M-x customize-face`.

## Feature matrix

| Status | Area | Behavior in 0.2.0 |
|---|---|---|
| Supported | EPUB container and publication model | Opens DRM-free, reflowable EPUB 2/3; validates the central directory; extracts metadata, spine documents, and visible images on demand; reads EPUB 2 NCX and EPUB 3 navigation documents |
| Supported | Common XHTML semantics | Paragraphs, headings, emphasis, links, quotations, code, ordered and unordered lists, a text fallback for simple tables, and visible image errors |
| Supported | CJK and reflow | Width-aware layout, common kinsoku rules, non-final-line justification, greedy or balanced break selection, and reflow after width/font/theme/text-scale changes |
| Supported | Long chapters | Small initial and cold-scroll chunks, block and character budgets, keyed incremental region rendering, initial idle expansion, and next-chapter prefetch |
| Supported | Navigation | Previous/next chapter, automatic chapter crossing while scrolling, internal fragments, allowed external links, history, collapsible TOC, and title completion |
| Supported | Progress | Book-fingerprint identity, versioned locators, debounced saves, atomic sidecar merge/write, exact or degraded restoration, and weighted whole-book progress |
| Supported | Bookmarks and annotations | Named bookmarks; continuous highlights within one chapter; plain-text notes; lists for jumping, editing, and deleting; quote-based recovery after reflow or source-map changes |
| Supported | Input safety | OCF path normalization, collision checks, archive count/size/ratio limits, streaming member extraction, remote-resource isolation, and an external-link scheme allowlist |
| Not supported | Restricted and fixed-layout books | DRM, fixed-layout EPUB, vertical writing, and exact pagination |
| Not supported | Rich media and high-fidelity publisher layout | Complex ruby, MathML, general SVG, audio/video, JavaScript, general CSS, embedded publisher fonts, floats, or grid fidelity |
| Not supported | Whole-library services | Indexed full-text search, cross-device sync, EPUB CFI, or Web Annotation interoperability |
| Not supported | Pure-Elisp ZIP | Archive members are still read through `unzip` or `bsdtar` |

## Known limitations

- A highlight cannot cross from one chapter file into another. If a selection
  reaches across that boundary, create a separate highlight in each chapter.
- A chapter containing one enormous paragraph—tens of thousands of characters
  without a paragraph break—has to load that paragraph as one unit. Entering it
  may cause a noticeable pause.
- A very long URL with no legal break point, or an unusually wide glyph, can be
  clipped at the right edge instead of wrapping. Ordinary prose is unaffected.
- The percentage in the header is an estimate based on chapter weights. It
  reaches 100% at the end of the book, but the number between chapters should
  be treated as a guide rather than an exact word-count percentage.
- Progress-file coordination is designed for a local disk. If the book and its
  sidecar live in a cloud-synced folder and the same book is open on two
  computers, their progress can overwrite each other and a save may wait for a
  lock timeout. Opening the same book in multiple buffers on one machine is
  handled.
- If Emacs crashes or is killed, stale lock or temporary entries may remain in
  the progress directory. A later save waits and retries. If every save becomes
  consistently slow, remove old `*.lock`-style leftovers from that directory.

## Development

The test runner rebuilds the minimal EPUB 2/3, CJK, English, mixed-language,
long-chapter, and adversarial fixtures before running the complete ERT suite
in `emacs -Q`:

```sh
./test/run-tests.sh
```

If TextUI is not at the default development path, provide it explicitly:

```sh
TEXTUI_DIR=/path/to/textui ./test/run-tests.sh
```

Use another Emacs executable with `EMACS=/path/to/emacs`. Production modules
must use only TextUI's public API. Before submitting a change, run the full ERT
suite, byte-compile the package, and open at least one text-heavy EPUB for a
read-only smoke test.

## License

epub-reader is released under GPL-3.0-or-later. See [`COPYING`](COPYING).
