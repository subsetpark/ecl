" Vim indent file
" Language: ecl

if exists('b:did_indent')
  finish
endif
let b:did_indent = 1

setlocal autoindent
setlocal expandtab
setlocal shiftwidth=1
setlocal softtabstop=1
setlocal indentexpr=GetEclIndent()
setlocal indentkeys=0),0],0},!^F,o,O

let b:undo_indent = 'setlocal autoindent< expandtab< shiftwidth<'
let b:undo_indent .= ' softtabstop< indentexpr< indentkeys<'

if exists('*GetEclIndent')
  finish
endif

function! GetEclIndent() abort
  if v:lnum <= 1
    return 0
  endif

  " Whitespace within a multiline string is data, so preserve it verbatim.
  " A quote beginning a new string still receives ordinary structural indent.
  let l:first = match(getline(v:lnum), '\S') + 1
  let l:probe = l:first > 0 ? l:first : 1
  let l:syntax = synIDattr(synID(v:lnum, l:probe, 1), 'name')
  if l:syntax =~# '^ecl\%(String\|Escape\)$'
    let l:previous = getline(v:lnum - 1)
    let l:previous_syntax = synIDattr(
          \ synID(v:lnum - 1, strlen(l:previous) + 1, 1), 'name')
    if l:first == 0 || strpart(getline(v:lnum), l:first - 1, 1) !=# '"'
          \ || l:previous_syntax =~# '^ecl\%(String\|Escape\)$'
      return -1
    endif
  endif

  let l:view = winsaveview()
  try
    call cursor(v:lnum, 1)
    let l:ignored = 'synIDattr(synID(line("."), col("."), 1), "name") =~# "^ecl\\%(String\\|Escape\\|Comment\\|Character\\)$"'
    let l:open = searchpairpos('(\|\[\|{', '', ')\|\]\|}', 'bnW', l:ignored)
  finally
    call winrestview(l:view)
  endtry

  if l:open[0] == 0
    return 0
  endif

  " Content aligns just after its unmatched opener. A closing delimiter
  " aligns with the opener itself.
  let l:indent = virtcol(l:open)
  if getline(v:lnum) =~# '^\s*[)\]}]'
    let l:indent -= 1
  endif
  return max([0, l:indent])
endfunction
