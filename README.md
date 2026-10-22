# scss2-mode

Major modes for editing CSS and SCSS in Emacs, with Tree-sitter highlighting, context-aware completion, structural editing and [emmet2-mode](https://github.com/P233/emmet2-mode) abbreviations. One package provides `scss2-mode` and `css2-mode`.

The bundled parser is [tree-sitter-scss](https://github.com/P233/tree-sitter-scss), an independent grammar that is not interchangeable with the [official grammar](https://github.com/tree-sitter-grammars/tree-sitter-scss). Emacs compiles it on first use, so there is no grammar to install.

Parsing targets complete files, and error recovery is deliberately narrow. A statement being typed usually stays one local error, so the rules after it keep their highlighting and structural commands; the unfinished statement refuses structural edits until it is repaired.

## Requirements

- Emacs 31.1 or later, built with Tree-sitter support.
- A C compiler available to Emacs (`cc`, or the `CC` environment variable).
- emmet2-mode 2.0.0 or later, installed as a dependency; the 0.2 series is incompatible.
- Python 3 and Git, only to build a local package archive without straight.el.

scss2-mode is developed on macOS and checked by CI on Linux. Indented Sass (`.sass`) is not supported.

## Install

With straight.el and use-package, declare emmet2-mode first so straight knows its recipe. You need not enable `emmet2-mode`; scss2-mode calls it directly:

```elisp
(use-package emmet2-mode
  :straight (emmet2-mode :type git :host github :repo "P233/emmet2-mode"
                         :files (:defaults "data")))
(use-package scss2-mode
  :straight (scss2-mode :type git :host github :repo "P233/scss2-mode"
                        :files (:defaults "vendor")))
```

Without straight.el, build one local archive containing both packages from your scss2-mode checkout (add `--emacs /path/to/emacs` if `emacs` is not on `PATH`):

```sh
python3 scripts/package.py --output-dir dist/local-archive \
  --emmet-source /path/to/emmet2-mode
```

Then add the archive and install scss2-mode. Emacs installs emmet2-mode as a dependency. You need not enable `emmet2-mode`; scss2-mode calls it directly:

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

The parser ships as C source. On first use, Emacs compiles it into a native library in `scss2-grammar-cache-directory`; you run no build command and need no Tree-sitter CLI, download, Node or background service. Later sessions reuse the library. Changed parser sources or another platform build a new one; an update to the highlighting queries alone does not.

A buffer larger than `treesit-max-buffer-size`, or a parser that cannot be built or loaded (for example, without a C compiler), shows a warning and keeps the dialect's syntax, comment commands, indentation, and comment and string highlighting; your mode hooks still run.

## Everyday editing

Inside `.card { }`, type `m10` and run `M-x scss2-expand` to get `margin: 10px;`. Bracket values may contain blanks (`p[1px 2px]`, `w[calc(100% - 2rem)]`); SCSS also accepts `p$gutter` and `p$a$b$c`. Completion offers the same expansions as Emmet candidates.

Complete at point with `M-x completion-at-point` or a [frontend](#frontends); `M-x emmet2-complete` requests Emmet candidates only. Completion covers at-rules, property values, CSS functions, pseudo-selectors, media queries, local import paths, and custom properties in `var()`; SCSS adds visible variables, functions, mixins, named arguments, and members of local `@use` modules. Property names come only from Emmet expansion; class, ID, and tag names, and ordinary text in comments and strings, are not completed.

Matching is fuzzy: `display: ib` offers `inline-block`. The `scss2` completion style, the default for the `scss2` completion category, also decodes CSS escapes and treats Sass `_` and `-` alike. To match with your own styles, override the category. Your styles then match raw spellings, so escaped queries such as `i\62` and queries relying on Sass `_`/`-` equivalence find nothing:

```elisp
(add-to-list 'completion-category-overrides '(scss2 (styles basic partial-completion)))
```

In a narrowed buffer, completion and commands read the whole syntax tree, as Font Lock does, but editing and motion act only inside the restriction. Definition jumps follow xref: they widen by default and signal an error when `widen-automatically` is nil ([details](docs/architecture.md#narrowing-and-the-shared-parser)).

`M-.` (`xref-find-definitions`) finds Sass variables, mixins in `@include`, functions in calls and placeholder rules in `@extend`. Qualified names read local `@use` modules, including unsaved open buffers. Both modes also find custom-property declarations from `var(--name)`. `M-,` returns through xref history; the standard other-window definition command also works.

Eldoc shows parameter names and defaults inside resolved Sass mixin and function calls, including local `@use` members. In `@include paint(1, |)`, it highlights the second parameter; in `tint($amount: |)`, it highlights `$amount`. Nested calls show the innermost signature. Rest parameters receive extra positional arguments and unmatched keywords. Lookup follows the same rules as definition navigation and adds no index or cache.

Signatures use one line, with comments removed and whitespace collapsed. Strings and comments inside call arguments keep the enclosing argument's highlight. The provider is registered only in SCSS buffers and reads module signatures during the same lookup as definition navigation.

Flymake reports parse errors when you enable it. Both modes register `scss2-flymake` buffer-locally but leave `flymake-mode` off. To enable checks:

```elisp
(add-hook 'scss2-mode-hook #'flymake-mode)
(add-hook 'css2-mode-hook #'flymake-mode)
```

The backend reports outermost `ERROR` ranges and missing tokens as errors, naming the missing token; a missing token marks the character at its insertion point. Each check stops at 200 diagnostics and says so in the last one. In a narrowed buffer it checks the whole buffer, or only the restriction when `font-lock-dont-widen` is non-nil. Indirect clones have no parser and report nothing.

`hs-minor-mode` folds bracketed blocks in both modes, `//` comment runs in SCSS and multiline `/* */` comments in CSS, keeping the opening-brace line of a multiline selector visible.

Imenu lists mixins, functions, module-level Sass variables, rules whose whole selector is one `%placeholder`, keyframes and rules, omitting empty categories. Outline headings stay on rules, mixins and functions.

TAB indents and moves through declarations and maps. Before a nonempty line's first nonblank character, TAB indents the line and moves to that character. In a property or variable name, or a Sass map key, TAB reindents the current line and jumps to the first character of its value. Multiline maps, including nested ones, follow the same sequence: leading whitespace, then key, then value. Inside the value, including nested functions, strings, URLs, and snippet fields, TAB jumps past the declaration's `;`. Correct indentation leaves the text unchanged; an active region or an inaccessible line beginning skips reindentation. These actions close an open completion menu without accepting it. Elsewhere, including blank lines between statements, or without a value or an accessible `;`, TAB keeps its usual snippet or indentation behavior.

The modes neither load nor run Emacs's `css-mode`. They supply their own comment syntax, comment filling, color previews and indentation. Indentation nests by `scss2-indent-offset`, follows a block's existing indentation, and indents continued values and selectors as Prettier does; EditorConfig's `indent_size` sets `scss2-indent-offset`, and `css-indent-offset` is not read. `derived-mode-p` still matches `css-mode` in both modes and `scss-mode` in `scss2-mode`, but those modes' hooks and key bindings do not apply; use `scss2-mode-hook`, `css2-mode-hook` and their maps. Highlighting uses Font Lock faces plus `scss2-selector` and `scss2-property`, so themes own the palette.

In SCSS, `///` SassDoc comments use the doc face. Annotations such as `@param`, `@return` and `@example` use the doc-markup face, `{type}` uses the type face and `$name` after `@param` uses the variable-name face. Annotation aliases are supported. Example bodies keep the doc face. This highlighting is independent of `scss2-fontify-details`.

### Structural commands

TAB runs `scss2-tab` in both modes. The other commands have no default bindings; run them with `M-x` or bind them in `scss2-mode-map` and `css2-mode-map`:

```elisp
(with-eval-after-load 'scss2-mode
  (keymap-set scss2-mode-map "C-c e" #'scss2-expand))
(with-eval-after-load 'css2-mode
  (keymap-set css2-mode-map "C-c e" #'scss2-expand))
```

| Command | Action |
| --- | --- |
| `scss2-kill` | Kill the nearest entity, or an `@if` / `@else if` condition |
| `scss2-empty` | Clear the nearest `()` / `[]` / `{}` / `#{}` interior, string contents, declaration / map entry / named argument value, parameter default, or at-rule body |
| `scss2-copy` | Copy the nearest entity, briefly highlighting it |
| `scss2-comment-uncomment` | Comment the nearest map entry, declaration, statement or complete rule, or uncomment the comment group at point |
| `scss2-duplicate` | Duplicate the entity with its comma, statement separator or comment line break, briefly highlighting the copy |
| `scss2-mark` | Select the nearest entity or map key/value pair; repeated calls keep the selection |
| `scss2-avy-word` | Jump to a word inside the nearest complete multiline container |
| `scss2-expand` | Expand a declaration abbreviation |

Point alone determines the target; the commands ignore prefix arguments such as `C-u`. Each edit is one undo step. Commands refuse a target whose boundaries depend on unfinished syntax, and a failed edit restores text, point, selection and the kill ring. Empty can intentionally leave an unfinished value, and killing an `@if` condition leaves that condition unfinished ([details](docs/architecture.md#structural-targets)).

Kill, copy, duplicate, mark and comment are the entity commands. They walk up from point to the nearest node type in [`scss2-entity-node-types`](#structural-node-selection), which includes map entries by default; inside value whitespace they find the enclosing pair or declaration. With the defaults, point in a declaration selects the declaration with its complete multiline value, flags and terminator, and point in an at-rule header selects the complete block or statement. Arguments and parameters are not separate entities. Empty and Avy use their own rules, described below.

Some targets do not depend on that option. On a selector, the entity commands select its complete rule, including the selector list and block body; individual selector branches are not entities. In whitespace between statements inside `{}`, they select the nearest complete enclosing rule or block. To select a whole block, move to its selector, at-rule keyword or body whitespace. The whitespace right after a child's closing brace belongs to the parent, also for Avy, while point on the closing brace belongs to the child. Blank lines between top-level statements select nothing. A conditional's entity includes all its `@else` branches.

In a map, the entity commands select a complete key/value pair. At an entry's end, whitespace up to the next comma or closing `)` still belongs to that entry: `a: 1│,` and `a: 1 │,` select the same pair, and after the comma (`a: 1,│`) the surrounding container applies again. This rule never crosses a comment, nearer strings and calls inside a value keep priority, and empty applies it to named argument values and parameter defaults as well. Kill also removes an adjacent comma and keeps comments outside the pair; removing the last entry leaves `()`, and an empty `@at-root` query also loses its parentheses. Comment includes the required separators so the remaining map stays valid. Empty clears the pair's value.

Kill inside an `@if` or `@else if` condition removes the whole condition and keeps the directive and block: from `$x`, `@if $x > 0 { ... }` becomes `@if  { ... }`. The `@else if` prefix stays together, and map entries and comments remain nearer entities. On the directive or opening brace, kill selects the complete conditional chain. Other at-rule headers select their complete block or statement, including function and mixin names and parameters.

Existing comments are entities for kill, copy, duplicate and mark, and comment uncomments them. Consecutive `//` comments alone on their lines form one group, which a blank line ends; trailing comments and `/* ... */` comments stand alone. All five entity commands use the same group, so commenting a multiline block and invoking the command again restores the whole block. An adjacent handwritten `//` note also joins that group; separate it with a blank line to keep it commented. Uncomment may also select the comment immediately before point.

SCSS line comments use Emacs's native `comment-region` with the `indent` style: `//` markers align at the region's minimum indentation, code keeps its relative indentation after the markers, and blank lines also receive a marker. Emacs's standard whitespace rules can pad short blank lines or adjust tabs; undo restores the exact original text.

Empty walks upward from point to the nearest editable interior, value or block body. Function and mixin names select their parameter or argument list, so `@function rhythm(...)` and `@mixin rhythm(...)` both clear `()` from `rhythm`. On a parameter name with a default, only the value is cleared: from `$value`, `@mixin func($value: 1, $other: 2) {}` becomes `@mixin func($value: , $other: 2) {}`. Named arguments in calls, `@include` and module configuration (`with (...)`) follow the same rule; the name, colon, commas and other arguments remain. A parameter without a default continues upward to the surrounding parameter list.

Inside a header, parentheses, strings and nested calls keep their own interiors. With no nearer target, the search reaches the `{}` body: `@if ($a > 0)` clears the parentheses of its condition, while `@if $a > 0` clears the body. A rule's selector, an opening brace, blank space in a block and an at-rule keyword also clear the body; for `@if` and `@else if`, only the current branch's body is cleared. A blockless directive can select its argument list, so `@include foo(1);` becomes `@include foo();` from its keyword or name. Without a nearer interior or body, empty clears a nonempty at-rule head: from its keyword, `@use "sass:math";` becomes `@use ;`, while inside the string only the quoted contents are cleared. A leaf with no content, such as `@content;`, continues to its enclosing block. Empty stops at a comment, and wherever it finds no target it reports that there is nothing to empty.

`scss2-avy-word` needs [Avy](https://github.com/abo-abo/avy), which is optional. From point, it finds the nearest complete multiline container: a rule, at-rule or nested property block, a map, a parenthesized or bracketed list, or a module configuration (`with (...)`). Arguments and parameters continue upward to a qualifying container, such as their complete function or mixin block, and single-line containers give way to an enclosing multiline one; if none exists, the command reports no target. Ordinary declarations, individual map entries, strings, comments and raw value groups are not navigation containers.

The full container, including its header or delimiters, fixes the range at invocation; the visible part of the window does not limit it. Conditional blocks include the whole `@if`/`@else` chain. The closing delimiter belongs to its container; point immediately after it belongs to the parent. Candidates stay in the invoking window, and label display follows Avy's usual behavior.

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `scss2-enable-emmet` | `t` | `nil` disables abbreviations and keeps semantic completion |
| `scss2-fontify-details` | `nil` | `t` also highlights numbers, type brackets, and delimiters such as commas and member dots, which many themes, including Emacs's default, show plain; `nil` stores fewer highlighting intervals. Units and operators are always highlighted, and `;`, `:`, and other brackets never; set it before opening buffers |
| `scss2-idle-release-delay` | `30` | Idle seconds before buffers shown in no window release their syntax trees and highlighting, keeping text and undo; `nil` keeps everything |
| `scss2-grammar-cache-directory` | `tree-sitter/scss2-mode/` in `user-emacs-directory` | Where the compiled parser is stored |
| `CC` (environment) | `cc` | Compiler command, split like a shell command: `ccache cc` and `cc -m64` work; quote a path containing spaces |
| `scss2-indent-offset` | `2` | Indentation width |
| `scss2-fontify-colors` | `t` | Show hex colors, color names and literal `rgb()`/`hsl()` calls with that color as background; set it before opening buffers |
| `scss2-entity-node-types` | Map entries, declarations, rules and at-rule statements | Shared node selection for kill, copy, duplicate, mark and comment; see below |

Idle-released data is rebuilt on next use, so returning to a large file can take longer.

### Structural node selection

Use `M-x customize-variable RET scss2-entity-node-types RET` to inspect, edit and save the node list, or find it under `M-x customize-group RET scss2 RET`. The option applies to both `scss2-mode` and `css2-mode`.

Kill, copy, duplicate, mark and comment share this one list; there are no per-command lists. Empty and Avy use their built-in content and navigation rules and ignore it.

Entries are Tree-sitter node type strings, such as `"map_entry"`, `"property_declaration"`, `"variable_declaration"`, `"rule_set"`, `"function_definition"` and `"mixin_definition"`. Starting at point, commands walk upward to the nearest matching node; list order gives no type priority. Adding a type changes selection, not syntax or separator handling for that type.

For example, to stop selecting individual map entries and reach their enclosing declaration instead, keeping the other defaults:

```elisp
(with-eval-after-load 'scss2-edit
  (setq scss2-entity-node-types
        (remove "map_entry" scss2-entity-node-types)))
```

The list does not change what selectors, body whitespace and existing comments select, or how uncomment finds a comment. When the selected node is `@if` or `@else if` and point is in its condition, kill removes only the condition; the other four commands select the whole conditional chain.

## Frontends

Corfu is the supported completion frontend. Company works through standard completion-at-point; after Company accepts a function value such as `calc()`, point stays after the parentheses, where Corfu places it inside. Semantic value choices and Emmet declaration choices both work in Company. Orderless works with the default `scss2` category.

## Known limits

- Eldoc leaves CSS functions, unresolved calls, unparsed or unclosed argument lists, `@content` calls and `using (...)` parameters to other providers. Argument spreads count as one syntactic argument; their runtime contents are not evaluated.
- Definition lookup does not follow `@forward`, `@import`, built-in `sass:` modules, packages or load paths. Unqualified `as *` members are unsupported. Sass bindings use scope and source order: inside mixin or function bodies and their parameter defaults an unresolved name falls back to its first later module-level definition, while uses at module level still require an earlier declaration. Sass execution and the CSS cascade are not evaluated; custom-property lookup returns all matching declarations. Reference search uses only xref's stock fallback.
- Module completion reads local `@use` files, including unsaved edits in open buffers, but does not follow `@forward`. Unqualified variables, functions and mixins come only from the current file, not from `@import`ed files or `@use` modules loaded `as *`.
- Built-in modules such as `sass:math`, package and load-path modules and import paths with a scheme or without a local directory are left to other completion functions. Elsewhere semantic completion is exclusive: later completion functions do not run, even without a match.
- Inside a nested property such as `font: { weight: bold; }`, values complete under the full name (`font-weight`), but property names do not complete.
- Some unfinished code completes poorly, such as `var(` inside unclosed `@include` arguments.
- In a short file, a last rule left open after a complete declaration, as in `.a { color: red;` at the end of the file, makes the whole file one parse error, so structural commands stop until `}` is typed; `electric-pair-mode` inserts it with `{`.
- `hs-minor-mode` does not fold multiline `/* */` comments in SCSS. On a multiline selector, fold from the line with the `{`: from an earlier selector line, hideshow folds the enclosing block, or nothing at the top level.
- SassDoc highlighting applies to every `///` comment, so a `///` comment after code on the same line, as in `.a { b: c; } /// note`, and a line of slashes also use the doc face.
- Each open buffer keeps a syntax tree of tens of bytes per source byte; buffers shown in no window release it after `scss2-idle-release-delay`.
- Parser limits are listed in [tree-sitter-scss](https://github.com/P233/tree-sitter-scss#known-limits). Flymake reports the parser's errors without pattern suppression, including known false positives on valid typed `attr()` unions such as `attr(data-width type(<length> | <percentage>), 10px)` and a comment before a quoted `url()` argument such as `url(/* note */ "a.png")`. The backend does no Sass or CSS semantic validation.

## Development

<details>
<summary>Source loading, checks, packaging, and parser updates</summary>

For source loading, add both checkouts to `load-path` and require `scss2-mode`, keeping this package's `vendor/` and emmet2-mode's `data/` beside their Lisp files. [Architecture](docs/architecture.md) describes module ownership, data flow, and design decisions.

```sh
SCSS2_EMMET2_DIR=/path/to/emmet2-mode make check
make package
```

`make check` verifies the bundled parser against its manifest, runs the isolated core and semantic suites, the Python tests, and the full ERT suite after strict byte compilation, then reruns the suite in a temporary package installation; your installed packages are untouched. `SCSS2_EMMET2_DIR` defaults to `../emmet2-mode`; `make test-core` needs no emmet2-mode checkout. `make package` builds `dist/scss2-mode-<version>.tar` from tracked files and rejects a dirty parser snapshot.

CI also runs `make test-frontends` with the Corfu, compat, yasnippet, company-mode, orderless and avy revisions pinned in `.github/workflows/check.yml`. To run the same checks locally, place those checkouts under `SCSS2_FRONTEND_DIR` (default `.dependencies/`), using those package names as directory names, and run `make test-frontends`. Missing dependencies fail the checks. Popup and Avy label drawing still need GUI checks.

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

The manifest records imported content, including uncommitted changes; `make package` requires a committed snapshot. CI runs `make check test-frontends` and `make package` with Emacs 31.1 on Linux against the emmet2-mode commit pinned in the workflow; advance that pin in the commit that starts depending on newer emmet2-mode code.

</details>

## License

GPL-3.0-or-later, as with emmet2-mode. The bundled parser keeps its MIT license. The CSS data and its licenses (MIT for VS Code Custom Data, CC0-1.0 for MDN data) belong to the separately installed emmet2-mode package.
