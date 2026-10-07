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
- **Indent and move through declarations and maps with TAB:** before a nonempty line's first nonblank character, TAB indents the line and moves to that character. In a property or variable name, or a Sass map key, TAB reindents the current line and jumps to the first character of its value. Multiline maps follow the same sequence: leading whitespace → key → value, including nested maps. Correct indentation leaves the text unchanged; an active region or an inaccessible line beginning skips reindentation. Inside the value, including nested functions, strings, URLs, and snippet fields, TAB jumps past the declaration's `;`. These actions close an open completion menu without accepting it. Blank lines keep their usual snippet or indentation behavior. Elsewhere, or without a value or an accessible `;`, TAB keeps its usual behavior.
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
| `scss2-kill` | Kill the nearest entity, or an `@if` / `@else if` condition |
| `scss2-empty` | Clear the nearest `()` / `[]` / `{}` / `#{}` interior, string contents, declaration / map entry / named argument value, parameter default, or at-rule body |
| `scss2-copy` | Copy the configured entity, briefly highlighting it |
| `scss2-comment-uncomment` | Comment the nearest map entry, declaration, statement or complete rule, or uncomment the comment group at point |
| `scss2-duplicate` | Duplicate the entity with its comma, statement separator or comment line break, briefly highlighting the copy |
| `scss2-mark` | Select the nearest entity or map key/value pair; repeated calls keep the selection |
| `scss2-avy-word` | Jump to a word inside the nearest complete multiline container |
| `scss2-expand` | Expand a declaration abbreviation |

Structural commands ignore prefix arguments such as `C-u`; point determines
the target. To select a whole block, move to its selector, at-rule keyword or
body whitespace. Conditional entities include all `@else` branches, while
empty clears only the current branch's body.
A declaration includes its complete multiline value, flags and terminator;
arguments and parameters are not separate entities. Entity commands select a
map's complete key/value pair; empty clears that pair's value. Kill also removes
an adjacent comma and preserves comments outside the pair. Removing the last
entry leaves `()`; an empty `@at-root` query also loses its parentheses.
Comment includes the required separators so the remaining map stays valid.
At a map entry's end, whitespace up to its next comma or closing `)` still
belongs to that entry: `a: 1│,` and `a: 1 │,` select the same pair. After the
comma (`a: 1,│`), the surrounding container applies again. This rule also
selects named argument values and parameter defaults for empty. It never
crosses a comment; inside a value, nearer strings and calls keep priority.

Empty walks upward from point to the nearest editable interior, value or block
body. Function and mixin names select their associated parameter or argument list, so both
`@function rhythm(...)` and `@mixin rhythm(...)` clear `()` from `rhythm`.
On a parameter name with a default, only its value is cleared:
`@mixin func($value: 1, $other: 2) {}` becomes
`@mixin func($value: , $other: 2) {}` from `$value`. Named arguments in calls,
`@include`, and module configuration (`with (...)`) follow the same rule.
The name, colon, commas and other arguments remain. A parameter without a
default continues upward to the surrounding parameter list.
Inside a header, parentheses, strings and nested calls keep their own interiors.
With no nearer target, the search reaches the `{}` body: `@if ($a > 0)` clears
the parentheses from its condition, while `@if $a > 0` clears the body.
On the at-rule keyword, empty clears its body; for `@if` and `@else if`, only
the current branch is cleared. A blockless directive can select its argument
list, so `@include foo(1);` becomes `@include foo();` from its keyword or name.
Without a nearer interior or a body, empty clears a nonempty at-rule head:
`@use "sass:math";` becomes `@use ;` from its keyword. Inside the string, only
the quoted contents are cleared. A leaf with no content, such as `@content;`,
continues to its enclosing block. If no target exists, empty reports that
there is nothing to empty.

Kill inside an `@if` or `@else if` condition removes that entire condition,
preserving the directive and block: `@if $x > 0 { ... }` becomes
`@if  { ... }` from `$x`. The `@else if` prefix stays together. Map entries
and comments remain nearer entities. On the directive or opening brace, kill
selects the complete conditional chain. Other at-rule headers select their
complete block or statement, including function and mixin names and parameters.

Comments are entities for kill, copy, duplicate and mark. Consecutive `//`
comments alone on their lines form one group; a blank line ends it. Trailing
comments and `/* ... */` comments stand alone. All five entity commands use the
same comment group, so commenting a multiline block and invoking the command
again restores the whole block. An adjacent handwritten `//` note also belongs
to that group; separate it with a blank line to keep it commented.
SCSS uses Emacs's native `comment-region` with the `indent` style: `//` markers
align at the region's minimum indentation, with relative code indentation
after the markers. Blank lines also receive a marker. Whitespace follows
Emacs's standard rules, which can pad short blank lines or adjust tabs;
undo restores the exact original text.

[`scss2-entity-node-types`](#structural-node-selection) controls code selection
for kill, copy, duplicate, mark and comment. By default, point in a declaration selects the declaration,
and point in a selector or at-rule header selects the complete rule or block
(with the if-condition exception for kill described above).
All five entity commands on a selector always target its complete rule,
including the selector list and block body, regardless of this option.
Individual selector branches are not entities. In whitespace between statements
inside `{}`, all five target the nearest complete enclosing rule or block.
All five entity commands walk from point to the nearest configured ancestor,
including map entries by default. In body whitespace they find the enclosing
rule or at-rule; inside value whitespace they find the enclosing pair or declaration.
Existing comments are always selected as comment groups. Empty resolves the
entity's internal contents and Avy resolves its navigation container separately.
The whitespace immediately after a child's closing brace belongs to its parent,
including for Avy. A cursor on the closing brace still belongs
to the child. Uncomment may still select the comment immediately before point.

Avy is optional: install [Avy](https://github.com/abo-abo/avy) to use
`scss2-avy-word`. From point, it finds the nearest complete multiline container:
a rule, at-rule or nested property block, map, parenthesized or bracketed list,
or module configuration (`with (...)`). Arguments and parameters continue upward
to a qualifying container, such as their complete function or mixin block.
Single-line containers are skipped in favor of an enclosing multiline container;
if none exists, the command reports no target. Ordinary declarations, individual
map entries, strings, comments and raw value groups are not navigation containers.
The full container, including its header or delimiters, fixes the range at
invocation. Conditional blocks include the whole `@if`/`@else` chain. The closing
delimiter belongs to its container; point immediately after it belongs to the
parent. The range is independent of the visible window range.
Candidates stay in the invoking window; label display follows Avy's usual behavior.

```elisp
(with-eval-after-load 'scss2-mode
  (keymap-set scss2-mode-map "C-c e" #'scss2-expand))
(with-eval-after-load 'css2-mode
  (keymap-set css2-mode-map "C-c e" #'scss2-expand))
```

Blank lines between top-level statements select nothing.
Empty stops at a comment and reports that there is nothing to empty.
A rule's selector,
an opening brace or blank space in a block clears its body. Empty can
intentionally leave an unfinished value; killing an if condition leaves that
condition unfinished. Each mutation is one undo step; incomplete
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
| `scss2-entity-node-types` | Map entries, declarations, rules and at-rule statements | Shared node selection for kill, copy, duplicate, mark and comment; see below |

Idle-released data is rebuilt on next use, so returning to a large file can take longer.

### Structural node selection

Use `M-x customize-variable RET scss2-entity-node-types RET` to inspect, edit
and save the node list, or find it under `M-x customize-group RET scss2 RET`.
The same option applies to both `scss2-mode` and `css2-mode`.

Kill, copy, duplicate, mark and comment share this one list; there are no
per-command lists. Empty and Avy use their built-in content and navigation
rules, have no configurable node lists, and are unaffected by this setting.

Entries are Tree-sitter node type strings, such as `"map_entry"`,
`"property_declaration"`, `"variable_declaration"`, `"rule_set"`,
`"function_definition"` and `"mixin_definition"`. Starting at point, commands
walk upward to the nearest matching node. List order does not give a type
higher priority. Adding a type changes selection, not syntax or separator
handling for that type.

For example, to stop selecting individual map entries and instead reach their
enclosing declaration with the remaining defaults:

```elisp
(with-eval-after-load 'scss2-edit
  (setq scss2-entity-node-types
        (remove "map_entry" scss2-entity-node-types)))
```

This changes all five entity commands together. Selectors still select their
complete rule, inter-statement body whitespace selects the enclosing block,
and existing comments select their comment group, regardless of the list.
Uncomment detection is unchanged. When the selected node is `@if` or `@else if`
and point is in its condition, kill removes only the condition; the other four
commands select the whole conditional chain.

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

CI also runs `make test-frontends` with the Corfu, compat, yasnippet,
company-mode, orderless and avy revisions pinned in `.github/workflows/check.yml`.
To run the same checks locally, place those checkouts under
`SCSS2_FRONTEND_DIR` (default `.dependencies/`), using those package names as
directory names, and run `make test-frontends`. Missing dependencies fail the
checks. Popup and Avy label drawing still need GUI checks.

Benchmarks and individual integration checks:

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
  -L /path/to/company-mode -L /path/to/orderless -L /path/to/compat \
  -l scripts/test-frontends.el
# Avy: real candidates, key selection, cancellation and window isolation
emacs -Q --batch -L . -L /path/to/avy -l scripts/test-avy.el
```

To update the parser, change and test it in the grammar project, then import the complete snapshot instead of editing `vendor/`:

```sh
python3 scripts/vendor-parser.py --source /path/to/tree-sitter-scss
SCSS2_EMMET2_DIR=/path/to/emmet2-mode make check
```

The manifest records imported content, including uncommitted changes; `make package` requires a committed snapshot. CI runs `make check test-frontends` and `make package` with Emacs 31.1 on Linux and macOS against the pinned Emmet2 commit; advance that pin in the commit that starts depending on newer Emmet2 code.

</details>

## License

GPL-3.0-or-later, as with emmet2-mode. The bundled parser keeps its MIT license. The CSS data and its licenses (MIT for VS Code Custom Data, CC0-1.0 for MDN data) belong to the separately installed emmet2-mode package.
