### module port
# Common resource operations and compositions. Calls observe their result
# under an error boundary and join exchange cleanup before returning it.
[]
(
 `port.core [open begin endpoint send receive finish await result cancel shutdown close] import

 ### def call
 (resource operation request -- value :
  "Begin an operation, claim its result, and close the exchange. Use only when no additional
   streaming input or output is required. Close the exchange before returning or re-raising its
   error.")
 (begin dup wrap (result) @attempt swap close result.or-raise first) `call def
) `port @defm
