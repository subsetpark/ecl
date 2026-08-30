### module stdlib.test.error
(
 'stdlib.test.support
 ('equal 'raises-containing 'documented)
 import

 ### test construction-and-validation
 (-- : "Construct error dictionaries and validate the raise-compatible schema.")
 ('domain error.new {'kind 'domain} equal
  'custom error.new "broken" error.with-message {'detail 7} error.with-data
  {'kind 'custom 'msg "broken" 'data {'detail 7}} equal
  {'kind 'io 'msg "x" 'word 'read 'trace ['outer 'inner]
   'data {'path "p"}}
  error.valid?
  1 equal
  {'kind 'io 'msg 7} error.valid? 0 equal
  {'msg "missing kind"} error.valid? 0 equal
  7 error.valid? 0 equal
  (missing) @attempt 'err at error.valid? 1 equal
  {'kind 'custom 'extra 1} error.valid? 1 equal)
 'construction-and-validation test

 ### test kind-predicates
 (-- : "Compare and select validated error kinds.")
 ('io error.new 'io error.kind? 1 equal
  'io error.new 'type error.kind? 0 equal
  'timeout error.new ['io 'timeout] error.kind-in? 1 equal
  'domain error.new ['io 'timeout] error.kind-in? 0 equal
  (7 error.new) 'type "kind symbol" raises-containing
  ('io error.new 7 error.with-message)
  'type
  "string message"
  raises-containing
  ('io error.new 7 error.with-data) 'type "data dict" raises-containing
  ('io error.new ['io 7] error.kind-in?)
  'type
  "list of kind symbols"
  raises-containing)
 'kind-predicates test

 ### test documentation
 (-- : "Expose documentation for every error module export.")
 (['error.new 'error.with-message 'error.with-data 'error.valid?
   'error.kind? 'error.kind-in?]
  documented)
 'documentation test
) 'stdlib.test.error @defm
