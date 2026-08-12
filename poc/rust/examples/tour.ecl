#!/usr/bin/env ecl
# Values are pushed; words consume and produce stack values.
[1 2 3 4] (dup *) each 'squares let
squares pp

# Definitions are quotations plus a quoted name and remain late-bound.
(0 (+) fold) 'total def
[1 2 3] total pp

# Dict literals run their bodies on an isolated stack.
{'input [1 2 3 4]
 'squares squares
 'total squares total}
pp

