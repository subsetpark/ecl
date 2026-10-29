# Assemble design/STDLIB.md from its fragments under design/stdlib.
#
# Usage: assemble.ecl            write design/STDLIB.md
#        assemble.ecl --check    fail when design/STDLIB.md is stale
#
# Run from the repository root; every path is read through the `` `cwd `` root.
# The reference opens with preamble.md, then the core section, then one
# section per standard-library module (`stdlib`, less the `.core`
# implementations its modules import), ordered by name. A section lists every
# word `exports` reports, and each entry's effect and documentation are read
# through `effect` and `doc`, so the code is the only place they are written.
# A fragment (core.md, modules/<name>.md) supplies a section's `## name`
# introduction and, under `### word` headings, examples for the words that have
# them. A word needs no heading to be documented; a heading for a word the
# section does not export, or a fragment for no module, is refused.
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
  order. A registration reads `(body) name def`, its name one quoted symbol.")
(dup (definition-word?) each where
 (|forms indices| forms indices 1 - at (chars) each forms indices 2 - at)
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

### def module-ranks
(path -- name ranks :
 "Return the module name a source registers with the dependency ranks of its definitions.")
(source-forms
 dup dup len 2 - at chars
 swap dup len 3 - at definitions ranks) `module-ranks def

### def prelude-ranks
(-- ranks : "Rank the prelude's definitions after checking that the file is already in rank order.")
("src/prelude.ecl" source-forms definitions over swap ranks over over rank-order
 (|names ranks order|
  names order at names match?
  "src/prelude.ecl is not in dependency-rank, codepoint order" check
  ranks)
 call) `prelude-ranks def

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
 "Return what a fragment entry holds beneath its heading, which may only be an examples section.")
(dup entry-name swap "\n" split rest
 dup (len 0 >) each where dup empty? (pop pop "") (first drop "\n" join) if
 dup empty? over "#### Examples" starts? or
 rolldown ": a fragment entry may hold only examples" cat check)
`examples-of def

### def escaped
(name -- text : "Escape a word name for a Markdown heading.")
("*" "\\*" str.replace) `escaped def

### def entry-text
(name qualifier -- text :
 "Render a word's declared effect and documentation, read through reflection.")
(swap cat intern dup effect effect-text swap doc cat) `entry-text def

### def member?
(name names -- bool : "Return 1 when a list holds a value matching the name.")
(|name names| names name find names len <) `member? def

### def require-all
(names known message -- : "Fail, naming every name the known list lacks, unless it holds them all.")
(|names known message|
 names known (member? not) partial each where names swap at
 dup empty? swap ", " join message swap cat check) `require-all def

### def fragment
(path title -- header entries :
 "Read a section fragment as its header block and entry blocks, or a bare heading when the section
  has no fragment.")
(|path title|
 `cwd path fs.exists?
 path title pair
 (|path title|
  `cwd path fs.read-text blocks
  over "\n" split first "## " title cat match?
  "a section fragment's heading does not match its name" check)
 with
 title wrap ("## " swap cat []) with
 if) `fragment def

### def examples
(entries names -- examples :
 "Map each fragment entry's word to its examples, refusing an entry for a word the section does not
  export.")
(|entries names|
 entries (entry-name) each names "a fragment entry names a word the section does not export: "
 require-all
 entries (entry-name) each entries (examples-of) each zip dict.from-pairs) `examples def

### def render-entry
(name examples qualifier -- block :
 "Render one entry: its heading, its effect and documentation, then any fragment examples.")
(|name examples qualifier|
 examples name "" dict.get
 "### " name escaped cat "\n" cat name qualifier entry-text cat
 swap dup empty? (pop) ("\n\n" swap cat cat) if) `render-entry def

### def section
(path title qualifier names ranks -- text :
 "Render one section: its fragment's introduction, then an entry for every exported word in rank
  order, each from reflection plus its fragment examples.")
(|path title qualifier names ranks|
 path title fragment names examples qualifier pair
 names ranks rank-order names swap at
 swap (|name context| name context first context 1 at render-entry) partial each
 cons "\n\n" join) `section def

### def documented-modules
(-- names : "Return every standard-library module name except the `.core` implementations.")
(stdlib (chars) each dup (".core" str.ends? not) each where at) `documented-modules def

### def module-section
(module known -- text : "Render one module's section from its exports and its source ranks.")
(|module known|
 "design/stdlib/modules/" module cat ".md" cat
 module
 module "." cat
 module intern exports (chars) each
 known module {} dict.get
 section) `module-section def

### def module-sections
(-- texts :
 "Render one section per documented module in name order, refusing a fragment with no module.")
(`cwd "design/stdlib/modules" fs.list (`name at) each
 dup (".md" str.ends?) each where at (-3 drop) each
 documented-modules
 (|fragments modules|
  fragments modules "a module fragment names no standard-library module: " require-all
  "src/stdlib" ecl-files (module-ranks pair) each dict.from-pairs
  modules swap (module-section) partial each)
 call) `module-sections def

### def document
(-- text : "Assemble the complete reference.")
(module-sections
 "design/stdlib/core.md" "Prelude and core" "" `core exports (chars) each prelude-ranks section
 swap cons
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
