//// Parse, serialize, assemble, and convert Writerly documents.
////
//// Writerly is an indentation-based markup language descended from
//// [Elm-Markup](https://github.com/mdgriffith/elm-markup). It represents
//// elements, attributes, paragraphs, blank lines, comments, and fenced code
//// blocks, and converts them to and from VXML.

import dirtree.{type DirTree} as dt
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/regexp.{type Regexp}
import gleam/result
import gleam/string.{inspect as ins}
import on
import vxml.{type Attr, type Line, type VXML, Attr, Line, T, V}
import vxml/blame.{type Blame, prepend_comment as pc} as bl
import vxml/io_lines.{type InputLine, type OutputLine, InputLine, OutputLine} as io_l

// ************************************************************
// public types
// ************************************************************

/// A node in a parsed Writerly document.
///
/// Every node and its contained VXML values retain source-provenance `Blame`.
pub type Writerly {
  BlankLine(blame: Blame)
  Paragraph(blame: Blame, lines: List(Line))
  Comment(blame: Blame, lines: List(Line))
  CodeBlock(blame: Blame, attrs: List(Attr), lines: List(Line))
  Tag(blame: Blame, name: String, attrs: List(Attr), children: List(Writerly))
}

/// An error encountered while parsing Writerly source.
pub type ParseError {
  BadTag(blame: Blame, bad_name: String)
  BadKey(blame: Blame, bad_key: String)
  IndentationTooLarge(
    blame: Blame,
    expected: String,
    found: String,
    line: String,
  )
  IndentationNotMultipleOfFour(blame: Blame, line: String)
  CodeBlockInfoStartsWithSpace(blame: Blame, bad_info: String)
  CodeBlockNotClosed(blame: Blame)
  CodeBlockUnwantedAnnotationAtClose(
    blame: Blame,
    opening_blame: Blame,
    annotation: String,
  )
  ExcessiveLeadingAttributeWhitespace(blame: Blame, maximum: Int, found: Int)
  NonUniqueRoot(blame: Blame)
  MissingRoot(blame: Blame)
}

/// A Writerly source file to assemble, identified by its path relative to the
/// root of the document, for example `"chapter1/__parent.wly"`.
pub type SourceFile {
  SourceFile(path: String, contents: String)
}

/// An error encountered while assembling Writerly source files.
pub type AssemblyError {
  /// No eligible `.wly` file sits directly at the root.
  NoFilesFound(String)
  /// A source path is empty, absolute, or contains an empty, `.`, or `..`
  /// component.
  InvalidSourcePath(String)
  /// Two source files have the same path.
  DuplicateSourcePath(String)
}

/// An error encountered while converting VXML to Writerly or serializing
/// Writerly source.
pub type SerializationError {
  EmptyTextNode(blame: Blame)
  MalformedBlankLine(blame: Blame)
  MalformedCodeBlock(blame: Blame)
  MalformedComment(blame: Blame)
  EmptyParagraph(blame: Blame)
  EmptyComment(blame: Blame)
  DuplicateCodeBlockInfoStringPrefix(blame: Blame)
  ExcessiveLeadingAttributeWhitespaceInSerialization(
    blame: Blame,
    maximum: Int,
    found: Int,
  )
}

const commented_attribute_key_prefix = "WriterlyCommentedAttribute"

const commented_attribute_key_suffix = "Spaces"

const maximum_leading_attribute_spaces = 100

/// The synthetic VXML attribute key used for the nonempty, unmarked prefix
/// of a code block's info string: the part before its first unescaped
/// `&key=value` annotation. The attribute is absent when that prefix is empty.
pub const code_block_info_string_prefix_attribute_key = "WriterlyCodeBlockInfoStringPrefix"

/// Returns the encoded number of spaces in a Writerly commented attribute.
/// Only keys encoding between zero and 100 spaces are recognized.
pub fn commented_attribute_spaces(key: String) -> Option(Int) {
  case string.starts_with(key, commented_attribute_key_prefix) {
    False -> None
    True ->
      case string.ends_with(key, commented_attribute_key_suffix) {
        False -> None
        True -> {
          let encoded =
            key
            |> string.drop_start(string.length(commented_attribute_key_prefix))
            |> string.drop_end(string.length(commented_attribute_key_suffix))

          case int.parse(encoded) {
            Ok(spaces)
              if spaces >= 0 && spaces <= maximum_leading_attribute_spaces
            -> Some(spaces)
            _ -> None
          }
        }
      }
  }
}

/// Returns whether a key is a valid Writerly commented-attribute encoding.
pub fn is_commented_attribute_key(key: String) -> Bool {
  commented_attribute_spaces(key) != None
}

/// Constructs a Writerly commented-attribute key for a bounded space count.
pub fn commented_attribute_key(spaces: Int) -> Option(String) {
  case spaces >= 0 && spaces <= maximum_leading_attribute_spaces {
    True -> Some(make_commented_attribute_key(spaces))
    False -> None
  }
}

fn make_commented_attribute_key(spaces: Int) -> String {
  commented_attribute_key_prefix
  <> int.to_string(spaces)
  <> commented_attribute_key_suffix
}

fn split_leading_spaces(value: String, spaces: Int) -> #(Int, String) {
  case string.starts_with(value, " ") {
    True -> split_leading_spaces(string.drop_start(value, 1), spaces + 1)
    False -> #(spaces, value)
  }
}

fn leading_attribute_whitespace_count(value: String, count: Int) -> Int {
  case value {
    " " <> rest | "\t" <> rest ->
      leading_attribute_whitespace_count(rest, count + 1)
    _ -> count
  }
}

fn trim_trailing_attribute_whitespace(value: String) -> String {
  case string.ends_with(value, " ") || string.ends_with(value, "\t") {
    True -> trim_trailing_attribute_whitespace(string.drop_end(value, 1))
    False -> value
  }
}

fn parse_attribute_value(
  blame: Blame,
  raw_value: String,
) -> Result(String, ParseError) {
  let whitespace = leading_attribute_whitespace_count(raw_value, 0)
  case whitespace > maximum_leading_attribute_spaces {
    True ->
      Error(ExcessiveLeadingAttributeWhitespace(
        blame,
        maximum_leading_attribute_spaces,
        whitespace,
      ))
    False -> Ok(trim_trailing_attribute_whitespace(raw_value))
  }
}

// The API covers five areas of responsibility:
//
//    1. assembling List(InputLine) from in-memory source files
//    2. List(InputLine) -> Writerly (parsing)
//    3. Writerly -> VXML
//    4. VXML -> Writerly
//    5. Writerly -> List(OutputLine) / String / String (debug table)
//
// See 'PART 1', 'PART 2', 'PART 3', 'PART 4', 'PART 5' below.

// ************************************************************
// PART 1
//
// List(SourceFile) -> List(InputLine)   // Result
//
// pub fn assemble_sources
// pub fn assemble_sources_with_path_selector
// ************************************************************

fn file_is_not_commented(path: String) -> Bool {
  !{ string.contains(path, "/#") || string.starts_with(path, "#") }
}

fn file_is_selected_or_has_selected_descendant(
  path_selector: fn(String) -> Bool,
  path: String,
  all_paths: List(String),
) -> Bool {
  path_selector(path)
  || {
    string.ends_with(path, "__parent.wly")
    && {
      let prefix = path |> string.drop_end(12)
      list.any(all_paths, fn(x) {
        string.starts_with(x, prefix) && path_selector(x)
      })
    }
  }
}

fn shortname_for_blame(path: String, dirname: String) -> String {
  assert string.starts_with(path, dirname)
  let length_to_drop = case string.ends_with(dirname, "/") || dirname == "" {
    True -> string.length(dirname)
    False -> string.length(dirname) + 1
  }
  string.drop_start(path, length_to_drop)
}

fn input_lines_for_file_at_depth(
  sources: Dict(String, String),
  dirname: String,
  path: String,
  depth: Int,
) -> List(InputLine) {
  let shortname = shortname_for_blame(path, dirname)
  case shortname == "" {
    True ->
      panic as {
        "no shortname left after removing dirname '"
        <> dirname
        <> "' from path '"
        <> path
        <> "'"
      }
    False -> shortname
  }

  case dict.get(sources, shortname) {
    Ok(contents) -> io_l.string_to_input_lines(contents, shortname, 4 * depth)
    Error(_) -> panic as { "no source file for assembled path '" <> path <> "'" }
  }
}

fn dir_and_filename_2_path(dir: String, path: String) -> String {
  case dir {
    "" -> path
    _ -> dir <> "/" <> path
  }
}

fn drop_slash(s: String) {
  case string.ends_with(s, "/") {
    True -> string.drop_end(s, 1)
    False -> s
  }
}

fn is_direct_relative_path(path: String) -> Bool {
  !string.contains(path, "/")
}

fn is_valid_source_path(path: String) -> Bool {
  path
  |> string.split("/")
  |> list.all(fn(component) {
    component != "" && component != "." && component != ".."
  })
}

/// Checks the source paths and returns the eligible `.wly` paths, sorted.
fn relative_paths_of_uncommented_wly(
  root: String,
  sources: List(SourceFile),
) -> Result(List(String), AssemblyError) {
  use paths <- on.ok(
    list.try_fold(sources, [], fn(seen, source) {
      use <- on.false_true(is_valid_source_path(source.path), fn() {
        Error(InvalidSourcePath(source.path))
      })
      use <- on.true_false(list.contains(seen, source.path), fn() {
        Error(DuplicateSourcePath(source.path))
      })
      Ok([source.path, ..seen])
    }),
  )

  let relative_filepaths =
    paths
    |> list.filter(string.ends_with(_, ".wly"))
    |> list.filter(file_is_not_commented)
    |> list.sort(string.compare)

  case list.any(relative_filepaths, is_direct_relative_path) {
    True -> Ok(relative_filepaths)
    False -> Error(NoFilesFound("no direct .wly files found in: " <> root))
  }
}

fn input_lines_for_dirtree_at_depth(
  sources: Dict(String, String),
  original_dirname: String,
  acc: String,
  tree: DirTree,
  depth: Int,
) -> List(InputLine) {
  let added_depth = fn(prefixes: List(String), path: String) {
    list.fold(prefixes, 0, fn(acc, prefix) {
      case
        string.starts_with(path, prefix) && path != prefix <> "__parent.wly"
      {
        True -> acc + 1
        False -> acc
      }
    })
  }

  let parent_prefixes = fn(contents: List(DirTree)) -> List(String) {
    list.fold(contents, [], fn(acc, tree) {
      case string.ends_with(tree.name, "__parent.wly") {
        True -> {
          let assert dt.Filepath(_) = tree
          let prefix = string.drop_end(tree.name, 12)
          assert !list.contains(acc, prefix)
          [prefix, ..acc]
        }
        False -> acc
      }
    })
  }

  case tree {
    dt.Filepath(path) -> {
      assert string.ends_with(path, ".wly")
      input_lines_for_file_at_depth(
        sources,
        original_dirname,
        dir_and_filename_2_path(acc, path),
        depth,
      )
    }

    dt.Dirpath(path, contents) -> {
      let prefixes = parent_prefixes(contents)
      contents
      |> list.flat_map(fn(subtree) {
        let depth = depth + added_depth(prefixes, subtree.name)
        input_lines_for_dirtree_at_depth(
          sources,
          original_dirname,
          dir_and_filename_2_path(acc, path),
          subtree,
          depth,
        )
      })
    }
  }
}

/// Assembles selected `.wly` files from in-memory sources.
///
/// Source paths are relative to the document root and use `/` separators;
/// `root` names the root of the returned `DirTree` and is not part of any
/// blame path. Only paths ending in `.wly` whose components do not begin with
/// `#` are assembled, and at least one of them must sit directly at the root.
///
/// The selector receives the relative source paths. A selected file is
/// included along with any `__parent.wly` files needed to contain it. The
/// returned directory tree records the selected layout; the input lines retain
/// their relative source paths and are indented according to that tree.
pub fn assemble_sources_with_path_selector(
  root: String,
  sources: List(SourceFile),
  path_selector: fn(String) -> Bool,
) -> Result(#(DirTree, List(InputLine)), AssemblyError) {
  let dirname = drop_slash(root)

  use paths <- on.ok(relative_paths_of_uncommented_wly(root, sources))

  let contents =
    sources
    |> list.map(fn(source) { #(source.path, source.contents) })
    |> dict.from_list

  let paths =
    paths
    |> list.filter(file_is_selected_or_has_selected_descendant(
      path_selector,
      _,
      paths,
    ))

  let drop_suffix = fn(name) {
    case string.ends_with(name, "__parent.wly") {
      True -> string.drop_end(name, 12)
      False -> name
    }
  }

  let tree =
    dt.from_terminals(dirname, paths)
    |> dt.sort(fn(t1, t2) {
      string.compare(t1.name |> drop_suffix, t2.name |> drop_suffix)
    })

  let lines = input_lines_for_dirtree_at_depth(contents, dirname, "", tree, 0)

  Ok(#(tree, lines))
}

/// Assembles every eligible `.wly` file from in-memory sources.
///
/// See `assemble_sources_with_path_selector` for the rules and for selective
/// assembly.
pub fn assemble_sources(
  root: String,
  sources: List(SourceFile),
) -> Result(#(DirTree, List(InputLine)), AssemblyError) {
  assemble_sources_with_path_selector(root, sources, fn(_) { True })
}

// ************************************************************
// PART 2
//
// List(InputLine) -> List(Writerly)      // Result
// String -> Writerly                     // Result
// 
// pub fn input_lines_to_writerlys
// pub fn input_lines_to_writerly
// pub fn string_to_writerlys
// pub fn string_to_writerly
// ************************************************************

type InputLines =
  List(InputLine)

type Encounter {
  EncounteredFileEnd
  EncounteredBlankLine(blame: Blame, indent: Int)
  EncounteredNonMod4Indent(blame: Blame, indent: Int, suffix: String)
  EncounteredHigherIndent(
    blame: Blame,
    indent: Int,
    suffix: String,
    original_indent: Int,
    higher_indent: Int,
  )
  EncounteredLowerIndent(blame: Blame, indent: Int, suffix: String)
  EncounteredTextLine(blame: Blame, suffix: String)
  EncounteredTagLine(blame: Blame, suffix: String)
  EncounteredCommentLine(blame: Blame, suffix: String)
  EncounteredCodeFence(blame: Blame, suffix: String)
}

fn nonempty_suffix_encounter(blame: Blame, suffix: String) -> Encounter {
  case suffix {
    "|>" <> _ -> EncounteredTagLine(blame |> bl.set_anchored, suffix)
    "!!" <> _ -> EncounteredCommentLine(blame, suffix)
    "```" <> _ -> EncounteredCodeFence(blame, suffix)
    _ -> EncounteredTextLine(blame, suffix)
  }
}

fn input_lines_encounter(
  indent: Int,
  head: InputLines,
) -> #(Encounter, InputLines) {
  use first, rest <- on.empty_nonempty(head, fn() { #(EncounteredFileEnd, []) })

  let InputLine(blame, first_indent, suffix) = first

  use <- on.true_false(suffix == "", fn() {
    #(EncounteredBlankLine(blame, first_indent), rest)
  })

  use <- on.true_false(first_indent % 4 != 0, fn() {
    #(EncounteredNonMod4Indent(blame, first_indent, suffix), rest)
  })

  use <- on.true_false(first_indent < indent, fn() {
    #(EncounteredLowerIndent(blame, first_indent, suffix), rest)
  })

  use <- on.true_false(first_indent > indent, fn() {
    #(
      EncounteredHigherIndent(blame, first_indent, suffix, indent, first_indent),
      rest,
    )
  })

  let encounter = nonempty_suffix_encounter(blame, suffix)

  #(encounter, rest)
}

fn drop_text_line_escape(
  blame: Blame,
  suffix: String,
  rgxs: OurRegexes,
) -> Line {
  case regexp.check(rgxs.includes_bol_te_escape, suffix) {
    True -> Line(blame |> bl.advance(1), suffix |> string.drop_start(1))
    False -> Line(blame, suffix)
  }
}

// The parsing loops below are self-recursive in tail position, with results
// accumulated in reverse, so that Gleam compiles them to loops on JavaScript.
// Only nested tags recurse, bounding stack depth by the document's nesting
// rather than by its length; browsers overflow after a few thousand frames.

fn parse_text_lines_at_indent(
  indent: Int,
  head: InputLines,
  rgxs: OurRegexes,
  acc: List(Line),
) -> #(List(Line), Encounter, InputLines) {
  let #(encounter, rest) = input_lines_encounter(indent, head)

  case encounter {
    EncounteredTextLine(blame, suffix) -> {
      let line = drop_text_line_escape(blame, suffix, rgxs)
      parse_text_lines_at_indent(indent, rest, rgxs, [line, ..acc])
    }
    _ -> #(list.reverse(acc), encounter, rest)
  }
}

fn parse_comment_lines_at_indent(
  indent: Int,
  head: InputLines,
  acc: List(Line),
) -> #(List(Line), Encounter, InputLines) {
  let #(encounter, rest) = input_lines_encounter(indent, head)

  case encounter {
    EncounteredCommentLine(blame, suffix) -> {
      let line = Line(blame |> bl.advance(2), suffix |> string.drop_start(2))
      parse_comment_lines_at_indent(indent, rest, [line, ..acc])
    }
    _ -> #(list.reverse(acc), encounter, rest)
  }
}

fn parse_attrs_at_indent(
  indent: Int,
  head: InputLines,
  rgxs: OurRegexes,
  acc: List(Attr),
  errors: List(ParseError),
) -> #(List(Attr), Encounter, InputLines, List(ParseError)) {
  let #(encounter, rest) = input_lines_encounter(indent, head)

  case encounter {
    EncounteredCommentLine(blame, suffix) -> {
      let #(spaces, val) =
        suffix |> string.drop_start(2) |> split_leading_spaces(0)
      let errors = case spaces > maximum_leading_attribute_spaces {
        True -> [
          ExcessiveLeadingAttributeWhitespace(
            blame,
            maximum_leading_attribute_spaces,
            spaces,
          ),
          ..errors
        ]
        False -> errors
      }
      let spaces = int.min(spaces, maximum_leading_attribute_spaces)
      let attr = Attr(blame, make_commented_attribute_key(spaces), val)
      parse_attrs_at_indent(indent, rest, rgxs, [attr, ..acc], errors)
    }

    EncounteredTextLine(blame, suffix) ->
      case text_line_attr(blame, suffix, rgxs) {
        #(Some(attr), error) ->
          parse_attrs_at_indent(
            indent,
            rest,
            rgxs,
            [attr, ..acc],
            prepend_option(errors, error),
          )
        #(None, _) -> #(list.reverse(acc), encounter, rest, errors)
      }

    _ -> #(list.reverse(acc), encounter, rest, errors)
  }
}

fn prepend_option(list: List(a), item: Option(a)) -> List(a) {
  case item {
    Some(item) -> [item, ..list]
    None -> list
  }
}

// The attribute on a `key=value` text line, or `None` if the line is not one.
fn text_line_attr(
  blame: Blame,
  suffix: String,
  rgxs: OurRegexes,
) -> #(Option(Attr), Option(ParseError)) {
  assert suffix != ""
  assert !string.starts_with(suffix, "!!")
  assert !string.starts_with(suffix, "|>")

  use #(key, val) <- on.error_ok(suffix |> string.split_once("="), fn(_) {
    #(None, None)
  })

  use <- on.true_false(
    key == ""
      || string.contains(key, " ")
      || !regexp.check(rgxs.is_valid_key, key),
    fn() { #(None, None) },
  )

  let #(val, error) = parse_attribute_value_recovering(blame, val)
  #(Some(Attr(blame, key, val)), error)
}

fn parse_attribute_value_recovering(
  blame: Blame,
  raw_value: String,
) -> #(String, Option(ParseError)) {
  case parse_attribute_value(blame, raw_value) {
    Ok(value) -> #(value, None)
    Error(error) -> #(
      raw_value |> string.trim_start |> trim_trailing_attribute_whitespace,
      Some(error),
    )
  }
}

// Splits the trailing blank lines off `acc`, which holds siblings in reverse.
// Returns the blank lines in document order and the remaining siblings, still
// in reverse.
fn split_trailing_blank_lines(
  acc: List(Writerly),
  blanks: List(Writerly),
) -> #(List(Writerly), List(Writerly)) {
  case acc {
    [BlankLine(..) as blank, ..rest] ->
      split_trailing_blank_lines(rest, [blank, ..blanks])
    _ -> #(blanks, acc)
  }
}

fn finish_siblings(
  acc: List(Writerly),
  encounter: Encounter,
  rest: InputLines,
  errors: List(ParseError),
) -> #(List(Writerly), List(Writerly), Encounter, InputLines, List(ParseError)) {
  let #(blanks, siblings) = split_trailing_blank_lines(acc, [])
  #(list.reverse(siblings), blanks, encounter, rest, errors)
}

// Moves a mis-indented line back by `by` spaces, together with the following
// lines indented at least as deeply, so one mistake is reported once.
fn shift_block(head: InputLines, by: Int) -> InputLines {
  case head {
    [] -> []
    [first, ..rest] ->
      shift_block_loop(rest, first.indent, by, [
        InputLine(..first, indent: first.indent - by),
      ])
  }
}

fn shift_block_loop(
  lines: InputLines,
  from_indent: Int,
  by: Int,
  acc: InputLines,
) -> InputLines {
  case lines {
    [InputLine(suffix: "", ..) as blank, ..rest] ->
      shift_block_loop(rest, from_indent, by, [blank, ..acc])
    [line, ..rest] if line.indent >= from_indent ->
      shift_block_loop(rest, from_indent, by, [
        InputLine(..line, indent: line.indent - by),
        ..acc
      ])
    _ -> list.fold(acc, lines, fn(lines, line) { [line, ..lines] })
  }
}

/// Parses the siblings at `indent`, up to a line of lower indentation or the
/// end of input. Returns the siblings without their trailing blank lines, the
/// trailing blank lines (which the caller hoists out of a closing tag), the
/// encounter and input that stopped the run, and the errors found so far,
/// most recent first.
///
/// `acc` holds the siblings parsed so far, most recent first. A child tag's
/// trailing blank lines become ordinary siblings after the tag here, and
/// trailing blank lines at the end of the run are split off again by
/// `finish_siblings`. After an error the parser repairs the spot and goes on,
/// so later errors are found too.
fn parse_writerlys_at_indent_from_encounter(
  indent: Int,
  rest: InputLines,
  rgxs: OurRegexes,
  encounter: Encounter,
  acc: List(Writerly),
  errors: List(ParseError),
) -> #(List(Writerly), List(Writerly), Encounter, InputLines, List(ParseError)) {
  case encounter {
    EncounteredFileEnd -> finish_siblings(acc, EncounteredFileEnd, [], errors)

    EncounteredBlankLine(blame, _) -> {
      let #(encounter, rest) = input_lines_encounter(indent, rest)
      parse_writerlys_at_indent_from_encounter(
        indent,
        rest,
        rgxs,
        encounter,
        [BlankLine(blame), ..acc],
        errors,
      )
    }

    EncounteredNonMod4Indent(blame, line_indent, suffix) -> {
      let target = int.min(line_indent / 4 * 4, indent)
      let head =
        shift_block([InputLine(blame, line_indent, suffix), ..rest], {
          line_indent - target
        })
      let #(encounter, rest) = input_lines_encounter(indent, head)
      parse_writerlys_at_indent_from_encounter(
        indent,
        rest,
        rgxs,
        encounter,
        acc,
        [IndentationNotMultipleOfFour(blame, suffix), ..errors],
      )
    }

    EncounteredHigherIndent(blame, _, suffix, indent, higher_indent) -> {
      let error =
        IndentationTooLarge(
          blame,
          "expected: " <> ins(indent),
          "found: " <> ins(higher_indent),
          "line: '" <> suffix <> "'",
        )
      let head =
        shift_block([InputLine(blame, higher_indent, suffix), ..rest], {
          higher_indent - indent
        })
      let #(encounter, rest) = input_lines_encounter(indent, head)
      parse_writerlys_at_indent_from_encounter(
        indent,
        rest,
        rgxs,
        encounter,
        acc,
        [error, ..errors],
      )
    }

    EncounteredLowerIndent(blame, suffix_indent, suffix) -> {
      assert suffix_indent <= indent
      assert suffix != ""
      case suffix_indent < indent {
        True -> finish_siblings(acc, encounter, rest, errors)
        False -> {
          let encounter = nonempty_suffix_encounter(blame, suffix)
          parse_writerlys_at_indent_from_encounter(
            indent,
            rest,
            rgxs,
            encounter,
            acc,
            errors,
          )
        }
      }
    }

    EncounteredCommentLine(blame, suffix) -> {
      let line = Line(blame |> bl.advance(2), suffix |> string.drop_start(2))
      let #(lines, encounter, rest) =
        parse_comment_lines_at_indent(indent, rest, [line])
      parse_writerlys_at_indent_from_encounter(
        indent,
        rest,
        rgxs,
        encounter,
        [Comment(blame, lines), ..acc],
        errors,
      )
    }

    EncounteredTextLine(blame, suffix) -> {
      let line = drop_text_line_escape(blame, suffix, rgxs)
      let #(lines, encounter, rest) =
        parse_text_lines_at_indent(indent, rest, rgxs, [line])
      parse_writerlys_at_indent_from_encounter(
        indent,
        rest,
        rgxs,
        encounter,
        [Paragraph(blame, lines), ..acc],
        errors,
      )
    }

    EncounteredTagLine(blame, suffix) -> {
      let tag = suffix |> string.drop_start(2) |> string.trim
      let errors = case regexp.check(rgxs.is_valid_tag, tag) {
        True -> errors
        False -> [BadTag(blame, tag), ..errors]
      }
      let #(attrs, children, blanks, encounter, rest, errors) =
        parse_tag_contents(indent, rest, rgxs, errors)
      let acc =
        list.fold(
          blanks,
          [Tag(blame, tag, attrs, children), ..acc],
          fn(acc, blank) { [blank, ..acc] },
        )
      parse_writerlys_at_indent_from_encounter(
        indent,
        rest,
        rgxs,
        encounter,
        acc,
        errors,
      )
    }

    EncounteredCodeFence(blame, suffix) -> {
      let #(attrs, info_errors) =
        code_block_info_to_attrs(
          blame |> bl.advance(3),
          suffix |> string.drop_start(3),
          rgxs,
        )
      let #(lines, rest, close_error) =
        parse_code_block_at_indent(indent, rest, blame, rgxs, [])
      let errors =
        list.fold(info_errors, errors, fn(errors, error) { [error, ..errors] })
        |> prepend_option(close_error)
      let #(encounter, rest) = input_lines_encounter(indent, rest)
      parse_writerlys_at_indent_from_encounter(
        indent,
        rest,
        rgxs,
        encounter,
        [CodeBlock(blame, attrs, lines), ..acc],
        errors,
      )
    }
  }
}

// Parses a tag's attributes and children, one indentation level deeper. This
// is the parser's only non-tail recursion, so stack depth follows nesting.
fn parse_tag_contents(
  indent: Int,
  rest: InputLines,
  rgxs: OurRegexes,
  errors: List(ParseError),
) -> #(
  List(Attr),
  List(Writerly),
  List(Writerly),
  Encounter,
  InputLines,
  List(ParseError),
) {
  let #(attrs, encounter, rest, errors) =
    parse_attrs_at_indent(indent + 4, rest, rgxs, [], errors)
  let #(children, blanks, encounter, rest, errors) =
    parse_writerlys_at_indent_from_encounter(
      indent + 4,
      rest,
      rgxs,
      encounter,
      [],
      errors,
    )
  #(attrs, children, blanks, encounter, rest, errors)
}

// An unclosed block ends where its indentation ends; the line that ended it
// is left for the caller.
fn parse_code_block_at_indent(
  indent: Int,
  head: InputLines,
  initial_blame: Blame,
  rgxs: OurRegexes,
  acc: List(Line),
) -> #(List(Line), InputLines, Option(ParseError)) {
  case head {
    [] -> #(list.reverse(acc), [], Some(CodeBlockNotClosed(initial_blame)))
    [InputLine(blame, first_indent, suffix), ..rest] ->
      case code_block_line(indent, blame, first_indent, suffix, rgxs) {
        CodeBlockContent(line) ->
          parse_code_block_at_indent(indent, rest, initial_blame, rgxs, [
            line,
            ..acc
          ])
        CodeBlockClose("") -> #(list.reverse(acc), rest, None)
        CodeBlockClose(annotation) -> #(
          list.reverse(acc),
          rest,
          Some(CodeBlockUnwantedAnnotationAtClose(
            blame,
            initial_blame,
            annotation,
          )),
        )
        CodeBlockUnclosed -> #(
          list.reverse(acc),
          head,
          Some(CodeBlockNotClosed(initial_blame)),
        )
      }
  }
}

type CodeBlockLine {
  CodeBlockContent(Line)
  CodeBlockClose(annotation: String)
  CodeBlockUnclosed
}

fn code_block_line(
  indent: Int,
  blame: Blame,
  first_indent: Int,
  suffix: String,
  rgxs: OurRegexes,
) -> CodeBlockLine {
  use <- on.true_false(first_indent > indent, fn() {
    let spaces = string.repeat(" ", first_indent - indent)
    let content = spaces <> suffix
    CodeBlockContent(Line(blame |> bl.advance(indent - first_indent), content))
  })

  use <- on.true_false(suffix == "", fn() { CodeBlockContent(Line(blame, "")) })

  use <- on.true_false(first_indent < indent, fn() { CodeBlockUnclosed })

  use <- on.true_false(suffix |> string.starts_with("```"), fn() {
    CodeBlockClose(suffix |> string.drop_start(3) |> string.trim_end())
  })

  let #(blame, suffix) = case
    regexp.check(rgxs.includes_bol_cb_escape, suffix)
  {
    True -> #(blame |> bl.advance(1), suffix |> string.drop_start(1))
    False -> #(blame, suffix)
  }

  CodeBlockContent(Line(blame, suffix))
}

fn attrs_to_code_block_info(
  attrs: List(Attr),
) -> Result(String, SerializationError) {
  let #(info_attrs, attrs) =
    list.partition(attrs, fn(attr) {
      attr.key == code_block_info_string_prefix_attribute_key
    })
  use info <- on.ok(case info_attrs {
    [] -> Ok(None)
    [info] -> Ok(Some(info))
    [_, duplicate, ..] ->
      Error(DuplicateCodeBlockInfoStringPrefix(duplicate.blame))
  })
  let escape = fn(s) {
    s
    |> string.replace("\\", "\\\\")
    |> string.replace("&", "\\&")
  }
  let keyval_maker = fn(attr: Attr) -> Result(String, SerializationError) {
    use value <- on.ok(attribute_value_for_serialization(attr))
    Ok({ attr.key <> "=" <> value } |> escape)
  }
  use keyvals <- on.ok(attrs |> list.try_map(keyval_maker))
  let info = case info {
    None -> ""
    Some(info) -> info.val |> string.trim |> escape
  }
  Ok([info, ..keyvals] |> string.join("&"))
}

fn code_block_info_to_attrs(
  blame: Blame,
  info: String,
  rgxs: OurRegexes,
) -> #(List(Attr), List(ParseError)) {
  let info = info |> string.trim_end()

  use <- on.true_false(info == "", fn() { #([], []) })

  use <- on.true_false(info |> string.starts_with(" "), fn() {
    let trimmed = string.trim_start(info)
    let spaces = string.length(info) - string.length(trimmed)
    let #(attrs, errors) =
      code_block_info_to_attrs(blame |> bl.advance(spaces), trimmed, rgxs)
    #(attrs, [CodeBlockInfoStartsWithSpace(blame, info), ..errors])
  })

  use <- on.false_true(info |> string.contains("&"), fn() {
    #([Attr(blame, code_block_info_string_prefix_attribute_key, info)], [])
  })

  let pieces = regexp.split(rgxs.unescaped_ampersand, info)

  let pieces =
    list.map_fold(pieces, #(blame, ""), fn(acc, p) {
      let #(blame, last_piece) = acc
      let acc = #(blame |> bl.advance(last_piece |> string.length), p)
      #(acc, acc)
    })
    |> pair.second

  let pieces =
    list.index_map(pieces, fn(p, i) {
      let #(blame, p) = p
      let p = case i % 3 {
        0 -> p |> string.replace("\\&", "&") |> string.replace("\\\\", "\\")
        1 -> p |> string.replace("\\\\", "\\")
        2 -> p
        _ -> panic
      }
      #(blame, p)
    })

  let keyvals =
    list.fold(pieces, #(None, 0, []), fn(acc, p) {
      let #(maybe, i, so_far) = acc
      case i % 3 {
        0 -> {
          assert maybe == None
          #(Some(p), i + 1, so_far)
        }
        1 -> {
          let assert Some(#(prev_blame, prev_p)) = maybe
          let #(_, p) = p
          #(None, i + 1, [#(prev_blame, prev_p <> p), ..so_far])
        }
        2 -> {
          assert maybe == None
          #(None, i + 1, so_far)
        }
        _ -> panic
      }
    })

  let keyvals = case keyvals.0 {
    None -> keyvals.2 |> list.reverse
    Some(x) -> [x, ..keyvals.2] |> list.reverse
  }

  let assert [info, ..keyvals] = keyvals
  let info = Attr(info.0, code_block_info_string_prefix_attribute_key, info.1)

  let #(keyvals, errors) =
    list.fold(keyvals, #([], []), fn(acc, kv) {
      let #(attrs, errors) = acc
      let #(blame, kv) = kv
      let #(key, val) =
        string.split_once(kv, "=")
        |> result.unwrap(#(kv, ""))
      let key = string.trim(key)
      let #(val, value_error) = parse_attribute_value_recovering(blame, val)
      let errors = prepend_option(errors, value_error)
      case regexp.check(rgxs.is_valid_key, key) {
        False -> #(attrs, [BadKey(blame, key), ..errors])
        True -> #([Attr(blame, key, val), ..attrs], errors)
      }
    })
  let keyvals = list.reverse(keyvals)

  let attrs = case info.val {
    "" -> keyvals
    _ -> [info, ..keyvals]
  }

  #(attrs, list.reverse(errors))
}

fn parse_writerlys_at_indent(
  indent: Int,
  head: InputLines,
  rgxs: OurRegexes,
) -> #(List(Writerly), List(Writerly), Encounter, InputLines, List(ParseError)) {
  let #(encounter, rest) = input_lines_encounter(indent, head)
  parse_writerlys_at_indent_from_encounter(
    indent,
    rest,
    rgxs,
    encounter,
    [],
    [],
  )
}

type OurRegexes {
  OurRegexes(
    is_valid_tag: Regexp,
    is_valid_key: Regexp,
    // te = 'text',       'includes_' = (as we parse source)
    includes_bol_te_escape: Regexp,
    // cb = 'code block', 'includes_' = (as we parse source)
    includes_bol_cb_escape: Regexp,
    // te = 'text',       'requires_' = (as we output source)
    requires_bol_te_escape: Regexp,
    // cb = 'code block', 'requires_' = (as we output source)
    requires_bol_cb_escape: Regexp,
    unescaped_ampersand: Regexp,
  )
}

fn our_regexes() -> OurRegexes {
  let assert Ok(is_valid_tag) =
    regexp.from_string("^[a-zA-Z_:][-a-zA-Z0-9._:]*$")
  let assert Ok(is_valid_key) =
    regexp.from_string("^[a-zA-Z_][-a-zA-Z0-9._:]*$")
  let assert Ok(includes_bol_te_escape) =
    regexp.from_string("^\\\\+(\\s|!!|```)")
  let assert Ok(includes_bol_cb_escape) = regexp.from_string("^\\\\+(```)")
  let assert Ok(requires_bol_te_escape) =
    regexp.from_string("^\\\\*(\\s|!!|```)")
  let assert Ok(requires_bol_cb_escape) = regexp.from_string("^\\\\*(```)")
  let assert Ok(unescaped_ampersand) =
    regexp.from_string("(?<!\\\\)(\\\\\\\\)*(&)")

  OurRegexes(
    is_valid_tag,
    is_valid_key,
    includes_bol_te_escape,
    includes_bol_cb_escape,
    requires_bol_te_escape,
    requires_bol_cb_escape,
    unescaped_ampersand,
  )
}

/// Parses input lines into zero or more top-level Writerly nodes.
pub fn input_lines_to_writerlys(
  lines: InputLines,
) -> Result(List(Writerly), ParseError) {
  case input_lines_to_writerlys_with_errors(lines) {
    #(writerlys, []) -> Ok(writerlys)
    #(_, [first, ..]) -> Error(first)
  }
}

/// Parses input lines into zero or more top-level Writerly nodes, recovering
/// from errors instead of stopping at the first one.
///
/// Returns the nodes and every error, in the order they were found. After an
/// error the parser repairs that spot (a mis-indented line moves back with its
/// block, an invalid tag still parses as a tag, an unclosed code block ends
/// where its indentation does) so that later errors are found too. The nodes
/// are only meaningful when there are no errors. With no errors, the nodes
/// are the same as `input_lines_to_writerlys` returns.
pub fn input_lines_to_writerlys_with_errors(
  lines: InputLines,
) -> #(List(Writerly), List(ParseError)) {
  let rgxs = our_regexes()
  let #(writerlys, _, _, _, errors) = parse_writerlys_at_indent(0, lines, rgxs)
  #(writerlys, list.reverse(errors))
}

fn is_not_blank_line(w: Writerly) -> Bool {
  case w {
    BlankLine(..) -> False
    _ -> True
  }
}

/// Parses input lines containing exactly one non-blank top-level node.
///
/// Top-level blank lines do not count toward cardinality. Returns `MissingRoot`
/// when there is no non-blank root and `NonUniqueRoot` when there is more than
/// one.
pub fn input_lines_to_writerly(
  lines: InputLines,
) -> Result(Writerly, ParseError) {
  use writerlys <- on.ok(input_lines_to_writerlys(lines))
  case list.filter(writerlys, is_not_blank_line) {
    [one] -> Ok(one)
    [] -> Error(MissingRoot(bl.no_blame))
    [one, ..] -> Error(NonUniqueRoot(one.blame))
  }
}

/// Parses a source string into zero or more top-level Writerly nodes.
///
/// `filename` is recorded in the source blame attached to parsed values.
pub fn string_to_writerlys(
  source: String,
  filename: String,
) -> Result(List(Writerly), ParseError) {
  source
  |> io_l.string_to_input_lines(filename, 0)
  |> input_lines_to_writerlys
}

/// Parses a source string into zero or more top-level Writerly nodes and every
/// error found. See `input_lines_to_writerlys_with_errors`.
pub fn string_to_writerlys_with_errors(
  source: String,
  filename: String,
) -> #(List(Writerly), List(ParseError)) {
  source
  |> io_l.string_to_input_lines(filename, 0)
  |> input_lines_to_writerlys_with_errors
}

/// Parses a source string containing exactly one non-blank top-level node.
///
/// `filename` is recorded in the source blame attached to parsed values.
pub fn string_to_writerly(
  source: String,
  filename: String,
) -> Result(Writerly, ParseError) {
  source
  |> io_l.string_to_input_lines(filename, 0)
  |> input_lines_to_writerly
}

// ************************************************************
// PART 3
//
// Writerly -> VXML, List(InputLine) -> VXML
//
// pub fn writerly_to_vxml
// pub fn input_lines_to_vxml
// ************************************************************

const writerly_blank_line_vxml_tag = "WriterlyBlankLine"

const writerly_code_block_vxml_tag = "WriterlyCodeBlock"

const writerly_comment_vxml_tag = "WriterlyComment"

/// Converts one Writerly node to its VXML representation.
///
/// Paragraphs become text nodes. Blank lines, comments, and code blocks use
/// the reserved `WriterlyBlankLine`, `WriterlyComment`, and
/// `WriterlyCodeBlock` element names.
pub fn writerly_to_vxml(t: Writerly) -> VXML {
  case t {
    BlankLine(blame) ->
      V(
        blame: blame,
        tag: writerly_blank_line_vxml_tag,
        attrs: [],
        children: [],
      )

    Paragraph(blame, lines) -> T(blame: blame, lines: lines)

    Comment(blame, lines) ->
      V(blame: blame, tag: writerly_comment_vxml_tag, attrs: [], children: [
        T(blame: blame, lines: lines),
      ])

    CodeBlock(blame, attrs, lines) ->
      V(
        blame: blame,
        tag: writerly_code_block_vxml_tag,
        attrs: attrs,
        children: case lines {
          [] -> []
          _ -> [T(blame: blame, lines: lines)]
        },
      )

    Tag(blame, tag, attrs, children) -> {
      V(
        blame: blame,
        tag: tag,
        attrs: attrs,
        children: children |> list.map(writerly_to_vxml),
      )
    }
  }
}

/// Converts Writerly nodes to VXML nodes in the same order.
pub fn writerlys_to_vxmls(writerlys: List(Writerly)) -> List(VXML) {
  writerlys |> list.map(writerly_to_vxml)
}

/// Parses input lines with one non-blank root and converts it to VXML.
pub fn input_lines_to_vxml(lines: InputLines) -> Result(VXML, ParseError) {
  input_lines_to_writerly(lines)
  |> result.map(writerly_to_vxml)
}

// ************************************************************
// PART 4
//
// VXML -> Writerly
//
// pub fn vxml_to_writerly
// pub fn vxmls_to_writerlys
// pub fn vxml_to_writerly
// ************************************************************

fn is_whitespace(s: String) -> Bool {
  string.trim(s) == ""
}

fn add_escape_in_string(s: String, re: Regexp) -> String {
  case regexp.check(re, s) {
    True -> "\\" <> s
    False -> s
  }
}

fn add_escapes_in_lines(contents: List(Line), re: Regexp) -> List(Line) {
  list.map(contents, fn(line) {
    Line(line.blame, line.content |> add_escape_in_string(re))
  })
}

fn process_vxml_t_node(
  blame: Blame,
  lines: List(Line),
) -> Result(Writerly, SerializationError) {
  let lines =
    lines
    |> list.index_map(fn(line, i) { #(i, line) })
    |> list.filter(fn(pair) {
      let #(index, line) = pair
      !is_whitespace(line.content)
      || index == 0
      || index == list.length(lines) - 1
    })
    |> list.map(pair.second)
  case lines {
    [] -> Error(EmptyTextNode(blame))
    [first, ..] -> Ok(Paragraph(first.blame, lines))
  }
}

fn vxml_to_writerly_internal(
  vxml: VXML,
) -> Result(Writerly, SerializationError) {
  case vxml {
    V(blame, tag, attrs, children) -> {
      case tag {
        _ if tag == writerly_blank_line_vxml_tag -> {
          case attrs, children {
            [], [] -> Ok(BlankLine(blame))
            _, _ -> Error(MalformedBlankLine(blame))
          }
        }
        _ if tag == writerly_code_block_vxml_tag -> {
          case children {
            [] -> Ok(CodeBlock(blame, attrs, []))
            [T(_, lines)] -> Ok(CodeBlock(blame, attrs, lines))
            _ -> Error(MalformedCodeBlock(blame))
          }
        }
        _ if tag == writerly_comment_vxml_tag -> {
          case children {
            [T(_, [_, ..] as lines)] -> Ok(Comment(blame, lines))
            _ -> Error(MalformedComment(blame))
          }
        }
        _ -> {
          use children <- on.ok(vxmls_to_writerlys(children))
          Ok(Tag(blame, tag, attrs, children))
        }
      }
    }
    T(blame, lines) -> process_vxml_t_node(blame, lines)
  }
}

/// Converts VXML nodes to Writerly nodes in the same order.
pub fn vxmls_to_writerlys(
  vxmls: List(VXML),
) -> Result(List(Writerly), SerializationError) {
  vxmls |> list.try_map(vxml_to_writerly_internal)
}

/// Converts VXML that corresponds to exactly one Writerly node.
///
pub fn vxml_to_writerly(vxml: VXML) -> Result(Writerly, SerializationError) {
  vxml_to_writerly_internal(vxml)
}

// ************************************************************
// PART 5-minus (annotating blames)
//
// Writerly -> Writerly
//
// fn annotate_blames
// ************************************************************

/// Adds structural descriptions to the blame comments throughout a tree.
///
/// This is intended for diagnostic tables. Source locations and node contents
/// are otherwise unchanged. Building a code-block description can fail when
/// its attributes cannot be serialized as a fence info string.
fn annotate_blames(writerly: Writerly) -> Result(Writerly, SerializationError) {
  case writerly {
    BlankLine(blame) -> Ok(BlankLine(blame |> pc("BlankLine")))
    Paragraph(blame, lines) ->
      Paragraph(
        blame |> pc("Paragraph"),
        list.index_map(lines, fn(line, i) {
          Line(
            line.blame
              |> pc("Paragraph > Line(" <> ins(i + 1) <> ")"),
            line.content,
          )
        }),
      )
      |> Ok
    Comment(blame, lines) ->
      Comment(
        blame |> pc("Comment"),
        list.index_map(lines, fn(line, i) {
          Line(
            line.blame
              |> pc("Comment > Line(" <> ins(i + 1) <> ")"),
            line.content,
          )
        }),
      )
      |> Ok
    CodeBlock(blame, attrs, lines) -> {
      use info <- on.ok(attrs_to_code_block_info(attrs))
      Ok(CodeBlock(
        blame |> pc("CodeBlock:" <> info),
        attrs,
        list.index_map(lines, fn(line, i) {
          Line(
            line.blame
              |> pc("CodeBlock > Line(" <> ins(i + 1) <> ")"),
            line.content,
          )
        }),
      ))
    }
    Tag(blame, tag, attrs, children) -> {
      use children <- on.ok(list.try_map(children, annotate_blames))
      Ok(Tag(
        blame |> pc("Tag"),
        tag,
        list.index_map(attrs, fn(attr, i) {
          Attr(
            attr.blame |> pc("Tag > Attr(" <> ins(i + 1) <> ")"),
            attr.key,
            attr.val,
          )
        }),
        children,
      ))
    }
  }
}

// ************************************************************
// API PART 5 (emitting to OutputLine & String)
//
// Writerly -> List(OutputLine)
// List(Writerly) -> List(OutputLine)
// Writerly -> String
// List(Writerly) -> String
//
// pub fn writerly_to_output_lines
// pub fn writerlys_to_output_lines
// pub fn writerly_to_string
// pub fn writerlys_to_string
// pub fn writerly_debug_table
// ************************************************************

fn line_to_output_line(line: Line, indentation: Int) -> OutputLine {
  OutputLine(line.blame, indentation, line.content)
}

fn lines_to_output_lines(
  lines: List(Line),
  indentation: Int,
) -> List(OutputLine) {
  lines
  |> list.map(line_to_output_line(_, indentation))
}

fn attribute_value_for_serialization(
  attr: Attr,
) -> Result(String, SerializationError) {
  let whitespace = leading_attribute_whitespace_count(attr.val, 0)
  case whitespace > maximum_leading_attribute_spaces {
    True ->
      Error(ExcessiveLeadingAttributeWhitespaceInSerialization(
        attr.blame,
        maximum_leading_attribute_spaces,
        whitespace,
      ))
    False -> Ok(trim_trailing_attribute_whitespace(attr.val))
  }
}

fn attr_to_output_line(
  attr: Attr,
  indentation: Int,
) -> Result(OutputLine, SerializationError) {
  case commented_attribute_spaces(attr.key) {
    Some(spaces) ->
      Ok(OutputLine(
        attr.blame,
        indentation,
        "!!" <> string.repeat(" ", spaces) <> attr.val,
      ))
    None -> {
      use value <- on.ok(attribute_value_for_serialization(attr))
      Ok(OutputLine(attr.blame, indentation, attr.key <> "=" <> value))
    }
  }
}

fn attrs_to_output_lines(
  attrs: List(Attr),
  indentation: Int,
) -> Result(List(OutputLine), SerializationError) {
  attrs |> list.try_map(attr_to_output_line(_, indentation))
}

fn first_child_is_blurb_and_first_line_of_blurb_could_be_read_as_attr_value_pair(
  nodes: List(Writerly),
) -> Bool {
  case nodes {
    [Paragraph(_, [first, ..]), ..] -> {
      case string.split_once(first.content, "=") {
        Error(_) -> False
        Ok(#(before, _)) -> {
          let before = string.trim(before)
          !string.contains(before, " ") && before != ""
        }
      }
    }
    _ -> False
  }
}

fn writerly_to_output_lines_internal(
  t: Writerly,
  indentation: Int,
  annotate_blames: Bool,
  rgxs: OurRegexes,
) -> Result(List(OutputLine), SerializationError) {
  case t {
    BlankLine(blame) -> Ok([OutputLine(blame, 0, "")])

    Paragraph(blame, lines) ->
      case lines {
        [] -> Error(EmptyParagraph(blame))
        _ ->
          lines
          |> add_escapes_in_lines(rgxs.requires_bol_te_escape)
          |> lines_to_output_lines(indentation)
          |> Ok
      }

    Comment(blame, lines) ->
      case lines {
        [] -> Error(EmptyComment(blame))
        _ ->
          lines
          |> list.map(fn(l) { Line(..l, content: "!!" <> l.content) })
          |> lines_to_output_lines(indentation)
          |> Ok
      }

    CodeBlock(blame, attrs, lines) -> {
      use info <- on.ok(attrs_to_code_block_info(attrs))
      Ok(
        list.flatten([
          [
            OutputLine(blame, indentation, "```" <> info),
          ],
          lines
            |> add_escapes_in_lines(rgxs.requires_bol_cb_escape)
            |> lines_to_output_lines(indentation),
          [
            OutputLine(
              case annotate_blames {
                False -> blame
                True -> blame |> pc("CodeBlock end")
              },
              indentation,
              "```",
            ),
          ],
        ]),
      )
    }

    Tag(blame, tag, attrs, children) -> {
      let tag_line = OutputLine(blame, indentation, "|> " <> tag)
      use attr_lines <- on.ok(attrs_to_output_lines(attrs, indentation + 4))
      use children_lines <- on.ok(
        children
        |> list.try_map(writerly_to_output_lines_internal(
          _,
          indentation + 4,
          annotate_blames,
          rgxs,
        ))
        |> result.map(list.flatten),
      )
      let buffer_lines = case
        first_child_is_blurb_and_first_line_of_blurb_could_be_read_as_attr_value_pair(
          children,
        )
      {
        True -> {
          let blame = case annotate_blames {
            False -> blame |> bl.clear_comments
            True -> blame |> bl.clear_comments |> pc("(a-b separation line)")
          }
          [OutputLine(blame, 0, "")]
        }
        False -> []
      }
      Ok(list.flatten([[tag_line], attr_lines, buffer_lines, children_lines]))
    }
  }
}

/// Serializes one Writerly node to Writerly `OutputLine` values.
pub fn writerly_to_output_lines(
  writerly: Writerly,
) -> Result(List(OutputLine), SerializationError) {
  let rgxs = our_regexes()
  writerly
  |> writerly_to_output_lines_internal(0, False, rgxs)
}

/// Serializes Writerly nodes to one flat list of VXML `OutputLine` values.
pub fn writerlys_to_output_lines(
  writerlys: List(Writerly),
) -> Result(List(OutputLine), SerializationError) {
  writerlys
  |> list.try_map(writerly_to_output_lines)
  |> result.map(list.flatten)
}

/// Serializes one Writerly node to Writerly source.
pub fn writerly_to_string(
  writerly: Writerly,
) -> Result(String, SerializationError) {
  writerly
  |> writerly_to_output_lines()
  |> result.map(io_l.output_lines_to_string)
}

/// Serializes Writerly nodes to Writerly source in the same order.
pub fn writerlys_to_string(
  writerlys: List(Writerly),
) -> Result(String, SerializationError) {
  writerlys
  |> writerlys_to_output_lines()
  |> result.map(io_l.output_lines_to_string)
}

/// Renders a blame-annotated diagnostic table for one Writerly tree.
///
/// `banner` labels the table and `indent` sets its left margin. Structural
/// descriptions are added to blame comments automatically. Returns an error
/// if the tree cannot be serialized as Writerly source.
pub fn writerly_debug_table(
  writerly: Writerly,
  banner: String,
  indent: Int,
) -> Result(String, SerializationError) {
  let rgxs = our_regexes()
  use writerly <- on.ok(annotate_blames(writerly))
  writerly
  |> writerly_to_output_lines_internal(0, True, rgxs)
  |> result.map(io_l.output_lines_table(_, banner, indent))
}
