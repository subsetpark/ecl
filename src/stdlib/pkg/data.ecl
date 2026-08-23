### module pkg.data
# Parse package metadata as inert data without evaluating it.
(
 ### defp inert?
 (value -- bool : "Return 1 when a value recursively contains no executable words.")
 ([(type 'word match?) (pop 0)
   (type 'dict match?) (vals (inert?) all?)
   (type 'list match?) ((inert?) all?)
   (pop 1)]
  cond)
 'inert? defp

 ### defp offending
 (key -- : "Raise an inert-data error for a dict entry.")
 (|key|
  {'kind 'domain 'msg "a manifest or lock holds only inert data"}
  'data
  'key key pair dict-of
  put
  raise)
 'offending defp

 ### def assert-inert-entry
 (pair -- : "Discard an inert entry, or raise an error that names its key.")
 (dup inert? (pop) (first offending) if)
 'assert-inert-entry def

 ### def read-one
 (text -- form : "Parse text containing exactly one form and return it without evaluation.")
 (|text|
  text str.str?
  {'kind 'type 'msg "pkg reads a package file from text"} assert
  text parse
  dup len 1 =
  {'kind 'shape 'msg "a package file is exactly one form"} assert
  first)
 'read-one def

 ### defp entry-of
 (key holder -- pair : "Return a key and its value as a pair.")
 (|key holder| key holder key at pair)
 'entry-of defp

 ### def sorted-entries
 (holder -- pairs : "Return a dict's entries in ascending key order.")
 (|holder| holder keys sort holder (entry-of) partial each)
 'sorted-entries def
 ) 'pkg.data @defm
