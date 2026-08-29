" Vim filetype plugin
" Language: ecl

if exists('b:did_ftplugin')
  finish
endif
let b:did_ftplugin = 1

setlocal commentstring=#\ %s
setlocal formatprg=ecl\ fmt\ -

let b:undo_ftplugin = 'setlocal commentstring< formatprg<'
