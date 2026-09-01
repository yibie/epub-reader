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

Version 0.1.0 requires Emacs 29.1 or later. It does not support DRM or
fixed-layout EPUBs.

## How it differs from nov.el

`nov.el` is established, widely packaged, and tested against a much larger
variety of books. It renders one XHTML document at a time with `shr`.
`epub-reader` uses its own publication and position models, then lays out a
small viewport through TextUI. That architectural difference matters most for
reflow, long chapters, and reliable reading positions.

| Area | nov.el 0.5 | epub-reader 0.1.0 |
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
- TextUI 0.5.1;
- either `unzip` or `bsdtar` on `exec-path`.

At this stage, install both TextUI and `epub-reader` from local checkouts and
add them to `load-path`:

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

The reader opens in a centered column. Resizing the window or changing text
scale reflows the visible content while keeping the same semantic position.

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
| `q` | Save progress and close the reader |

### Table of contents

| Key | Action |
|---|---|
| `RET` | Visit the current entry; toggle a group that has no destination |
| `TAB` | Collapse or expand the current group |
| `q` | Hide the TOC buffer |

Reopening the TOC restores its selected row.

### Bookmarks and highlights

Select text within one chapter and press `h` to highlight it. Press `e` while
point is on a highlight to add, read, or edit its plain-text note. The `M` and
`a` list buffers use these keys:

| List | `RET` | `d` | `e` | `q` |
|---|---|---|---|---|
| Bookmarks | Jump to the bookmark | Delete it | — | Hide the list |
| Highlights | Jump to the quoted text | Delete it | Edit its note | Hide the list |

Highlights are restored from the saved quote when an exact source position is
no longer available. Such a match is shown with a wavy underline and a warning
in the highlights list so that you can review it.

## Customization

Run `M-x customize-group RET epub-reader RET` to browse all options and faces.
The settings most readers are likely to change are:

| Purpose | Options |
|---|---|
| Reading column and images | `epub-reader-reading-width`, `epub-reader-image-rows`, `epub-reader-text-wrap-strategy` |
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

Body text, headings, emphasis, quotations, code, links, highlights, image
messages, reader chrome, and TOC state all have `epub-reader-*` faces. Use
`M-x customize-face` to adjust them.

## Feature matrix

| Status | Area | Behavior in 0.1.0 |
|---|---|---|
| Supported | EPUB container and publication model | Opens DRM-free, reflowable EPUB 2/3; validates the central directory; extracts metadata, spine documents, and visible images on demand; reads EPUB 2 NCX and EPUB 3 navigation documents |
| Supported | Common XHTML semantics | Paragraphs, headings, emphasis, links, quotations, code, ordered and unordered lists, a text fallback for simple tables, and visible image errors |
| Supported | CJK and reflow | Width-aware layout, common kinsoku rules, non-final-line justification, greedy or balanced break selection, and reflow after width/font/theme/text-scale changes |
| Supported | Long chapters | Small initial and cold-scroll chunks, block and character budgets, viewport overscan, idle expansion, and next-chapter prefetch |
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
