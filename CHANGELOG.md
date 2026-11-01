# Changelog

## 0.7.0 — Unreleased

- Add `input_lines_to_writerlys_with_errors` and
  `string_to_writerlys_with_errors`, which recover from parse errors and return
  every error in the order found, together with the parsed nodes. A
  mis-indented line moves back with its block, an invalid tag still parses as a
  tag, and an unclosed code block ends where its indentation ends, so one
  mistake is reported once. `input_lines_to_writerlys` is now built on them and
  returns the same first error as before (a differential test of 80,000
  documents matched the previous parser exactly).
- **Breaking:** Remove all file access so the package is target- and
  host-agnostic, and usable from the browser on the JavaScript target.
  `simplifile` is no longer a dependency, and no generated JavaScript module
  imports a `node:*` module. Requires `vxml` 3.0.0.
- **Breaking:** Replace `assemble_input_lines(path)` and
  `assemble_input_lines_with_path_selector(path, selector)` with
  `assemble_sources(root, sources)` and
  `assemble_sources_with_path_selector(root, sources, selector)`, which take a
  list of the new `SourceFile(path, contents)` type with paths relative to
  `root`. Assembly rules (`.wly` only, `#` commenting, `__parent.wly` nesting,
  sort order, and blame paths) are unchanged; for the same files on disk the
  new functions return the same `DirTree` and `InputLine`s as before.
- **Breaking:** `AssemblyError` drops `ReadFileError` and
  `ReadFileOrDirectoryError`, and gains `InvalidSourcePath` and
  `DuplicateSourcePath`.
- `#` commenting now applies to path components below the root only. Before,
  a root directory path with a component starting with `#` excluded every file.
- A source list's order no longer affects the result.
- Fix stack overflows on JavaScript for long documents. The parser recursed
  once per sibling node, text line, comment line, attribute, and code-block
  line, and overflowed at about 880 sibling tags in browsers (831 in Node).
  The parsing loops now compile to `while` loops, so stack depth follows
  nesting only; 200,000 siblings or lines parse, and parsing is about 20%
  faster. Results and errors are unchanged: a differential test of 60,000
  random documents matched the previous parser exactly.

**Migration:** read the files yourself, or on Erlang use
`vxml_pipeline/writerly_defaults.read_writerly_sources(path)`, which returns
the root and sources for a file or directory path:

```gleam
use #(root, sources) <- result.try(wd.read_writerly_sources(path))
writerly.assemble_sources(root, sources)
|> result.map_error(wd.SourceAssemblyError)
```
