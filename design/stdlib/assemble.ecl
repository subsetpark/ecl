# Assemble design/STDLIB.md from its fragments under design/stdlib.
#
# Usage: assemble.ecl            write design/STDLIB.md
#        assemble.ecl --check    fail when design/STDLIB.md is stale
#
# Run from the repository root; every path is read through the `` `cwd `` root.
# The reference opens with preamble.md, then core.md, then one fragment per
# module from modules/, ordered by section name. Each fragment is one `## name`
# section: an introduction followed by `### word` entries in any order.
#
# Entries within a section are ordered by dependency rank, then by codepoint
# name. A word's rank is zero when its definition uses no other word from the
# same source, and otherwise one more than the highest rank it uses, counting
# through private helpers; the members of a mutually recursive cycle share one
# rank. Builtins have no source and rank zero. Core ranks
# come from src/prelude.ecl and module ranks from the module source under
# src/stdlib that registers the section's name. The prelude itself must already
# be in this order; assembly refuses otherwise.

### def check
(bool message -- : "Raise a domain error with the message unless the condition holds.")
(swap `domain error.new rolldown error.with-message assert) `check def

### def code-symbols
(form -- symbols : "Return every symbol in a form, descending into nested lists.")
(dup type `symbol match?
 (symbol wrap)
 (dup type `list match? ((code-symbols) each raze) (pop []) if)
 if) `code-symbols def

### def definition-word?
(form -- bool : "Return 1 for the symbol def or defp.")
(dup type `symbol match? (chars dup "def" match? swap "defp" match? or) (pop 0) if)
`definition-word? def

### def definitions
(forms -- names bodies :
 "Return the name and body quotation of every def or defp form in a definition list, in source
  order. A registration reads `(body) (name) core.first def`, the quote's expansion.")
(dup (definition-word?) each where
 (|forms indices| forms indices 2 - at (first chars) each forms indices 3 - at)
 call) `definitions def

### def adjacency
(names bodies -- matrix :
 "Return the 0/1 matrix whose row for each definition marks the other definitions its body uses.")
(swap (intern) each over len range swap
 (|body index symbols| symbols body code-symbols in? index 0 put)
 partial zip-with) `adjacency def

### def closure-step
(reach -- reach : "Add to each row everything the definitions it already reaches reach.")
(dup (|row reach| reach row where at row (max) fold) partial each) `closure-step def

### def condensed
(matrix -- matrix :
 "Give each definition every use of its mutually recursive cycle that lies outside the cycle, so the
  members of one cycle share one rank.")
(|matrix|
 matrix (closure-step) converge dup flip and
 dup len range
 matrix
 (|cycle index matrix| cycle index 1 put dup where matrix swap at (max) fold1 swap not and)
 partial zip-with) `condensed def

### def rank-step
(ranks matrix -- ranks :
 "Recompute every rank from the current ranks of the definitions each uses.")
(swap (|row ranks| ranks row where at dup empty? (pop 0) (max-of 1 +) if) partial each)
`rank-step def

### def ranks
(names bodies -- ranks :
 "Map each defined name to its rank: the longest chain of same-source definitions beneath it, with
  each mutually recursive cycle counted once.")
(over swap adjacency condensed
 dup (pop 0) each swap (rank-step) partial converge
 dict.from-lists) `ranks def

### def rank-of
(name ranks -- rank : "Return a name's rank, or zero for a word without a definition.")
(swap over over dict.has? (at) (pop pop 0) if) `rank-of def

### def rank-order
(names ranks -- indices : "Return the permutation ordering names by rank, then by codepoint.")
(over swap (rank-of) partial each swap zip grade) `rank-order def

### def source-forms
(path -- forms : "Read and parse one trusted first-party source.")
(`cwd swap fs.read-text parse) `source-forms def

### def ecl-files
(directory -- paths : "Return every .ecl file beneath a directory, recursively.")
(dup `cwd swap fs.list swap
 (|entry directory|
  directory "/" cat entry `name at cat
  entry `kind at `directory match?
  (ecl-files)
  (dup ".ecl" str.ends? (wrap) (pop []) if)
  if)
 partial each raze) `ecl-files def

### def word-spelling
(form -- text : "Return a word's spelling, or the empty string for any other form.")
(dup type `symbol match? (chars) (pop "") if) `word-spelling def

### def annotation?
(form -- bool : "Return 1 for a list holding a top-level `--` or `:` word.")
(dup type `list match?
 ((word-spelling dup "--" match? swap ":" match? or) any?)
 (pop 0)
 if) `annotation? def

### def effect-text
(annotation -- text :
 "Render an annotation's declared effect as an entry's leading code span and dash, or return the
  empty string for a documentation-only annotation.")
((word-spelling) each dup ":" find take
 dup "--" find over len <
 ((|words| "`( " words " " join cat " )` — " cat) call)
 (pop "")
 if) `effect-text def

### def public-entry
(forms index qualifier -- pair :
 "Render the effect and documentation of the public definition whose `def` word sits at an index, as
  a [name text] pair. The documentation is the binding's canonical docstring.")
(|forms index qualifier|
 forms index 2 - at first chars
 forms index 4 - 0 max at
 index 4 >= over annotation? and (effect-text) (pop "") if
 qualifier forms index 2 - at first chars cat intern doc cat
 pair) `public-entry def

### def public-docs
(forms qualifier -- docs :
 "Map each public definition in a definition list to its rendered effect and documentation.")
(over (word-spelling "def" match?) each where
 rollup pair
 (|index context| context first index context 1 at public-entry)
 partial each dict.from-pairs) `public-docs def

### def module-info
(path -- name info :
 "Return the module name a source registers with the ranks and rendered documentation of its
  definitions.")
(source-forms
 dup dup len 3 - at first chars
 swap dup len 4 - at
 (|name body|
  name
  body definitions ranks
  body name "." cat public-docs
  pair)
 call) `module-info def

### def prelude-info
(-- info :
 "Rank and document the prelude's definitions after checking that the file is already in rank
  order.")
("src/prelude.ecl" source-forms dup definitions over swap ranks over over rank-order
 (|forms names ranks order|
  names order at names match?
  "src/prelude.ecl is not in dependency-rank, codepoint order" check
  ranks forms "" public-docs pair)
 call) `prelude-info def

### def starts?
(line prefix -- bool : "Return 1 when a line begins with a prefix.")
(|line prefix| line prefix len line len min take prefix match?) `starts? def

### def trim-trailing
(lines -- lines : "Drop trailing empty lines.")
(dup (len 0 >) each where dup empty? (pop pop []) (last 1 + take) if) `trim-trailing def

### def entry-name
(block -- name : "Return the unescaped word name from an entry block's heading.")
("\n" split first 4 drop ("\\" first match? not) filter) `entry-name def

### def blocks
(text -- header entries :
 "Split a fragment into its header block and one block per `### ` entry, each without trailing blank
  lines. Headings inside fenced code are ordinary text.")
("\n" split
 dup ("```" starts?) each 0 (+) scan 2 mod 0 =
 over ("~~~" starts?) each 0 (+) scan 2 mod 0 = and
 over ("### " starts?) each and where 0 swap cons
 cut (trim-trailing "\n" join) each uncons) `blocks def

### def examples-of
(block -- text :
 "Return what an ECL-defined word's fragment entry holds beneath its heading, which may only be an
  examples section.")
(dup entry-name swap "\n" split rest
 dup (len 0 >) each where dup empty? (pop pop "") (first drop "\n" join) if
 dup empty? over "#### Examples" starts? or
 rolldown ": an ECL-defined word's fragment entry may hold only examples" cat check)
`examples-of def

### def ecl-entry
(name names entries docs -- block :
 "Render an ECL-defined word's entry from its documentation and its fragment entry's examples.")
(|name names entries docs|
 entries names name find
 over len over >
 (at examples-of)
 (pop pop "")
 if
 "### " name cat "\n" cat docs name at cat
 swap dup empty? (pop) ("\n\n" swap cat cat) if) `ecl-entry def

### def merge-entries
(entries docs -- entries :
 "Keep each builtin entry as written and render every ECL-defined word's entry from its source,
  including words the fragment omits.")
(|entries docs|
 entries (entry-name) each
 entries docs pair
 (|names entries docs|
  names docs (swap dict.has? not) partial each where entries swap at
  docs dict.keys names entries docs 3 pack
  (|name context| name context first context 1 at context 2 at ecl-entry)
  partial each
  cat)
 with call) `merge-entries def

### def section
(path name info -- text :
 "Read one section fragment and return it with ECL-defined entries rendered from source and every
  entry in rank order.")
(|path name info|
 `cwd path fs.read-text blocks
 info name pair
 (|header entries info name|
  header "\n" split first "## " name cat match?
  "a section fragment's heading does not match its name" check
  entries info 1 at merge-entries
  dup (entry-name) each info first rank-order at header swap cons "\n\n" join)
 with call) `section def

### def module-sections
(module-info -- texts : "Assemble every module fragment, ordered by section name.")
(`cwd "design/stdlib/modules" fs.list (`name at) each
 dup (".md" str.ends?) each where at
 dup (-3 drop) each dup grade
 (|known files names order|
  files order at names order at
  known
  (|file name known|
   "design/stdlib/modules/" file cat name
   known name over over dict.has? (at) (pop pop [{} {}]) if
   section)
  partial zip-with)
 call) `module-sections def

### def document
(-- text : "Assemble the complete reference.")
("src/stdlib" ecl-files (module-info pair) each dict.from-pairs
 module-sections
 "design/stdlib/core.md" "Prelude and core" prelude-info section swap cons
 `cwd "design/stdlib/preamble.md" fs.read-text "\n" split trim-trailing "\n" join swap cons
 "<!-- Generated from design/stdlib by design/stdlib/assemble.ecl; edit the fragments. -->" swap
 cons
 "\n\n" join "\n" cat) `document def

args dup len 0 = swap ["--check"] match? or
"usage: assemble.ecl [--check]" check
document
args len 0 >
(|document|
 `cwd "design/STDLIB.md" fs.read-text document match?
 "design/STDLIB.md is stale; run `zig build stdlib`" check)
(|document|
 document `cwd "design/STDLIB.md" over over fs.exists? (fs.replace-text) (fs.create-text) if)
if
