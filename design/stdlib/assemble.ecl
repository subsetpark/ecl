# Assemble design/STDLIB.md from its fragments under design/stdlib.
#
# Usage: assemble.ecl            write design/STDLIB.md
#        assemble.ecl --check    fail when design/STDLIB.md is stale
#
# Run from the repository root; every path is read through the `'cwd` root.
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
(swap 'domain error.new rolldown error.with-message assert) 'check def

### def code-symbols
(form -- symbols : "Return every word in a form as a symbol, descending into nested lists.")
(dup type 'word match?
 (symbol wrap)
 (dup type 'list match? ((code-symbols) each raze) (pop []) if)
 if) 'code-symbols def

### def definition-word?
(form -- bool : "Return 1 for the word def or defp.")
(dup type 'word match? (chars dup "def" match? swap "defp" match? or) (pop 0) if)
'definition-word? def

### def definitions
(forms -- names bodies :
 "Return the name and body quotation of every def or defp form in a definition list, in source
  order.")
(dup (definition-word?) each where
 (|forms indices| forms indices 1 - at (chars) each forms indices 2 - at)
 call) 'definitions def

### def adjacency
(names bodies -- matrix :
 "Return the 0/1 matrix whose row for each definition marks the other definitions its body uses.")
(swap (intern) each over len range swap
 (|body index symbols| symbols body code-symbols in? index 0 put)
 partial zip-with) 'adjacency def

### def closure-step
(reach -- reach : "Add to each row everything the definitions it already reaches reach.")
(dup (|row reach| reach row where at row (max) fold) partial each) 'closure-step def

### def condensed
(matrix -- matrix :
 "Give each definition every use of its mutually recursive cycle that lies outside the cycle, so the
  members of one cycle share one rank.")
(|matrix|
 matrix (closure-step) converge dup flip and
 dup len range
 matrix
 (|cycle index matrix| cycle index 1 put dup where matrix swap at (max) fold1 swap not and)
 partial zip-with) 'condensed def

### def rank-step
(ranks matrix -- ranks :
 "Recompute every rank from the current ranks of the definitions each uses.")
(swap (|row ranks| ranks row where at dup empty? (pop 0) (max-of 1 +) if) partial each)
'rank-step def

### def ranks
(names bodies -- ranks :
 "Map each defined name to its rank: the longest chain of same-source definitions beneath it, with
  each mutually recursive cycle counted once.")
(over swap adjacency condensed
 dup (pop 0) each swap (rank-step) partial converge
 dict.from-lists) 'ranks def

### def rank-of
(name ranks -- rank : "Return a name's rank, or zero for a word without a definition.")
(swap over over dict.has? (at) (pop pop 0) if) 'rank-of def

### def rank-order
(names ranks -- indices : "Return the permutation ordering names by rank, then by codepoint.")
(over swap (rank-of) partial each swap zip grade) 'rank-order def

### def source-forms
(path -- forms : "Read and parse one trusted first-party source.")
('cwd swap fs.read-text parse) 'source-forms def

### def ecl-files
(directory -- paths : "Return every .ecl file beneath a directory, recursively.")
(dup 'cwd swap fs.list swap
 (|entry directory|
  directory "/" cat entry 'name at cat
  entry 'kind at 'directory match?
  (ecl-files)
  (dup ".ecl" str.ends? (wrap) (pop []) if)
  if)
 partial each raze) 'ecl-files def

### def module-ranks
(path -- name ranks : "Return the module name a source registers and the ranks of its definitions.")
(source-forms
 dup dup len 2 - at chars
 swap dup len 3 - at definitions ranks) 'module-ranks def

### def prelude-ranks
(-- ranks : "Rank the prelude's definitions after checking that the file is already in rank order.")
("src/prelude.ecl" source-forms definitions over swap ranks over over rank-order
 (|names ranks order|
  names order at names match?
  "src/prelude.ecl is not in dependency-rank, codepoint order" check
  ranks)
 call) 'prelude-ranks def

### def starts?
(line prefix -- bool : "Return 1 when a line begins with a prefix.")
(|line prefix| line prefix len line len min take prefix match?) 'starts? def

### def trim-trailing
(lines -- lines : "Drop trailing empty lines.")
(dup (len 0 >) each where dup empty? (pop pop []) (last 1 + take) if) 'trim-trailing def

### def entry-name
(block -- name : "Return the unescaped word name from an entry block's heading.")
("\n" split first 4 drop ("\\" first match? not) filter) 'entry-name def

### def blocks
(text -- header entries :
 "Split a fragment into its header block and one block per `### ` entry, each without trailing blank
  lines. Headings inside fenced code are ordinary text.")
("\n" split
 dup ("```" starts?) each 0 (+) scan 2 mod 0 =
 over ("### " starts?) each and where 0 swap cons
 cut (trim-trailing "\n" join) each uncons) 'blocks def

### def section
(path name ranks -- text :
 "Read one section fragment and return it with its entries in rank order.")
(|path name ranks|
 'cwd path fs.read-text blocks
 ranks name pair
 (|header entries ranks name|
  header "\n" split first "## " name cat match?
  "a section fragment's heading does not match its name" check
  entries dup (entry-name) each ranks rank-order at header swap cons "\n\n" join)
 with call) 'section def

### def module-sections
(module-ranks -- texts : "Assemble every module fragment, ordered by section name.")
('cwd "design/stdlib/modules" fs.list ('name at) each
 dup (".md" str.ends?) each where at
 dup (-3 drop) each dup grade
 (|ranked files names order|
  files order at names order at
  ranked
  (|file name ranked|
   "design/stdlib/modules/" file cat name
   ranked name over over dict.has? (at) (pop pop {}) if
   section)
  partial zip-with)
 call) 'module-sections def

### def document
(-- text : "Assemble the complete reference.")
("src/stdlib" ecl-files (module-ranks pair) each dict.from-pairs
 module-sections
 "design/stdlib/core.md" "Prelude and core" prelude-ranks section swap cons
 'cwd "design/stdlib/preamble.md" fs.read-text "\n" split trim-trailing "\n" join swap cons
 "<!-- Generated from design/stdlib by design/stdlib/assemble.ecl; edit the fragments. -->" swap
 cons
 "\n\n" join "\n" cat) 'document def

args dup len 0 = swap ["--check"] match? or
"usage: assemble.ecl [--check]" check
document
args len 0 >
(|document|
 'cwd "design/STDLIB.md" fs.read-text document match?
 "design/STDLIB.md is stale; run `zig build stdlib`" check)
(|document|
 document 'cwd "design/STDLIB.md" over over fs.exists? (fs.replace-text) (fs.create-text) if)
if
