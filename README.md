# Writerly

<img src="https://raw.githubusercontent.com/vistuleB/writerly/main/logo.svg" alt="Writerly Logo" style="width:110px;height:110px;"/>

[![Package Version](https://img.shields.io/hexpm/v/writerly)](https://hex.pm/packages/writerly)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/writerly/)

Writerly is a lightweight, indentation-based markup language for authoring
tree-structured documents that resemble ordinary prose. Its syntax is
descended from [Elm-Markup](https://github.com/mdgriffith/elm-markup).

This Gleam package constitutes Writerly's reference implementation. It can:

- convert between Writerly and [VXML](https://hex.pm/packages/vxml)
- assemble a document distributed across a directory of `.wly` files,
  according to Writerly's own
  [multi-file document specification](#multi-file-documents)

Writerly is deliberately tag- and attribute-agnostic: it assigns no built-in
meaning to a document's vocabulary. Each project typically defines that
vocabulary through a process known as *desugaring*, which transforms parsed
VXML into target-specific structure. The
[VXML Pipeline](https://hex.pm/packages/vxml_pipeline) package provides
desugaring support.

The
[Writerly extension for VS Code](https://marketplace.visualstudio.com/items?itemName=TabbyNotes.writerly-vscode-extension)
provides syntax highlighting, diagnostics, and document navigation.

### Example

````writerly
|> Chapter
    title=The observatory on the hill
    handle=observatory

    The road to the observatory follows the river for
    several miles before turning uphill. In summer, tall
    grass hides the stones that once marked the route.

    At the summit stands a small white building with a
    copper dome. The telescope inside was installed in
    1927, but its clockwork drive still follows the stars
    across the sky.

    |> Section
        title=Recording an observation
        handle=recording-observations

        An observation begins with the time, the position
        of the telescope, and a short description of the
        weather. Blank lines separate paragraphs, while
        consecutive lines remain part of the same paragraph.

        A project may give _underscores_ a meaning such
        as emphasis, although Writerly itself leaves them
        as text.

        |> Note
            class=field-note

            Clouds near the horizon can make a bright
            star appear to fade and return several times.

        The measurements can then be processed by a program:

        ```gleam&id=record
        pub fn record(name, brightness) {
          #(name, brightness)
        }
        ```

    !! Recheck the installation date before publication.
````

The pipe symbol `|>` starts a new node, with the tag name and nothing else on
the same line. Its attributes and children are indented by four spaces.
Ordinary prose needs no marker. Consecutive text lines form a paragraph, while
blank lines are represented by their own node type in the parsed AST.

### Beginning-of-line escape sequences

Indentation, `!!`, and triple backticks have structural meaning at the start
of a line. Prefix them with a backslash when they should instead be text:

````writerly
\   text beginning with spaces
\!! text, not a comment
\```text, not a code fence
````

Writerly removes the backslash and preserves the following text.
Inside a fenced code block, use the same technique for a content line that
would otherwise look like the closing fence. The serializer adds these
escapes when required.

### Use from Gleam

Add the package to a Gleam project:

```sh
gleam add writerly
```

Parse a source string with one non-blank top-level element directly to VXML:

```gleam
import writerly
import vxml/io_lines

pub fn parse(source: String, source_path: String) {
  source
  // 'source_path' is used for blame attribution:
  |> io_lines.string_to_input_lines(source_path, 0)
  |> writerly.input_lines_to_vxml
}
```

`input_lines_to_vxml` preserves source provenance through VXML `Blame` values.
The lower-level `string_to_writerlys` and `input_lines_to_writerlys` functions
are available when a source contains multiple top-level nodes; convert their
results with `writerlys_to_vxmls`.

### Multi-file documents

`assemble_sources` assembles a document from a list of `SourceFile(path,
contents)` values whose paths are relative to the document root. The package
does no file I/O, so it runs on both the Erlang and JavaScript targets,
including in the browser: the caller loads the sources from disk, an editor's
in-memory project, or anywhere else. A single-file document is a one-element
list. A multi-file document may use `__parent.wly` as its root file:

```text
book/
├── __parent.wly
├── 01-introduction.wly
├── 02-examples.wly
└── appendix/
    ├── __parent.wly
    └── 01-tables.wly
```

Sibling files are processed in lexicographic path order. Their contents are
indented beneath the contents of `__parent.wly` if a `__parent.wly` file is present.
Otherwise they are concatenated at their native level of indentation.
Nested directories are assembled recursively.
Files and directories whose names start with `#` are ignored. Only files
ending in `.wly` are included; directory names need no special suffix.
At least one eligible `.wly` file must sit directly at the root. If every
eligible file is in a subdirectory, assembly returns `NoFilesFound`. Source
paths use `/` separators and must not be empty, absolute, or contain empty,
`.`, or `..` components (`InvalidSourcePath`), and each path may appear only
once (`DuplicateSourcePath`). The order of the source list does not matter.

Use `assemble_sources_with_path_selector` to select source paths with a
`fn(String) -> Bool` predicate receiving relative file paths.
Assembly returns `Result(#(DirTree, List(InputLine)), AssemblyError)`. The
first argument names the root of the returned tree. The tree records the
selected file layout; the input lines retain relative filenames and line
numbers for later parsing and VXML processing:

```gleam
import gleam/result
import writerly.{SourceFile}

pub fn assemble_lines() {
  [
    SourceFile("__parent.wly", "|> Book"),
    SourceFile("01-introduction.wly", "Once upon a time."),
  ]
  |> writerly.assemble_sources("book", _)
  |> result.map(fn(assembled) {
    let #(_tree, lines) = assembled
    lines
  })
}
```

To assemble a file or directory on disk, read its `.wly` files into
`SourceFile`s first, for example with
[simplifile](https://hex.pm/packages/simplifile).
`vxml_pipeline/writerly_defaults.read_writerly_sources` does exactly this.

### VXML representation

The conversion to VXML uses ordinary VXML element and text nodes, with three
reserved element names:

- `WriterlyBlankLine` represents a semantic blank line;
- `WriterlyCodeBlock` represents a fenced code block;
- `WriterlyComment` represents a comment block.

The synthetic attribute `WriterlyCodeBlockInfoStringPrefix` stores the
nonempty, unmarked prefix of a code fence's info string: the part before its
first unescaped `&key=value` annotation. The attribute is absent when that
prefix is empty. Structured fence annotations become ordinary VXML attributes.
Commented-out element attributes use keys of the form
`WriterlyCommentedAttribute<N>Spaces`, where `N` records their original spacing.
Use `code_block_info_string_prefix_attribute_key` for the info-string attribute
key. For commented attributes, use:

- `is_commented_attribute_key(key)` to recognize an encoded key;
- `commented_attribute_spaces(key)` to recover its spacing as `Option(Int)`;
- `commented_attribute_key(spaces)` to construct a key as `Option(String)`.

The spacing helpers accept or recognize counts from zero through 100; invalid
counts or keys produce `None`.

VXML-to-Writerly conversion and Writerly serialization return `Result` values.
Malformed reserved elements, empty text nodes, and malformed manually
constructed Writerly nodes are reported as `SerializationError` values.

### Serialization and diagnostics

Convert a VXML node back to Writerly source by first converting it to a
Writerly node, then serializing it. Both operations can fail, and `result.try`
propagates either error to the caller:

```gleam
import gleam/result
import vxml
import writerly

pub fn to_source(tree: vxml.VXML) -> Result(String, writerly.SerializationError) {
  use document <- result.try(writerly.vxml_to_writerly(tree))
  writerly.writerly_to_string(document)
}
```

For multiple VXML nodes, use `vxmls_to_writerlys` followed by
`writerlys_to_string`. Serialization produces Writerly syntax; it is not a
byte-for-byte reconstruction of the original source formatting.

`writerly_debug_table(document, "Parsed document", 0)` returns a diagnostic
table as `Result(String, SerializationError)`. It displays source provenance
with structural descriptions such as `Paragraph > Line(1)`. The second argument
is the table banner; the third is its left margin. Annotation is automatic.

### API overview

Singular conversion names operate on one node; plural names operate on lists.
Parsing to a single node requires exactly one non-blank top-level node.

| Operation | Functions |
|---|---|
| Parse source strings | `string_to_writerly`, `string_to_writerlys` |
| Parse source lines | `input_lines_to_writerly`, `input_lines_to_writerlys` |
| Parse directly to one VXML root | `input_lines_to_vxml` |
| Convert Writerly to VXML | `writerly_to_vxml`, `writerlys_to_vxmls` |
| Convert VXML to Writerly | `vxml_to_writerly`, `vxmls_to_writerlys` |
| Serialize to source strings | `writerly_to_string`, `writerlys_to_string` |
| Serialize to provenance-carrying output lines | `writerly_to_output_lines`, `writerlys_to_output_lines` |
| Assemble source files | `assemble_sources`, `assemble_sources_with_path_selector` |
| Render a diagnostic table | `writerly_debug_table` |

Parsing, assembly, VXML-to-Writerly conversion, and serialization return
`Result` values. Writerly-to-VXML conversion is infallible.

### Cross-document references

Writerly has an official convention for cross-document references based on
*handles*. A handle connects a definition site to one or more usage sites.
Handle syntax is interpreted by editor tooling and desugaring rather than by
the core parser. A definition may be an ordinary element attribute:

```writerly
|> Theorem
    handle=odd-order-theorem
```

or an in-text marker:

```writerly
odd-order-theorem##<<
```

A usage places `>>` immediately before the handle name:

```writerly
The result now follows from Theorem >>odd-order-theorem.
```

A single backslash suppresses either kind of in-text recognition:

```writerly
odd-order-theorem\##<< is ordinary text
\>>odd-order-theorem is ordinary text
```

Inside fenced code-block content, in-text handle definitions remain active,
but `>>handle` usages are ordinary code text. Neither form is recognized on
the opening or closing fence line.

The [full handle grammar](#handle-grammar) at the end of this README describes
additional definition forms, escaping rules, and other capabilities.

In parsed VXML, `handle` remains an ordinary attribute and in-text handle forms
remain text. Projects interpret them later through desugaring. The
[VXML Pipeline](https://hex.pm/packages/vxml_pipeline) package supplies shared
handle desugarers.

The
[Writerly extension for VS Code](https://github.com/vistuleB/writerly-vscode-extension#handles)
provides navigation, completion, rename support, and diagnostics for handles
that follow the same grammar.

### Inline formatting

Unlike some other lightweight markup languages, Writerly assigns no special
meaning to underscores, asterisks, tildes, or similar inline delimiters. They
remain ordinary text. A project may introduce rich-text formatting with its
own delimiters and interpret them during desugaring.

Writerly provides structural elements, attributes, paragraphs, comments, and
fenced code blocks without prescribing a built-in rich-text vocabulary. This
is one respect in which Writerly may differ from syntax familiar from
Elm-Markup and other lightweight markup languages.

### MathJax and LaTeX

Writerly treats LaTeX commands and math delimiters such as `$...$` and
`\[...\]` as ordinary text. The parser does not interpret or render them;
a project's desugaring pipeline determines how that text is prepared for
MathJax or another renderer. Commands such as `\frac` and `\begin{align*}`
can be written directly, without doubling their backslashes.

Writerly's indentation rules still apply inside LaTeX source. To keep leading
spaces for visually aligning source lines, put a backslash immediately after
the structural indentation, before those spaces:

```writerly
|> Example

    \begin{align*}
    (x + 1)^2 &= x^2 + 2x + 1 \\
    \         &= x(x + 2) + 1
    \end{align*}
```

Writerly removes the initial escape backslash on the continuation line and
preserves the spaces after it. The
[courses source](https://github.com/dominikscheder/courses/blob/main/course-TI-2/wly/03/03-sets-like-R.wly)
contains an example of this convention in an `align*` environment.

For an example pipeline that desugars LaTeX math in Writerly source for
MathJax, see
[the courses pipeline](https://github.com/dominikscheder/courses/blob/main/src/pipeline.gleam),
including its `math_block_pipeline` and `inline_math_pipeline` steps.

## Syntax Reference

### Source and indentation

A Writerly document is a sequence of lines. Its structural indentation is made
of spaces and must be a multiple of four. A child is indented exactly four
spaces farther than its parent. Unexpected deeper indentation is an error.

Writerly documents conventionally use the `.wly` filename extension.

### Line classification

Parsing proceeds linearly. Structural indentation first determines the current
parent and the line's position within it. A line is then interpreted according
to that position:

1. An empty line is a semantic blank line.
2. In an element's initial attribute region, a valid `key=value` line is an
   attribute and an `!!` line is a commented attribute.
3. At ordinary child position, `|>` opens an element, `!!` begins a comment,
   and three initial backticks open a fenced code block.
4. Any other nonempty line is paragraph text.

A beginning-of-line escape suppresses recognition of comment and code-fence
markers and permits content to begin with otherwise structural spaces.

### Elements

An element begins with `|>` followed by a tag name:

```writerly
|> article
```

Whitespace surrounding the name after `|>` is trimmed. A tag name must match:

```text
[A-Za-z_:][-A-Za-z0-9._:]*
```

The result is an ordinary VXML element with the same tag name.
Attributes and children occur on subsequent lines, indented four more spaces.
An element ends when the indentation returns to that element's level or lower.
Closing tags are not written.

### Attributes

Immediately after an element line, lines of the following form are parsed as
attributes:

```writerly
|> figure
    id=overview
    class=wide diagram
```

The first `=` separates the key and value. An attribute key must match:

```text
[A-Za-z_][-A-Za-z0-9._:]*
```

The key and value become an ordinary VXML attribute. Leading spaces and tabs
after the `=` are preserved as part of the value, up to a maximum of 100.
More than 100 leading spaces or tabs is a parsing error. Trailing spaces and
tabs are trimmed. Empty values are allowed.

Attribute parsing stops at the first line that is not a valid attribute. If an
element's first text line resembles an attribute, insert a blank line before
it:

```writerly
|> Example

    equation=a+b
```

### Paragraphs and text lines

Consecutive ordinary lines at the same indentation become the `Line` values
of one VXML text node. After removing structural indentation, Writerly
preserves the remaining text, including trailing whitespace.

Leading spaces in text content cannot be written directly because leading
spaces normally express structural indentation. To preserve them, place a
backslash immediately after the line's structural indentation. The backslash
is removed while the spaces following it are retained. The same escape allows
text to begin with `!!` or triple backticks:

```writerly
\    text beginning with spaces
\!! text, not a comment
\``` text, not a code fence
```

Exactly one escape backslash is removed. Further backslashes remain part of
the text. The serializer inserts one escape when required.

### Blank lines

Every empty source line becomes an empty VXML element named
`WriterlyBlankLine`. Blank lines are therefore semantic nodes: adding or
removing one changes the VXML tree. Their meaning, if any, is assigned by later
processing.

### Comments

At ordinary child position, consecutive lines beginning with `!!` become one
`WriterlyComment` VXML element containing a text node. The `!!` marker is
removed from the stored line content:

```writerly
!! first comment line
!! second comment line
```

In the attribute region immediately following an element, an `!!` line is
instead stored as a synthetic VXML attribute. The number of spaces after `!!`
is preserved in its key, up to a maximum of 100. More than 100 spaces is a
parsing error:

```writerly
|> figure
    !! class=temporarily-disabled
    src=figure.svg
```

### Fenced code blocks

A line beginning with three backticks opens a code block. A line containing
three backticks at the same indentation closes it. The result is a
`WriterlyCodeBlock` VXML element:

````writerly
```gleam
pub fn answer() {
  42
}
```
````

The closing fence may have trailing whitespace but no annotation. Lines inside
the block retain their relative indentation. Prefix a content line that would
look like a closing fence with a backslash; parsing removes exactly that one
backslash.

The text immediately following the opening backticks is the info string. It
must not begin with a space. An info string may be followed by structured
annotations written as `&key=value`:

````writerly
```gleam&id=answer&class=example
```
````

Annotation keys follow the attribute-key grammar. Their values preserve leading
spaces and tabs, trim trailing spaces and tabs, and obey the same 100-character
leading-whitespace limit as element attributes; exceeding that limit is a
parsing error. Write `\&` for a literal ampersand and `\\` for a literal
backslash in the info string or an annotation. Parsing and serialization
preserve the distinction between the leading info string and structured
annotations.

### Top-level cardinality

A Writerly source may contain any number of top-level nodes, but parsing it as
one VXML tree requires exactly one non-blank root. `input_lines_to_vxml`
returns `MissingRoot` or `NonUniqueRoot` when that requirement is not met. For
multiple roots, use `string_to_writerlys` or `input_lines_to_writerlys`, then
convert the result to a list of VXML nodes with `writerlys_to_vxmls`.

### Handle grammar

Handles are an official Writerly convention interpreted by editor tooling and
desugaring. The core Writerly parser preserves their source syntax as ordinary
attributes or text.

Handle names and decorators use these character classes:

```text
name interior: Unicode letters, numbers, marks, _ . : - ' ^
name final:    Unicode letters, numbers, marks, _ ' ^
decorator:     # followed by one or more Unicode letters, numbers, marks, _ : ' -
```

A name contains at least one character and cannot end with `.`, `:`, or `-`.
Zero or more decorators may follow it. Decorators are metadata and are not part
of the indexed handle name.

#### Attribute definitions

Within an element's attribute region, `handle` defines a handle. Its value has
one of these forms:

```text
name
name <<value>>
```

The bare form assigns an empty value. In the assigned form, the first `<<` and
final `>>` delimit the value. The value may itself contain `<<` or `>>`.

#### In-text definitions

An in-text definition has one of these forms:

```text
<boundary>name<decorators>##<<
##name<decorators>##<<
```

`<boundary>` is the beginning of text content, a space, `{`, `(`, `[`, or the
position immediately after an active value closer. The boundary is retained.
The second form uses an explicit `##` opener, which is consumed, and may occur
at any position.

The `##<<` terminator must be directly adjacent to the name or final decorator.
Any intervening backslash prevents recognition, regardless of the number of
backslashes.

An in-text definition may carry a same-line value:

```text
name##<<value>>##
```

The value begins after `##<<` and ends before the first active `>>##` on the
same line. Within a confirmed value, all other characters—including spaces,
brackets, pipes, and `##<<`—are value text. If the line contains no active
closer, the definition has an empty value and scanning restarts after `##<<` as
ordinary text; that remaining text may contain another definition.

A run of consecutive backslashes immediately before `>>##` controls whether
the closer is active. An even count, including zero, is active; an odd count
escapes the closer. The escaping backslash is removed from the value. An active
closer is consumed eagerly, and its ending position is a new definition
boundary. Definitions can therefore be chained:

```writerly
##first##<<first value>>##second##<<second value>>##
```

The complete in-text definition grammar applies to fenced code-block content,
but not to opening or closing fence lines.

#### Usages

A usage is `>>name`. Outside fenced code blocks it has no left-boundary
requirement. Usages are not recognized inside code-block content or on fence
lines.

A run of consecutive backslashes immediately before `>>` controls whether the
usage is active. An even count, including zero, is active; an odd count escapes
the usage:

```text
>>name       active
\>>name      escaped
\\>>name     active
\\\>>name    escaped
```

The Writerly parser preserves these backslashes. Removing usage escapes,
materializing definitions, interpreting definition values, and resolving usages
belong to later desugaring stages.

### Example

Given this Writerly source, patterned after a project chapter:

````writerly
|> Chapter
    title=An illustrative chapter

    This opening paragraph has three lines,
    the third of which starts with an  
    \ escaped space, and the second of which has two trailing spaces.


    |> Example
        label=A small program
        !! class=draft
        style=color:red
        ```gleam&id=answer&listing=true
        pub fn answer() {
          42
        }
        ```

    !! This comment block remains
    !! available to later processing.
    \```text, not a code fence
````

Parsing and conversion produce the following serialized VXML:

```vxml
<> Chapter
  title=An illustrative chapter
  <> WriterlyBlankLine
  <>
    'This opening paragraph has three lines,'
    'the third of which starts with an  '
    ' escaped space, and the second of which has two trailing spaces.'
  <> WriterlyBlankLine
  <> WriterlyBlankLine
  <> Example
    label=A small program
    WriterlyCommentedAttribute1Spaces=class=draft
    style=color:red
    <> WriterlyCodeBlock
      WriterlyCodeBlockInfoStringPrefix=gleam
      id=answer
      listing=true
      <>
        'pub fn answer() {'
        '  42'
        '}'
  <> WriterlyBlankLine
  <> WriterlyComment
    <>
      ' This comment block remains'
      ' available to later processing.'
  <>
    '```text, not a code fence'
```

The in-memory VXML additionally associates a `Blame` value with every element,
attribute, text node, and text line. The serialized form above omits those
values.
