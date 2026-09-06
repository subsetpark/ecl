" Vim syntax file
" Language: ecl

if exists('b:current_syntax')
  finish
endif

syntax case match
syntax sync fromstart

" Strings may span lines. Keep valid escapes distinct without trying to turn
" syntax highlighting into a second reader for malformed source.
syntax match eclEscape /\\\%(\\\|"\|n\|t\|u{\x\{1,6}}\)/ contained
syntax region eclString start=/"/ skip=/\\\\\|\\"/ end=/"/ contains=eclEscape

" Define structural punctuation before atom-shaped literals so a character
" such as `\(` owns its delimiter rather than being split into two groups.
syntax match eclDelimiter /[(){}]/
syntax match eclDelimiter /\[\|\]/
syntax match eclBinder /|/
syntax match eclReserved /;/

" Atom boundaries mirror the reader: comma is whitespace, while semicolon
" and pipe terminate atoms even though their uses are restricted.
let s:atom_start = '\%([^][[:space:],(){}"#;|]\)\@<!'
let s:atom_end = '\ze\%($\|[][[:space:],(){}"#;|]\)'

execute 'syntax match eclNumber /' . s:atom_start
      \ . '\%([+-]\?0x\x\+\|[+-]\?\d\%(_\?\d\)*\|'
      \ . '[+-]\?\d\+\.\d\+\%([eE][+-]\?\d\+\)\?\|'
      \ . '[+-]\?\d\+[eE][+-]\?\d\+\|[+-]\?inf\)'
      \ . s:atom_end . '/'

execute 'syntax match eclCharacter /' . s:atom_start
      \ . '\\\%(space\|tab\|newline\|u{\x\{1,6}}\|u\%({\)\@!\|[^u]\)'
      \ . s:atom_end . '/'

let s:symbol_segment = '[^[:space:],(){}\[\]"#''\\.;|]\+'
execute 'syntax match eclSymbol /' . s:atom_start . "'"
      \ . s:symbol_segment . '\%(\.' . s:symbol_segment . '\)*'
      \ . s:atom_end . '/'

execute 'syntax match eclDefinition /' . s:atom_start
      \ . '\%(defp\?\|setp\?\|test\|@defm\)' . s:atom_end . '/'

syntax match eclComment /#.*/ contains=@Spell

highlight default link eclComment Comment
highlight default link eclString String
highlight default link eclEscape SpecialChar
highlight default link eclNumber Number
highlight default link eclCharacter Character
highlight default link eclSymbol Constant
highlight default link eclDefinition Keyword
highlight default link eclDelimiter Delimiter
highlight default link eclBinder Operator
highlight default link eclReserved Error

let b:current_syntax = 'ecl'
