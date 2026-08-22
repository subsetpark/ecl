### module pkg.data
# Parse package metadata as inert data without evaluating it.
(
 ### defp inert?
 ([(type 'word match?) (pop 0)
   (type 'dict match?) (vals (inert?) all?)
   (type 'list match?) ((inert?) all?)
   (pop 1)]
  cond)
 (value -- bool : "Return 1 when a value recursively contains no executable words.")
 'inert? defp

 ### defp offending
 (|key|
  {'kind 'domain 'msg "a manifest or lock holds only inert data"}
  'data
  'key key pair dict-of
  put
  raise)
 (key -- : "Raise an inert-data error for a dict entry.")
 'offending defp

 ### def assert-inert-entry
 (dup inert? (pop) (first offending) if)
 (pair -- : "Discard an inert entry, or raise an error that names its key.")
 'assert-inert-entry def

 ### def read-one
 (|text|
  text str.str?
  {'kind 'type 'msg "pkg reads a package file from text"} assert
  text parse
  dup len 1 =
  {'kind 'shape 'msg "a package file is exactly one form"} assert
  first)
 (text -- form : "Parse text containing exactly one form and return it without evaluation.")
 'read-one def

 ### defp entry-of
 (|key holder| key holder key at pair)
 (key holder -- pair : "Return a key and its value as a pair.")
 'entry-of defp

 ### def sorted-entries
 (|holder| holder keys sort holder (entry-of) partial each)
 (holder -- pairs : "Return a dict's entries in ascending key order.")
 'sorted-entries def
 )
'pkg.data
@defm
