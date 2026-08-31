# Assemble a Markdown template and its named generated fragments.
#
# Usage: assemble.ecl OUTPUT TEMPLATE NAME FRAGMENT [NAME FRAGMENT ...]
#        assemble.ecl --check OUTPUT TEMPLATE NAME FRAGMENT [NAME FRAGMENT ...]
#
# The template names fragments as <!-- include:NAME -->. Generated fragments
# are embedded two heading levels beneath their authored section. Assembly
# fails before writing when an input cannot be read or a directive is
# malformed.

### def embed-fragment
(fragment -- fragment : "Demote Markdown headings for inclusion beneath an authored section.")
(|fragment|
 fragment "\n" split
 (|line|
  line "#" str.starts?
  ("##")
  ("")
  if
  line cat)
 each
 "\n" join)
'embed-fragment def

### def assemble-spec
(arguments -- output document : "Return the output path and assembled document for one invocation.")
(|arguments|
 arguments dup len 4 >=
 'domain error.new
 "assemble.ecl expects OUTPUT TEMPLATE NAME FRAGMENT [NAME FRAGMENT ...]" error.with-message
 assert
 dup first swap
 1 at io.slurp
 arguments rest rest
 dup len 2 mod 0 =
 'domain error.new
 "assemble.ecl expects every fragment to have a name" error.with-message
 assert
 dup dup len 2 div range 2 * at
 swap dup len 2 div range 2 * 1 + at
 zip
 swap
 (|document item|
  document
  item first wrap "<!-- include:{} -->" str.format
  item 1 at io.slurp embed-fragment
  (|current marker fragment|
   current marker str.contains?
   'domain error.new
   "assembly template is missing an expected include directive" error.with-message
   assert
   current marker fragment str.replace)
  call)
 fold)
'assemble-spec def

args dup first "--check" match?
(rest assemble-spec
 (|output document|
  document output io.slurp match?
  'domain error.new
  "design/SPEC.md is stale; run `zig build spec`" error.with-message
  assert)
 call)
(assemble-spec swap io.spit)
if
