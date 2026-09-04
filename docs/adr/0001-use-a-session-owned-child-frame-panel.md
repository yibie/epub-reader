---
status: accepted
date: 2026-09-04
---

# Use a session-owned child frame for the reader panel

EPUB Reader will present its table of contents, annotations, and bookmarks in
one panel host owned by each reader session.  On supported graphical displays
the host is an interactive child frame overlaid at the top-right of the reader
window; on terminals, or when child-frame creation fails, the same panel
interface uses the managed ordinary side/bottom-window adapter.  This keeps the
reader's window dimensions and text layout stable while retaining a portable
fallback.

## Decision

- A reader session owns one panel host.  The host is not a process-wide
  singleton and is never shared between books or reader sessions.
- TOC, annotations, and bookmarks are views of that host.  Switching views
  reuses the host and changes its rendered content instead of creating
  overlapping child frames.
- Every view exposes one shared header with Contents, Highlights, and
  Bookmarks tabs.  The active tab is session state; clicking another tab
  switches through that reader session rather than performing a global buffer
  lookup.
- The child frame is an interactive tool panel, not a tooltip.  Mapping it must
  not steal focus, but an explicit panel-focus operation must allow its
  keybindings to receive input.  It must not unconditionally redirect focus to
  the parent as non-interactive popup packages do.
- The panel handle records the exact originating reader window.  Activating an
  item, closing or hiding the panel, killing its buffer, and leaving a note
  editor must return through that origin when it is still live.  UI code must
  not infer the reader from selected-frame, because the selected frame may be
  the child.
- User toggles hide and reuse the child frame.  Session termination, reader or
  panel-buffer death, parent deletion, an incompatible parent/display change,
  or a failed invariant destroys it.  Hide and destroy are distinct lifecycle
  operations and both are idempotent.
- Ordinary-window presentation obeys the same show, focus, hide/close, live,
  and ownership semantics.  The layout module remains the owner of ordinary
  window placement and removal through injected display and close callbacks.

## Child-frame invariants

Creation is attempted only when the reader's parent is graphical.  Critical
frame parameters are explicit, including parent-frame, a nil parent-id,
initial invisibility, no-focus-on-map, no decorations or bars, no taskbar or
desktop entry, and an unsplittable root window.  The child shares the parent's
minibuffer window.  After creation, frame-parent must equal the requested
parent; otherwise the frame is destroyed and presentation falls back to an
ordinary window.  Clearing parent-id and checking frame-parent prevent a user
default-frame-alist from silently creating a hidden top-level tool frame.

The panel accepts focus only through an explicit operation.  Returning to the
reader explicitly selects the parent frame with native input focus and then
selects the saved reader window.  This is required for older PGTK/Wayland
versions, where deleting a focused child did not reliably restore keyboard
input to its parent.

## Geometry

Child-frame coordinates are pixels relative to the parent frame's native
top-left origin.  Reader window pixel edges determine the anchor, but frame
text, inner, native, and outer dimensions are not interchangeable:
pixelwise set-frame-size sizes the text area, while right alignment depends on
the child's measured outer width and the parent's native area.

The host is initially created hidden from an estimated geometry, shown, then
measured and corrected once.  Subsequent updates cache the last
(x, y, width, height) and avoid unchanged writes.  Geometry is recomputed when
the reader window changes size or position inside its frame, when the parent
frame changes size, and before a hidden host is shown again.  Moving the parent
on the desktop normally carries its children and does not itself require a
desktop-coordinate calculation.

The requested rectangle is clamped to the parent native area.  Most window
systems clip children at the parent edges, although NS is an exception; the
implementation must not depend on that exception.  When a useful panel cannot
fit, it may shrink, hide, or use the ordinary-window fallback.

## Lifecycle and isolation

Every hook, timer, buffer, frame, ordinary window, and callback belongs to one
opaque panel handle.  Teardown first invalidates and unregisters that handle,
then releases the presentation, so recursive frame/window hooks cannot operate
on a half-live panel.  Emacs recursively deletes children before deleting a
parent; a child already being deleted is only invalidated and must not be
deleted recursively a second time.

The reader-buffer kill path destroys its panel without trying to refocus the
dying reader.  The panel-buffer kill path destroys its presentation and, when
the origin is still live, restores that origin.  Injected ordinary close
callbacks are paired with the layout group captured for the same reader
session.  No global lookup may close a role belonging to another session.

## Considered options

- Inserting widgets or overlay strings into the reader buffer was rejected
  because they occupy the character/display layout and can change wrapping,
  row height, scrolling, or source-location behavior.
- An ordinary side window remains the fallback but was rejected as the primary
  graphical presentation because it narrows the reader and reflows the book.
- A Speedbar-style top-level frame was rejected as the primary presentation
  because it participates in the window manager, task switcher, desktops, and
  multi-monitor focus policy.  Speedbar's explicit attached-frame focus model
  is retained as an implementation lesson.
- A process-wide reusable child frame, as used by serial completion popups, was
  rejected because concurrently open books must not steal or close one
  another's panel.
- A no-accept-focus child frame with redirect-frame-focus was rejected because
  TOC and annotation lists require keyboard navigation and editing commands.

## Consequences and verification

The floating panel does not change reader window geometry or reflow text, but
it does cover content and intercept mouse events in its rectangle.  It must be
compact, quickly hideable, and usable without mouse interaction.

Terminal tests must cover the ordinary fallback, paired display/close
callbacks, buffer death, focus restoration, and multiple reader sessions.
Graphical tests or manual checks must cover successful child creation,
frame-parent validation, right/top alignment after mapping, parent resize,
reader-window split/reposition, parent deletion, focused-child deletion on the
oldest supported PGTK, and at least NS plus one X11/PGTK environment.  Child
frame item activation and note editing must prove that they return to the
saved origin rather than searching the current child frame.

## Sources

- [GNU Emacs: Child Frames](https://www.gnu.org/software/emacs/manual/html_node/elisp/Child-Frames.html)
- [GNU Emacs: Frame Layout](https://www.gnu.org/software/emacs/manual/html_node/elisp/Frame-Layout.html)
- [GNU Emacs: Frame Position](https://www.gnu.org/software/emacs/manual/html_node/elisp/Frame-Position.html)
- [GNU Emacs: Frame Size](https://www.gnu.org/software/emacs/manual/html_node/elisp/Frame-Size.html)
- [GNU Emacs: Input Focus](https://www.gnu.org/software/emacs/manual/html_node/elisp/Input-Focus.html)
- [GNU Emacs: Deleting Frames](https://www.gnu.org/software/emacs/manual/html_node/elisp/Deleting-Frames.html)
- [GNU Emacs: Window Hooks](https://www.gnu.org/software/emacs/manual/html_node/elisp/Window-Hooks.html)
- [Emacs frame deletion implementation](https://github.com/emacsmirror/emacs/blob/1de92cc3ec0915d412a531224b504f57ace55cc7/src/frame.c#L2598-L2675)
- [Emacs PGTK focused-child deletion handling](https://github.com/emacsmirror/emacs/blob/1de92cc3ec0915d412a531224b504f57ace55cc7/src/pgtkterm.c#L471-L526)
- [posframe geometry and parent handling](https://github.com/tumashu/posframe/blob/6f89c0acd29306cb2cd023418d18134cfc507800/posframe.el#L413-L586)
- [company-box child-frame ownership](https://github.com/sebastiencs/company-box/blob/c4f2e243fba03c11e46b1600b124e036f2be7691/company-box.el#L316-L371)
- [Corfu child-frame lifecycle and geometry](https://github.com/minad/corfu/blob/4303506204bdf5df8f5e7d1457f6fca465a4da8e/corfu.el#L433-L530)
- [Speedbar focus and presentation modes](https://github.com/emacs-mirror/emacs/blob/9c003435ca3321b2047a89edf28c04138680042e/lisp/speedbar.el#L979-L1208)
