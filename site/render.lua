-- Render an ECL source file into the site template with Neovim's TOhtml,
-- using the repository's syntax file. Classes in the output are Neovim's
-- resolved highlight groups (Comment, Statement, ...); the template styles them.
--
-- nvim --headless --clean -l site/render.lua <source.ecl> <template.html> <out.html>

local src, template, out = arg[1], arg[2], arg[3]
assert(src and template and out, 'usage: render.lua <source.ecl> <template.html> <out.html>')

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(arg[0], ':p'))))
vim.opt.runtimepath:prepend(root .. '/runtime')
vim.cmd('packadd nvim.tohtml')
vim.cmd('syntax on')
vim.cmd.edit(vim.fn.fnameescape(src))
vim.bo.filetype = 'ecl'

local html = require('tohtml').tohtml(0, { title = false })
local first, last
for i, line in ipairs(html) do
  if line == '<pre>' then
    first = i
  elseif line == '</pre>' then
    last = i
  end
end
assert(first and last, 'TOhtml output has no <pre> block')

local code = table.concat(html, '\n', first, last)
local page = assert(io.open(template)):read('a')
local result, n = page:gsub('<!%-%- code %-%->', function() return code end)
assert(n == 1, 'template must contain exactly one <!-- code --> marker')

local f = assert(io.open(out, 'w'))
f:write(result)
f:close()
