import dirtree.{Dirpath, Filepath} as _dt
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import vxml.{type Attr, Attr, Line, T, V}
import vxml/blame.{Anchored, Movable, Src, no_blame} as _bl
import vxml/io_lines.{InputLine} as io_l
import writerly.{type Writerly, Paragraph} as wl

pub fn main() -> Nil {
  gleeunit.main()
}

fn trim_fixture_end(source: String) -> String {
  case string.ends_with(source, " ") {
    True -> source |> string.drop_end(1) |> trim_fixture_end
    False ->
      case string.ends_with(source, "\n") {
        True -> source |> string.drop_end(1)
        False -> source
      }
  }
}

fn trim_fixture(source: String) -> String {
  case string.starts_with(source, "\n") {
    True -> string.drop_start(source, 1) |> trim_fixture_end
    False -> source |> trim_fixture_end
  }
}

/// Turn a legibly indented two-space test fixture into four-space Writerly.
fn normalize_fixture(source: String) -> String {
  let lines =
    source
    |> trim_fixture
    |> io_l.string_to_input_lines("", 0)

  let assert [first, ..] = lines

  lines
  |> list.map(fn(l) { InputLine(..l, indent: { l.indent - first.indent } * 2) })
  |> io_l.input_lines_to_string
}

fn parse_fixture(source: String) -> Writerly {
  let assert Ok(writerly) =
    source
    |> normalize_fixture
    |> wl.string_to_writerly("fixture.wly")
  writerly
}

fn assert_round_trip(source: String) {
  source
  |> parse_fixture
  |> wl.writerly_to_string
  |> should.equal(Ok(normalize_fixture(source)))
}

fn attr_pairs(attrs: List(Attr)) -> List(#(String, String)) {
  list.map(attrs, fn(attr) { #(attr.key, attr.val) })
}

fn test1_sources() -> List(wl.SourceFile) {
  [wl.SourceFile("test1.wly", "|> Book\n    bob=2\n    cuchua\n")]
}

fn test_a_sources() -> List(wl.SourceFile) {
  [
    wl.SourceFile("childA.wly", "It was a dark and stormy night."),
    wl.SourceFile("__parent.wly", "|> Book\n    a=b"),
  ]
}

fn assembled_paths(
  sources: List(wl.SourceFile),
  path_selector: fn(String) -> Bool,
) -> Result(List(String), wl.AssemblyError) {
  wl.assemble_sources_with_path_selector("root", sources, path_selector)
  |> result.map(fn(assembled) {
    let #(_tree, lines) = assembled
    lines
    |> list.map(fn(line) {
      let assert Src(path: path, ..) = line.blame
      path
    })
    |> list.unique
  })
}

pub fn assembler_reads_a_single_file_with_relative_blame_paths_test() {
  wl.assemble_sources("test", test1_sources())
  |> should.equal(
    Ok(
      #(Dirpath("test", [Filepath("test1.wly")]), [
        InputLine(Src([], "test1.wly", 1, 1, Movable), 0, "|> Book"),
        InputLine(Src([], "test1.wly", 2, 5, Movable), 4, "bob=2"),
        InputLine(Src([], "test1.wly", 3, 5, Movable), 4, "cuchua"),
        InputLine(Src([], "test1.wly", 4, 1, Movable), 0, ""),
      ]),
    ),
  )
}

pub fn assembler_nests_child_files_below_the_parent_document_test() {
  wl.assemble_sources("test/testA", test_a_sources())
  |> should.equal(
    Ok(
      #(
        Dirpath("test/testA", [Filepath("__parent.wly"), Filepath("childA.wly")]),
        [
          InputLine(Src([], "__parent.wly", 1, 1, Movable), 0, "|> Book"),
          InputLine(Src([], "__parent.wly", 2, 5, Movable), 4, "a=b"),
          InputLine(
            Src([], "childA.wly", 1, 1, Movable),
            4,
            "It was a dark and stormy night.",
          ),
        ],
      ),
    ),
  )
}

pub fn assembler_result_does_not_depend_on_source_order_test() {
  wl.assemble_sources("test/testA", list.reverse(test_a_sources()))
  |> should.equal(wl.assemble_sources("test/testA", test_a_sources()))
}

pub fn assembler_ignores_commented_and_non_wly_paths_test() {
  [
    wl.SourceFile("__parent.wly", "|> Book"),
    wl.SourceFile("a.wly", "a"),
    wl.SourceFile("#draft.wly", "draft"),
    wl.SourceFile("#old/b.wly", "old"),
    wl.SourceFile("notes.txt", "notes"),
  ]
  |> assembled_paths(fn(_) { True })
  |> should.equal(Ok(["__parent.wly", "a.wly"]))
}

pub fn assembler_keeps_parents_of_selected_files_test() {
  [
    wl.SourceFile("__parent.wly", "|> Book"),
    wl.SourceFile("ch1/__parent.wly", "|> Chapter"),
    wl.SourceFile("ch1/part1.wly", "one"),
    wl.SourceFile("ch1/part2.wly", "two"),
    wl.SourceFile("ch2/__parent.wly", "|> Chapter"),
    wl.SourceFile("ch2/part1.wly", "three"),
  ]
  |> assembled_paths(fn(path) { path == "ch1/part2.wly" })
  |> should.equal(Ok(["__parent.wly", "ch1/__parent.wly", "ch1/part2.wly"]))
}

pub fn assembler_requires_a_direct_wly_file_test() {
  [wl.SourceFile("sub/a.wly", "a"), wl.SourceFile("#b.wly", "b")]
  |> wl.assemble_sources("book", _)
  |> should.equal(Error(wl.NoFilesFound("no direct .wly files found in: book")))
}

pub fn assembler_rejects_invalid_and_duplicate_paths_test() {
  ["", "/abs.wly", "a//b.wly", "./a.wly", "sub/../a.wly", "sub/"]
  |> list.each(fn(path) {
    [wl.SourceFile("a.wly", "a"), wl.SourceFile(path, "x")]
    |> wl.assemble_sources("book", _)
    |> should.equal(Error(wl.InvalidSourcePath(path)))
  })

  [wl.SourceFile("a.wly", "a"), wl.SourceFile("a.wly", "b")]
  |> wl.assemble_sources("book", _)
  |> should.equal(Error(wl.DuplicateSourcePath("a.wly")))
}

pub fn parser_builds_a_tag_with_an_attribute_test() {
  wl.string_to_writerlys("|> Book\n    a=b", "doc")
  |> should.equal(
    Ok([
      wl.Tag(
        Src([], "doc", 1, 1, Anchored),
        "Book",
        [
          Attr(Src([], "doc", 2, 5, Movable), "a", "b"),
        ],
        [],
      ),
    ]),
  )
}

pub fn attribute_values_preserve_leading_and_trim_trailing_whitespace_test() {
  let source =
    "|> figure\n    offset-x=-4.04em\n    offset-y= 4.04em \t\n    tab=\tvalue\t"
  let assert Ok(
    wl.Tag(
      _,
      "figure",
      [
        Attr(_, "offset-x", "-4.04em"),
        Attr(_, "offset-y", " 4.04em"),
        Attr(_, "tab", "\tvalue"),
      ],
      [],
    ) as writerly,
  ) = wl.string_to_writerly(source, "doc")

  writerly
  |> wl.writerly_to_string
  |> should.equal(Ok(
    "|> figure\n    offset-x=-4.04em\n    offset-y= 4.04em\n    tab=\tvalue",
  ))
}

pub fn parser_preserves_paragraph_source_blame_test() {
  let assert Ok(#(_tree, lines)) = wl.assemble_sources("test", test1_sources())
  lines
  |> wl.input_lines_to_writerlys()
  |> should.equal(
    Ok([
      wl.Tag(
        Src([], "test1.wly", 1, 1, Anchored),
        "Book",
        [
          Attr(Src([], "test1.wly", 2, 5, Movable), "bob", "2"),
        ],
        [
          Paragraph(Src([], "test1.wly", 3, 5, Movable), [
            Line(Src([], "test1.wly", 3, 5, Movable), "cuchua"),
          ]),
        ],
      ),
    ]),
  )
}

pub fn parser_preserves_blame_across_assembled_files_test() {
  let assert Ok(#(_tree, lines)) =
    wl.assemble_sources("test/testA", test_a_sources())
  lines
  |> wl.input_lines_to_writerlys()
  |> should.equal(
    Ok([
      wl.Tag(
        Src([], "__parent.wly", 1, 1, Anchored),
        "Book",
        [
          Attr(Src([], "__parent.wly", 2, 5, Movable), "a", "b"),
        ],
        [
          Paragraph(Src([], "childA.wly", 1, 1, Movable), [
            Line(
              Src([], "childA.wly", 1, 1, Movable),
              "It was a dark and stormy night.",
            ),
          ]),
        ],
      ),
    ]),
  )
}

pub fn parser_rejects_invalid_tag_names_test() {
  let assert Error(wl.BadTag(_, "not a tag")) =
    wl.string_to_writerly("|> not a tag", "doc")
}

pub fn parser_rejects_indentation_not_divisible_by_four_test() {
  let assert Error(wl.IndentationNotMultipleOfFour(_, "too shallow")) =
    wl.string_to_writerly("|> Book\n  too shallow", "doc")
}

pub fn parser_rejects_skipped_indentation_levels_test() {
  let assert Error(wl.IndentationTooLarge(_, _, _, _)) =
    wl.string_to_writerly("|> Book\n        too deep", "doc")
}

pub fn parser_rejects_unclosed_code_blocks_test() {
  let assert Error(wl.CodeBlockNotClosed(_)) =
    wl.string_to_writerly("|> Book\n    ```gleam\n    pub fn main() {}", "doc")
}

pub fn parser_rejects_annotated_closing_code_fences_test() {
  let assert Error(wl.CodeBlockUnwantedAnnotationAtClose(_, _, "gleam")) =
    wl.string_to_writerly(
      "|> Book\n    ```gleam\n    body\n    ```gleam",
      "doc",
    )
}

pub fn parser_rejects_invalid_code_block_attribute_keys_test() {
  let assert Error(wl.BadKey(_, "bad key")) =
    wl.string_to_writerly("|> Book\n    ```gleam&bad key=value\n    ```", "doc")
}

pub fn single_root_parser_reports_missing_and_nonunique_roots_test() {
  let assert Error(wl.MissingRoot(_)) = wl.string_to_writerly("\n", "doc")
  let assert Error(wl.NonUniqueRoot(_)) =
    wl.string_to_writerly("first\n\nsecond", "doc")
}

pub fn writerly_tag_converts_to_vxml_element_test() {
  let assert Ok(wly_parsed) = wl.string_to_writerly("|> Book\n    a=b", "doc")

  wly_parsed
  |> wl.writerly_to_vxml()
  |> should.equal(
    vxml.V(
      Src([], "doc", 1, 1, Anchored),
      "Book",
      [Attr(Src([], "doc", 2, 5, Movable), "a", "b")],
      [],
    ),
  )
}

pub fn vxml_text_node_converts_to_writerly_paragraph_test() {
  let vxml_doc = "<> Book\n  a=b\n  <>\n    'first'\n    'second'"

  let assert Ok(vxml_parsed) = vxml.string_to_vxml(vxml_doc, "doc")

  vxml_parsed
  |> wl.vxml_to_writerly
  |> should.equal(
    Ok(
      wl.Tag(
        Src([], "doc", 1, 1, Anchored),
        "Book",
        [Attr(Src([], "doc", 2, 3, Movable), "a", "b")],
        [
          Paragraph(Src([], "doc", 4, 5, Movable), [
            Line(Src([], "doc", 4, 5, Movable), "first"),
            Line(Src([], "doc", 5, 5, Movable), "second"),
          ]),
        ],
      ),
    ),
  )
}

pub fn round_trip_preserves_escaped_code_fences_test() {
  "
  |> Book
    a=b
    ```
    \\```
    ```
  "
  |> assert_round_trip
}

pub fn round_trip_preserves_escaped_paragraph_indentation_test() {
  "
  |> Book
    A paragraph with
    \\ an escaped space
    at the beginning of the second line
  "
  |> assert_round_trip
}

pub fn round_trip_preserves_code_block_indentation_test() {
  "
  |> Book
    ```
      hallo
    \\```
    \\\\```
    ```
  "
  |> assert_round_trip
}

pub fn round_trip_preserves_comments_and_trailing_spaces_test() {
  "
  |> Book
    a=b
    !!someguy=aa
    t=w

    A paragraph with  
    \\ an escaped space
    \\\\ an escaped space
    at the beginning of the second line   
  "
  |> assert_round_trip
}

pub fn commented_attribute_encoding_test() {
  let source = "|> Book\n    !!   someguy=aa"
  let assert Ok(writerly) = wl.string_to_writerly(source, "doc")
  let assert wl.Tag(_, "Book", [Attr(_, key, val)], []) = writerly

  key |> should.equal("WriterlyCommentedAttribute3Spaces")
  val |> should.equal("someguy=aa")
  writerly |> wl.writerly_to_string |> should.equal(Ok(source))

  let empty_source = "|> Book\n    !!"
  let assert Ok(empty_writerly) = wl.string_to_writerly(empty_source, "doc")
  let assert wl.Tag(_, "Book", [Attr(_, empty_key, "")], []) = empty_writerly
  empty_key |> should.equal("WriterlyCommentedAttribute0Spaces")
  empty_writerly |> wl.writerly_to_string |> should.equal(Ok(empty_source))
}

pub fn commented_attribute_key_helpers_test() {
  wl.commented_attribute_spaces("WriterlyCommentedAttribute0Spaces")
  |> should.equal(Some(0))
  wl.commented_attribute_spaces("WriterlyCommentedAttribute100Spaces")
  |> should.equal(Some(100))
  wl.is_commented_attribute_key("WriterlyCommentedAttribute101Spaces")
  |> should.be_false
  wl.commented_attribute_spaces("WriterlyCommentedAttribute01Spaces")
  |> should.equal(Some(1))
}

pub fn code_block_info_string_and_attributes_round_trip_test() {
  let source =
    "|> Book\n    ```python&id=example&title=a\\&b&path=c\\\\d&empty=\n    body\n    ```"
  let assert Ok(
    wl.Tag(_, "Book", _, [wl.CodeBlock(_, attrs, [Line(_, "body")])]) as writerly,
  ) = wl.string_to_writerly(source, "doc")
  attr_pairs(attrs)
  |> should.equal([
    #(wl.code_block_info_string_prefix_attribute_key, "python"),
    #("id", "example"),
    #("title", "a&b"),
    #("path", "c\\d"),
    #("empty", ""),
  ])
  writerly |> wl.writerly_to_string |> should.equal(Ok(source))
}

pub fn code_block_info_string_attribute_may_appear_anywhere_test() {
  let writerly =
    wl.CodeBlock(
      no_blame,
      [
        Attr(no_blame, "id", "example"),
        Attr(
          no_blame,
          wl.code_block_info_string_prefix_attribute_key,
          " python ",
        ),
        Attr(no_blame, "class", " listing "),
      ],
      [],
    )

  let serialized = "```python&id=example&class= listing\n```"
  writerly |> wl.writerly_to_string |> should.equal(Ok(serialized))

  let assert Ok(wl.CodeBlock(_, attrs, [])) =
    wl.string_to_writerly(serialized, "doc")
  attr_pairs(attrs)
  |> should.equal([
    #(wl.code_block_info_string_prefix_attribute_key, "python"),
    #("id", "example"),
    #("class", " listing"),
  ])
}

pub fn writerly_serialization_rejects_excessive_leading_attribute_whitespace_test() {
  let value = string.repeat(" ", 101) <> "hidden"
  wl.Tag(no_blame, "Book", [Attr(no_blame, "key", value)], [])
  |> wl.writerly_to_string
  |> should.equal(
    Error(wl.ExcessiveLeadingAttributeWhitespaceInSerialization(
      no_blame,
      100,
      101,
    )),
  )
}

fn assert_excessive_leading_whitespace(source: String) {
  let assert Error(wl.ExcessiveLeadingAttributeWhitespace(_, 100, 101)) =
    wl.string_to_writerly(source, "doc")
  Nil
}

pub fn parser_rejects_excessive_leading_attribute_whitespace_test() {
  let excessive = string.repeat(" ", 101)

  assert_excessive_leading_whitespace(
    "|> Book\n    key=" <> excessive <> "hidden",
  )

  assert_excessive_leading_whitespace(
    "|> Book\n    !!" <> excessive <> "key=value",
  )

  assert_excessive_leading_whitespace(
    "|> Book\n    ```python&id=" <> excessive <> "hidden\n    ```",
  )

  assert_excessive_leading_whitespace(
    "|> Book\n    key=" <> string.repeat("\t", 101) <> "hidden",
  )
}

pub fn vxml_to_writerly_rejects_malformed_reserved_nodes_test() {
  wl.vxml_to_writerly(V(no_blame, "WriterlyBlankLine", [], [T(no_blame, [])]))
  |> should.equal(Error(wl.MalformedBlankLine(no_blame)))

  wl.vxml_to_writerly(
    V(no_blame, "WriterlyCodeBlock", [], [
      T(no_blame, [Line(no_blame, "one")]),
      T(no_blame, [Line(no_blame, "two")]),
    ]),
  )
  |> should.equal(Error(wl.MalformedCodeBlock(no_blame)))

  wl.vxml_to_writerly(V(no_blame, "WriterlyComment", [], []))
  |> should.equal(Error(wl.MalformedComment(no_blame)))
}

pub fn vxml_to_writerly_rejects_empty_text_node_test() {
  wl.vxml_to_writerly(T(no_blame, []))
  |> should.equal(Error(wl.EmptyTextNode(no_blame)))
}

pub fn writerly_serialization_rejects_empty_line_collections_test() {
  wl.writerly_to_string(wl.Paragraph(no_blame, []))
  |> should.equal(Error(wl.EmptyParagraph(no_blame)))

  wl.writerly_to_string(wl.Comment(no_blame, []))
  |> should.equal(Error(wl.EmptyComment(no_blame)))
}

pub fn writerly_serialization_rejects_duplicate_info_prefix_test() {
  let prefix = wl.code_block_info_string_prefix_attribute_key
  wl.CodeBlock(
    no_blame,
    [
      Attr(no_blame, prefix, "python"),
      Attr(no_blame, prefix, "gleam"),
    ],
    [],
  )
  |> wl.writerly_to_string
  |> should.equal(Error(wl.DuplicateCodeBlockInfoStringPrefix(no_blame)))
}

// The README's align* example, including the blank line and the nine spaces
// after the Writerly escape on the continuation line.
const latex_alignment_source = "|> Example

    \\begin{align*}
    (x + 1)^2 &= x^2 + 2x + 1 \\\\
    \\         &= x(x + 2) + 1
    \\end{align*}"

fn assert_latex_alignment_contents(parsed: Writerly) {
  let assert wl.Tag(_, "Example", [], children) = parsed
  children
  |> list.filter_map(fn(child) {
    case child {
      Paragraph(_, lines) -> Ok(list.map(lines, fn(line) { line.content }))
      _ -> Error(Nil)
    }
  })
  |> should.equal([
    [
      "\\begin{align*}",
      "(x + 1)^2 &= x^2 + 2x + 1 \\\\",
      "         &= x(x + 2) + 1",
      "\\end{align*}",
    ],
  ])
}

pub fn parser_preserves_latex_commands_and_escaped_alignment_spaces_test() {
  let assert Ok(parsed) =
    wl.string_to_writerly(latex_alignment_source, "latex-example.wly")
  assert_latex_alignment_contents(parsed)
}

pub fn latex_alignment_example_round_trips_without_text_or_indentation_changes_test() {
  let assert Ok(parsed) =
    wl.string_to_writerly(latex_alignment_source, "latex-example.wly")
  let assert Ok(serialized) = wl.writerly_to_string(parsed)
  serialized |> should.equal(latex_alignment_source)
  let assert Ok(reparsed) =
    wl.string_to_writerly(serialized, "latex-example.wly")
  assert_latex_alignment_contents(reparsed)
}
