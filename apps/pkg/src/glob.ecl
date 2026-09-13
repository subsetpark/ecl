### module pkg.glob
# Package source selection. Every dynamic-programming cell is ordinary ECL work.
[]
(
 ### defp initial-step
 (row token star? -- row : "Only leading wildcard tokens can match empty input.")
 (|row token star|
  row row last token star call and append) 'initial-step defp

 ### defp cell-value
 (state token -- bool : "Evaluate one wildcard recurrence without backtracking.")
 (|state token|
  token state 'context at 1 at call
  state 'index at state 'old at swap at
  token state 'item at state 'context at 2 at call and
  state 'new at last state 'old at state 'index at 1 + at or
  pair swap at) 'cell-value defp

 ### defp cell
 (state token -- state : "Append one dynamic-programming cell.")
 (|state token|
  state 'new state 'new at state token cell-value append put
  'index state 'index at 1 + put) 'cell defp

 ### defp row
 (previous item context -- next : "Consume one input token with bounded wildcard state.")
 (|previous item context|
  context first
  {} 'old previous put 'item item put 'context context put 'index 0 put 'new [0] put
  (cell) fold 'new at) 'row defp

 ### defp matches
 (pattern input star? same? -- bool : "Match a token sequence with repeatable wildcard tokens.")
 (|pattern input star same|
  input pattern [1] star (initial-step) partial fold
  pattern star same 3 pack (row) partial fold last) 'matches defp

 ### defp byte-match
 (pattern input -- bool : "Question mark matches one path byte.")
 (|pattern input| pattern 63 match? pattern input match? or) 'byte-match defp

 ### defp segment
 (pattern input -- bool : "Match a single component using * and ? without crossing slashes.")
 (bytes swap bytes swap (42 match?) (byte-match) matches) 'segment defp

 ### def matches?
 (pattern path -- bool : "Match portable source globs; ** spans zero or more complete components.")
 ("/" split swap "/" split swap ("**" match?) (segment) matches) 'matches? def
) 'pkg.glob @defm
