# scss2-mode

Edit CSS and SCSS in Emacs with syntax highlighting, context-aware completion, structural editing, and [emmet2-mode](https://github.com/P233/emmet2-mode) abbreviations. One package provides both **`scss2-mode` and `css2-mode`**.

**The bundled parser is [P233/tree-sitter-scss](https://github.com/P233/tree-sitter-scss), an independent, unofficial grammar.** It is not affiliated with [tree-sitter-grammars/tree-sitter-scss](https://github.com/tree-sitter-grammars/tree-sitter-scss), and the two grammars are not interchangeable. You do not need to install a grammar separately.

## Requirements

- **Emacs 30.1+**, built with Tree-sitter support.
- **A C compiler** available to Emacs (`cc` by default).
- **Python 3 and Git** to build the local package archive below.

Linux and macOS are the current targets. Indented Sass (`.sass`) is not supported.

## Install scss2-mode and emmet2-mode together

The current setup uses local development checkouts of **both this project and native emmet2-mode v2.0.0+**, which is on emmet2-mode's `native-emmet-rewrite` branch until it is released. Older emmet2-mode packages are incompatible. A separate tree-sitter-scss checkout is unnecessary: its sources are already included here.

From your scss2-mode checkout, build one local archive containing both packages:

```sh
cd /path/to/scss2-mode
python3 scripts/package.py --output-dir dist/local-archive \
  --emmet-source /path/to/emmet2-mode
```

If `emacs` is not on your shell's `PATH`, add `--emacs /path/to/emacs` to that command.

This produces a scss2-mode package, an emmet2-mode package, and the archive index. In Emacs, add that archive and install scss2-mode:

```elisp
(require 'package)
(add-to-list 'package-archives
             '("scss2-local" . "/absolute/path/to/scss2-mode/dist/local-archive/"))
(package-refresh-contents)
(package-install 'scss2-mode)
```

**Emacs installs emmet2-mode automatically as a dependency.** You do not need a second installation command or to enable `emmet2-mode` manually. The packages remain separate and are installed through the same archive.

### Open your first file

Open a `.scss` or `.css` file; Emacs selects the corresponding mode.

The included `parser.c` is **generated C source, not a precompiled library**. On first use, Emacs automatically compiles it and `scanner.c` into a native library (`.dylib` on macOS, `.so` on Linux). You need the compiler, but **you do not run compilation commands yourself** or install the Tree-sitter CLI.

Later buffers and Emacs sessions reuse the cached library. A changed parser snapshot or platform triggers a new build. This package does not currently ship prebuilt native libraries.

If your configuration explicitly selects a built-in mode, add these remappings and reopen the file:

```elisp
(add-to-list 'major-mode-remap-alist '(css-mode . css2-mode))
(add-to-list 'major-mode-remap-alist '(css-ts-mode . css2-mode))
(add-to-list 'major-mode-remap-alist '(scss-mode . scss2-mode))
```

## Everyday editing

- **Expand declarations:** inside a rule such as `.card { }`, type `m10` and run `M-x scss2-expand` to insert `margin: 10px;`. You can also choose Emmet candidates through completion; point starts at the value without selecting it. SCSS supports forms such as `p$gutter`.
- **Complete at point:** run `M-x completion-at-point`, or use a frontend such as Corfu. `M-x emmet2-complete` explicitly requests Emmet candidates.
- **Complete values and syntax:** get at-rules, property values, CSS functions, pseudo-selectors, media queries, local import paths, and custom properties in `var()`. SCSS also offers visible variables, functions, mixins, named arguments, and direct local module members.
- **Use fuzzy matching:** for example, `display: ib` offers `inline-block`. Matching is the `scss2` completion style, registered as the default for the `scss2` completion category; it also decodes CSS escapes and treats Sass `_` and `-` alike.
- **Leave values with TAB:** from anywhere in a property value, TAB jumps directly past that declaration's `;`, including inside nested functions, strings, URLs, and snippet fields. An open value-completion menu closes without accepting a candidate. Without a reliable, accessible semicolon, TAB keeps its existing behavior. Elsewhere TAB retains completion, indentation, or snippet navigation.
- **Keep familiar editing behavior:** built-in CSS/SCSS indentation, comment commands, and standard Emacs faces remain available.

Property names use Emmet declaration expansion, with no separate property-name completion. Existing declaration names do not expand over their values. Class, ID, and tag names are outside the completion scope; ordinary text in comments and strings stays opaque.

Both completion paths use your existing frontend. This package does not change its timing, fonts, or popup settings. To match with your own styles instead, override the category:

```elisp
(add-to-list 'completion-category-overrides '(scss2 (styles basic partial-completion)))
```

Selector prefixes such as `.`, `#` and `::` share the selector's face. Numbers
and units use distinct number and type faces; expression operators use the
property-value face. Variables, functions, strings and comments keep their own
faces. Colors follow the active theme's standard CSS and Font Lock faces.

For lower highlighting memory in large files, set this before opening buffers:

```elisp
(setq scss2-fontify-details nil)
```

This leaves numbers, operators, brackets and delimiters without separate faces.
Names, keywords, strings, comments and escapes remain highlighted; parsing,
completion and structural editing are unchanged. The default is full highlighting.
Reopen existing buffers after changing this option to free their old highlighting
intervals. The option reduces highlighting memory, not the syntax tree's memory.

After 30 seconds of idle time, buffers not displayed in any frame release their
syntax trees and highlighting. Text and undo history stay intact; the next syntax
request or redisplay rebuilds the needed data, so returning to a large file can
take longer. Set `scss2-idle-release-delay` to `nil` to keep these resources, or
customize its idle delay. Active completion sessions, indirect buffers and their
base buffers, and parsers with custom ranges or notifiers are left alone.

### Commands and key bindings

TAB uses `scss2-tab` in both modes. Other commands have no default bindings;
run them with `M-x` or bind them in `scss2-mode-map` and `css2-mode-map`.

| Command | Action |
| --- | --- |
| `scss2-tab` | Jump past the current value's semicolon; otherwise use the existing TAB command |
| `scss2-kill` | Kill the nearest statement, selector branch, argument, or value item |
| `scss2-empty` | Clear content, keeping its container |
| `scss2-substitute` | Replace content with the current kill |
| `scss2-copy` | Copy the semantic target |
| `scss2-duplicate` | Duplicate a statement or item with its separator |
| `scss2-mark` | Select the target |
| `scss2-zap` | Delete from point to the content's end without changing the kill ring |
| `scss2-kill-block` | Kill a block and its header |
| `scss2-empty-block` | Clear a block, keeping its header and braces |
| `scss2-kill-selector` | Kill one complete selector branch |
| `scss2-kill-property` | Kill a property or variable declaration |
| `scss2-empty-value` | Clear a declaration's value and flags |
| `scss2-kill-value-item` | Kill one value, argument, parameter, or map entry |
| `scss2-expand` | Expand a declaration abbreviation |

Optional example; choose any keys you prefer:

```elisp
(with-eval-after-load 'scss2-mode
  (keymap-set scss2-mode-map "C-c e" #'scss2-expand))

(with-eval-after-load 'css2-mode
  (keymap-set css2-mode-map "C-c e" #'scss2-expand))
```

A target is a whole statement or one item of a sequence: a value, argument, parameter, map entry, or selector branch. A quoted key or value belongs to its entry, and `!important` and Sass flags stay with their declaration. Point must touch the target: blank space, a comma, or a flag selects nothing, while a name or delimiter stands for its owner. A target that fills whole lines takes those lines with it.

Block deletion includes dependent `else` branches. A rule keeps its last selector, a variable its only value, and a `with` clause its only variable; remove the whole statement, or clear the value with `scss2-empty-value`. Arithmetic operands stay together, and strings, URLs, and raw custom-property values retain their boundaries.

Deleting a comment preserves adjacent value tokens. The first argument of CSS `var()` cannot be removed; remove the whole call instead. Statement duplication follows the surrounding line ending, including literal CRLF.

Each edit is atomic. Failed edits restore text, point, selection, and the kill ring. Incomplete or ambiguous boundaries are rejected. Clearing content may intentionally leave unfinished text such as `color: ;`. See the [known structural edge cases](docs/architecture.md#decisions-and-remaining-debt).

## Settings

| Setting | Purpose |
| --- | --- |
| `scss2-enable-emmet` | Set to `nil` to disable abbreviations while keeping semantic completion |
| `scss2-idle-release-delay` | Idle seconds before releasing invisible buffers' derived data; default 30, `nil` disables |
| `css-indent-offset` | Set the indentation width |
| `css-fontify-colors` | Control CSS color previews |
| `scss2-grammar-cache-directory` | Choose where locally compiled parser libraries are stored |

The parser cache defaults to `user-emacs-directory/tree-sitter/scss2-mode/`. Set the `CC` environment variable if Emacs should use a compiler other than `cc`; its value must name an executable, without compiler flags. Once installed and built, editing works offline without Node, Deno, or a background service.

## Current limits

- Module completion reads unsaved edits in open local `@use` files. It does not follow `@forward` re-exports, package/load-path importers, or a complete built-in module catalog.
- Completion has known edge cases with existing call/argument delimiters, import-path replacement, nested Sass contexts, and matching during an active session.
- If you clear `completion-category-defaults` or override the `scss2` category, your own styles match raw spellings: escaped queries such as `i\62` and Sass `_`/`-` equivalence then find nothing.
- Escaped keywords are treated as ordinary names, and some advanced CSS syntax, such as typed `attr()` unions, remains incomplete. Highlighting alone does not establish a safe structural edit range.
- Large symbol tables and deeply nested queries can affect responsiveness. Batch checks do not measure GUI input latency.
- Company supports semantic value selection, but the current Emmet2 dependency rejects its read-only CAPF probe and does not enter function parentheses after Company acceptance. Emmet choices and function cursor placement need fixes in that dependency. Orderless works with the default `scss2` category; overriding the category uses raw spellings as described above.

## Development

<details>
<summary>Source loading, checks, packaging, and parser updates</summary>

For source loading, add both checkouts to `load-path` and require `scss2-mode`. Keep this package's `vendor/` and emmet2-mode's `data/` directories alongside their Lisp files.

| Library | Owns |
| --- | --- |
| `scss2-grammar` | Building and loading the bundled parser |
| `scss2-syntax` | Buffer parser setup and shared grammar interpretation: fields, identities, ranges, recovered scopes |
| `scss2-context` | One ordered classifier for node roles and unfinished statement context |
| `scss2-completion` | Candidate discovery, Sass scopes, local modules and name identity for shared semantic tables |
| `scss2-edit` | Structural commands over sequence items and statements |
| `scss2-emmet` | The host side of emmet2-mode's context provider |
| `scss2` | Mode composition, completion dispatch, highlighting and navigation |

A grammar rule that two features need lives in `scss2-syntax`; a feature keeps only the type tables it alone uses. Completion tables stay plain prefix tables, and matching belongs to the completion style.

See [architecture and subsystem contracts](docs/architecture.md) for ownership, data flow and development boundaries.

```sh
SCSS2_EMMET2_DIR=/path/to/emmet2-mode make check
make package
```

`make check` validates the bundled sources, strictly compiles the package, checks subsystem independence, and runs the same full ERT suite against source and an isolated installation with real emmet2-mode. For focused work, `make test-core` needs no Emmet checkout; `make test-semantic` uses only its data/matching libraries. It does not touch your installed packages. `make package` builds a tar from tracked runtime files and resources and rejects dirty or unverified parser snapshots; newly added runtime files must be tracked. It does not publish anything. Direct development archives allow dirty snapshots; use `scripts/package.py --release` to apply the release check.

Make defaults to the sibling `../emmet2-mode` working checkout, including its local changes. Set `SCSS2_EMMET2_DIR` to use another local checkout. Rebuild the local archive with `--emmet-source` after updating Emmet2; package versions come from the checkouts' Lisp headers, so newer local code can still advertise `2.0.0`.

Optional benchmarks and Corfu/YAS integration checks:

```sh
emacs -Q --batch -L . -L /path/to/emmet2-mode -l scripts/benchmark-completion.el
EMMET2_TEST_DEPS=/path/to/emmet2-test-deps emacs -Q --batch -L . \
  -l /path/to/emmet2-mode/test/bootstrap.el -l scripts/test-corfu.el
```

Corfu checks use emmet2-mode's pinned test dependencies and cover typing, selection, value fields, handoff, and undo, with popup drawing excluded. Compare benchmarks using the same Emacs version and separate byte-compiled source copies.

Optional Company/Orderless checks (currently expose the two dependency failures above):

```sh
emacs -Q --batch -L . -L /path/to/emmet2-mode \
  -L /path/to/company-mode -L /path/to/orderless -l scripts/test-frontends.el
```

Generate and test parser changes in the grammar project, then import the complete snapshot:

```sh
python3 scripts/vendor-parser.py --source /path/to/tree-sitter-scss
SCSS2_EMMET2_DIR=/path/to/emmet2-mode make check
```

Do not patch generated vendor files independently. The manifest records imported content, including uncommitted changes. Releases should use a committed snapshot and an installable emmet2-mode dependency.

CI targets Linux/Emacs 30.1 and macOS/Emacs 30.2. Set the GitHub repository variable `SCSS2_EMMET2_REVISION` to the full 40-character commit SHA of a published compatible Emmet2 checkout containing `emmet2-completion.el` and `emmet2-css-value.el`. CI fails before setup if that pin is absent. Passing local checks does not imply passing hosted CI.

</details>

## License

GPL-3.0-or-later, as with emmet2-mode. The bundled parser retains its MIT license. CSS data and its licenses (MIT for VS Code Custom Data, CC0-1.0 for MDN data) belong to the separately installed emmet2-mode package.
