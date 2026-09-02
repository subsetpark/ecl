# Assemble a Markdown template and its named generated fragments.
#
# Usage: assemble.ecl ROOT OUTPUT TEMPLATE NAME FRAGMENT [NAME FRAGMENT ...]
#        assemble.ecl ROOT --check OUTPUT TEMPLATE NAME FRAGMENT [NAME FRAGMENT ...]
#
# ROOT is the absolute build root; every other path is relativized beneath it
# and read or written through the `'cwd` filesystem root the command line
# grants, which is why the build runs this script from that directory. The
# template names fragments as <!-- include:NAME -->. Generated fragments are
# embedded two heading levels beneath their authored section. Assembly fails
# before writing when an input cannot be read or a directive is malformed.

### def relativize-absolute
(root path -- path : "Strip the build root prefix from an absolute path beneath it.")
(|root path|
 path root "/" cat str.starts?
 'domain error.new "assembly input is outside the build root" error.with-message assert
 path root len 1 + drop)
'relativize-absolute def

### def relativize
(root path -- path :
 "Strip the build root prefix from an absolute path, keep a relative one, and normalize the result
  into the canonical grammar `fs` accepts.")
(dup path.absolute? (relativize-absolute) (nip) if path.normalize)
'relativize def

### def read-input
(root path -- text : "Read one assembly input beneath the build root.")
(relativize 'cwd swap fs.read-text)
'read-input def

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
(root arguments -- output document :
 "Return the relative output path and assembled document for one invocation.")
(|root arguments|
 arguments dup len 4 >=
 'domain error.new
 "assemble.ecl expects OUTPUT TEMPLATE NAME FRAGMENT [NAME FRAGMENT ...]" error.with-message
 assert
 dup first root swap relativize swap
 1 at root swap read-input
 arguments rest rest
 dup len 2 mod 0 =
 'domain error.new
 "assemble.ecl expects every fragment to have a name" error.with-message
 assert
 dup dup len 2 div range 2 * at
 swap dup len 2 div range 2 * 1 + at
 zip
 swap
 root
 (|document item root|
  document
  item first wrap "<!-- include:{} -->" str.format
  root item 1 at read-input embed-fragment
  (|current marker fragment|
   current marker str.contains?
   'domain error.new
   "assembly template is missing an expected include directive" error.with-message
   assert
   current marker fragment str.replace)
  call)
 partial
 fold
 dup "<!-- include:" str.contains? not
 'domain error.new
 "assembled specification contains an unresolved include directive" error.with-message
 assert)
'assemble-spec def

### def check-output
(output document root -- : "Require the checked-in output to match the assembled document.")
(|output document root|
 document root output read-input match?
 'domain error.new
 "design/SPEC.md is stale; run `zig build spec`" error.with-message
 assert)
'check-output def

### def write-output
(output document -- : "Create or strictly replace the assembled output beneath the build root.")
(swap 'cwd swap over over fs.exists? (fs.replace-text) (fs.create-text) if)
'write-output def

args first args rest
dup first "--check" match?
(rest (|root arguments| root arguments assemble-spec root check-output) call)
((|root arguments| root arguments assemble-spec write-output) call)
if
