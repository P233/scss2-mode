# scss2-mode

Edit CSS and SCSS in Emacs with syntax highlighting, context-aware completion, structural editing, and [emmet2-mode](https://github.com/P233/emmet2-mode) abbreviations. One package provides both **`scss2-mode` and `css2-mode`**.

**The bundled parser is [P233/tree-sitter-scss](https://github.com/P233/tree-sitter-scss), an independent, unofficial grammar.** It is not affiliated with, or interchangeable with, [tree-sitter-grammars/tree-sitter-scss](https://github.com/tree-sitter-grammars/tree-sitter-scss), and you do not install a grammar separately.

Parsing and highlighting target complete CSS/SCSS files. A statement being typed usually stays one local error, so the rules after it keep their colors and structural commands; the unfinished construct itself is best effort and refuses structural edits until it is repaired.

## Requirements

- **Emacs 31.1+**, built with Tree-sitter support.
- **A C compiler** available to Emacs (`cc`, or the `CC` environment variable).
- **emmet2-mode 2.0.0**, installed as a dependency. It is unreleased: use its `main` branch at or after the commit pinned in [`.github/workflows/check.yml`](.github/workflows/check.yml). Older emmet2-mode packages are incompatible.
- **Python 3 and Git** to build the local package archive, when not installing with straight.el.

CI runs on Linux and macOS. Indented Sass (`.sass`) is not supported.

## Install

With straight.el and use-package, declare emmet2-mode first so straight knows its recipe; **you do not enable `emmet2-mode` yourself**:

```elisp
(use-package emmet2-mode
  :straight (emmet2-mode :type git :host github :repo "P233/emmet2-mode"
                         :files (:defaults "data")))
(use-package scss2-mode
  :straight (scss2-mode :type git :host github :repo "P233/scss2-mode"
                        :files (:defaults "vendor")))
```

Without straight.el, build one local archive from your scss2-mode checkout containing both packages (add `--emacs /path/to/emacs` if `emacs` is not on `PATH`):

```sh
python3 scripts/package.py --output-dir dist/local-archive \
  --emmet-source /path/to/emmet2-mode
```

Then add the archive and install scss2-mode; **Emacs installs emmet2-mode automatically**, and you do not enable `emmet2-mode` yourself:

```elisp
(require 'package)
(add-to-list 'package-archives
             '("scss2-local" . "/absolute/path/to/scss2-mode/dist/local-archive/"))
(package-refresh-contents)
(package-install 'scss2-mode)
```

Rebuild the archive after updating either checkout. Versions come from the Lisp headers, so newer local code can still advertise the same version.

Open a `.scss` or `.css` file and Emacs selects the matching mode. If your configuration explicitly selects a built-in mode, remap it and reopen the file:

```elisp
(add-to-list 'major-mode-remap-alist '(css-mode . css2-mode))
(add-to-list 'major-mode-remap-alist '(css-ts-mode . css2-mode))
(add-to-list 'major-mode-remap-alist '(scss-mode . scss2-mode))
```

The parser ships as C source. On first use, Emacs compiles it into a native library in `scss2-grammar-cache-directory`; there is no build command to run, Tree-sitter CLI, download, Node, or background service. Later sessions reuse the library; changed parser sources or another platform build a new one, while an update to the highlighting queries alone does not.

A buffer larger than `treesit-max-buffer-size`, or a parser that cannot be built or loaded (for example, without a C compiler), shows a warning and keeps the dialect's syntax, comment commands, indentation and comment and string highlighting; your mode hooks still run.

## Everyday editing

- **Expand declarations:** inside `.card { }`, type `m10` and run `M-x scss2-expand` to get `margin: 10px;`. Bracket values may contain blanks (`p[1px 2px]`, `w[calc(100% - 2rem)]`); SCSS also accepts `p$gutter` and `p$a$b$c`. Completion offers these expansions as Emmet candidates.
- **Complete at point** with `M-x completion-at-point` or a [frontend](#frontends); `M-x emmet2-complete` requests Emmet candidates only. Completion covers at-rules, property values, CSS functions, pseudo-selectors, media queries, local import paths, and custom properties in `var()`; SCSS adds visible variables, functions, mixins, named arguments, and members of local `@use` modules. Property names come only from Emmet expansion; class, ID, and tag names, and ordinary text in comments and strings, are not completed.
- **Fuzzy matching:** `display: ib` offers `inline-block`. The `scss2` style, the default for the `scss2` completion category, also decodes CSS escapes and treats Sass `_` and `-` alike.
- **Move through declarations with TAB:** in a property or variable name, TAB jumps to the first character of its value; anywhere in the value, including nested functions, strings, URLs, and snippet fields, it jumps past the declaration's `;`. Both close an open completion menu without accepting it. Elsewhere, or without a value or an accessible `;`, TAB keeps its usual behavior.
- **No `css-mode` underneath:** the modes neither load nor run Emacs's `css-mode`. They supply their own comment syntax, comment filling, color previews and indentation, which nests by `scss2-indent-offset`, follows a block's existing indentation, and indents continued values and selectors as Prettier does; EditorConfig's `indent_size` sets `scss2-indent-offset`, and `css-indent-offset` is not read. `derived-mode-p` still matches `css-mode` in both modes and `scss-mode` in `scss2-mode`, but those modes' hooks and key bindings do not apply; use `scss2-mode-hook`, `css2-mode-hook` and their maps. Highlighting uses Font Lock faces, plus `scss2-selector` and `scss2-property`, so themes own the palette.

To match with your own styles, override the category. Your styles then match raw spellings, so escaped queries such as `i\62` and Sass `_`/`-` equivalence find nothing:

```elisp
(add-to-list 'completion-category-overrides '(scss2 (styles basic partial-completion)))
```

In a narrowed buffer, completion and commands read the whole syntax tree, as Font Lock does, but act only inside the restriction ([details](docs/architecture.md#narrowing-and-the-shared-parser)).

### Structural commands

TAB runs `scss2-tab` in both modes. The other commands have no default bindings; run them with `M-x` or bind them in `scss2-mode-map` and `css2-mode-map`.

| Command | Action |
| --- | --- |
| `scss2-kill` | Kill a selector branch, complete declaration, leaf statement such as `@include foo;`, or at-rule block |
| `scss2-empty` | Clear the nearest `()` / `[]` / `{}` / `#{}` interior, string contents, declaration, map entry or `@return`-style value, or `@if` condition |
| `scss2-copy` | Copy the same entity as kill |
| `scss2-comment-uncomment` | Comment the entity, or uncomment the comment at point (one `//` line at a time) |
| `scss2-duplicate` | Duplicate the entity with its comma or statement separator |
| `scss2-mark` | Select the entity; repeated calls keep the selection |
| `scss2-avy-word` | Jump to a word inside the invocation's complete rule or at-rule block |
| `scss2-expand` | Expand a declaration abbreviation |

`C-u` selects the nearest complete structural block for kill, copy, comment,
duplicate and mark, including its header and any `@else` branches. For empty,
`C-u` clears only the nearest block's body (the current conditional branch).
On a `//` comment, `C-u` uncomments its whole run of adjacent `//` lines, such
as a block commented with `C-u`.
A declaration includes its complete multiline value, flags and terminator;
arguments, parameters and map entries are not separate entities; empty clears
a map entry's value.

Avy is optional: install [Avy](https://github.com/abo-abo/avy) to use
`scss2-avy-word`. Its range is the nearest complete rule or at-rule at invocation,
including the header and nested blocks, rather than the visible window range.
Nested property bodies and raw value containers do not narrow that range.
Candidates stay in the invoking window; label display follows Avy's usual behavior.

```elisp
(with-eval-after-load 'scss2-mode
  (keymap-set scss2-mode-map "C-c e" #'scss2-expand))
(with-eval-after-load 'css2-mode
  (keymap-set css2-mode-map "C-c e" #'scss2-expand))
```

Entity commands require point on an entity, including whitespace inside it.
Blank space between statements and blank lines inside a value select nothing;
use `C-u` to select a containing rule explicitly.
Selector branches include nested pseudo-class selectors. Killing or commenting
the only branch is rejected: select the whole rule with `C-u`. Comments between
a killed branch and its comma remain in place. Empty stops at a comment or at
a leaf statement it does not clear, such as `@extend` or `@include` outside
its arguments, and reports that there is nothing to empty instead of clearing
the enclosing block; blank space in a block clears its body. Empty can
intentionally leave an unfinished value or condition. Each mutation is one undo step; incomplete
input boundaries are rejected, and a failed edit restores text, point, selection
and the kill ring. See the [structural edge cases](docs/architecture.md#decisions-and-known-limits).

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `scss2-enable-emmet` | `t` | `nil` disables abbreviations and keeps semantic completion |
| `scss2-fontify-details` | `nil` | `t` also highlights numbers, commas, and member dots, which many themes, including Emacs's default, show plain; `nil` saves about 15% of highlighting memory. Units and operators are always highlighted, and brackets, `:`, and `;` never; set it before opening buffers |
| `scss2-idle-release-delay` | `30` | Idle seconds before buffers shown in no window release their syntax trees and highlighting, keeping text and undo; `nil` keeps everything |
| `scss2-grammar-cache-directory` | `tree-sitter/scss2-mode/` in `user-emacs-directory` | Where the compiled parser is stored |
| `CC` (environment) | `cc` | Compiler command, split like a shell command: `ccache cc` and `cc -m64` work; quote a path containing spaces |
| `scss2-indent-offset` | `2` | Indentation width |
| `scss2-fontify-colors` | `t` | Show hex colors, color names and literal `rgb()`/`hsl()` on their own color; set it before opening buffers |

Idle-released data is rebuilt on next use, so returning to a large file can take longer.

## Frontends

Corfu is the supported frontend. Company works through standard `completion-at-point`, including semantic value choices and Emmet declaration choices; after Company accepts a function value such as `calc()`, point stays after the parentheses, where Corfu places it inside. This is a documented frontend difference. Orderless works with the default `scss2` category.

## Current limits

- Module completion reads local `@use` files, including unsaved edits in open buffers. It does not follow `@forward`, so a module that only forwards offers no names. Unqualified variables, functions, and mixins come only from the current file, not from `@import`ed files.
- Built-in modules such as `sass:math`, package or load-path modules, and import paths with a scheme or without a local directory are left to other completion functions. Elsewhere semantic completion is exclusive: other completion functions do not run there, even without a match.
- Inside a nested property such as `font: { weight: bold; }`, values complete under the full name (`font-weight`), but names are not completed: Emmet writes whole names, which Sass would prefix again. When the stylesheet ends inside an unclosed block, a nested property's outer names can be lost, so values may use a partial name and Emmet may offer whole names.
- Some unfinished code completes poorly, such as `var(` inside unclosed `@include` arguments, or an unclosed media group followed by another condition.
- Parser limits ([full list](https://github.com/P233/tree-sitter-scss#known-limits)): escaped keywords such as `@m\65 dia` are read as ordinary names, and typed `attr()` unions such as `type(<length> | <percentage>)` do not parse.
- In a media or container query, a feature name continued by interpolation, as in `(max-#{$side} > 1px)`, colors as a value rather than a property.
- Internet Explorer–only syntax is not supported: the `*` property hack, `alpha(opacity=50)` arguments, `progid:` filters and `expression()` parse as local errors.
- A last rule left open after a complete declaration, as in `.a { color: red;` at the end of the file, makes the whole file one parse error, so structural commands stop until `}` is typed; `electric-pair-mode` inserts it with `{`.
- Each open buffer keeps a syntax tree of tens of bytes per source byte, so several large files use noticeably more memory than `scss-mode`; buffers shown in no window release it after `scss2-idle-release-delay`.

## Development

<details>
<summary>Source loading, checks, packaging, and parser updates</summary>

For source loading, add both checkouts to `load-path` and require `scss2-mode`, keeping this package's `vendor/` and emmet2-mode's `data/` beside their Lisp files. [Architecture](docs/architecture.md) describes module ownership, data flow, and design decisions.

```sh
SCSS2_EMMET2_DIR=/path/to/emmet2-mode make check
make package
```

`make check` verifies the bundled parser against its manifest, runs the isolated core and semantic suites, the Python tests, and the full ERT suite after strict byte compilation, then reruns the suite in a temporary package installation; your installed packages are untouched. `SCSS2_EMMET2_DIR` defaults to `../emmet2-mode`; `make test-core` needs no Emmet checkout. `make package` builds `dist/scss2-mode-<version>.tar` from tracked files and rejects a dirty parser snapshot.

Optional checks (popup drawing excluded):

```sh
# Mode setup, parsing and fontification benchmark; compare separate processes
emacs -Q --batch -L /path/to/emmet2-mode -l scripts/benchmark-emacs.el
# Completion benchmark; compare byte-compiled copies on the same Emacs
emacs -Q --batch -L . -L /path/to/emmet2-mode -l scripts/benchmark-completion.el
# Corfu/YAS, using emmet2-mode's pinned test dependencies
EMMET2_TEST_DEPS=/path/to/emmet2-test-deps emacs -Q --batch -L . \
  -l /path/to/emmet2-mode/test/bootstrap.el -l scripts/test-corfu.el
# Company/Orderless
emacs -Q --batch -L . -L /path/to/emmet2-mode \
  -L /path/to/company-mode -L /path/to/orderless -l scripts/test-frontends.el
# Avy: real candidates, key selection, cancellation and window isolation
emacs -Q --batch -L . -L /path/to/avy -l scripts/test-avy.el
```

To update the parser, change and test it in the grammar project, then import the complete snapshot instead of editing `vendor/`:

```sh
python3 scripts/vendor-parser.py --source /path/to/tree-sitter-scss
SCSS2_EMMET2_DIR=/path/to/emmet2-mode make check
```

The manifest records imported content, including uncommitted changes; `make package` requires a committed snapshot. CI runs `make check` and `make package` with Emacs 31.1 on Linux and macOS against the pinned Emmet2 commit; advance that pin in the commit that starts depending on newer Emmet2 code.

</details>

## License

GPL-3.0-or-later, as with emmet2-mode. The bundled parser keeps its MIT license. The CSS data and its licenses (MIT for VS Code Custom Data, CC0-1.0 for MDN data) belong to the separately installed emmet2-mode package.
