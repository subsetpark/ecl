### module pkg.data
# Parse package metadata as inert data without evaluating it.
(
 ### defp inert?
 (value -- bool : "Return 1 when a value recursively contains no executable words.")
 ([(type 'word match?) (pop 0)
   (type 'dict match?) (dict.vals (inert?) all?)
   (type 'list match?) ((inert?) all?)
   (pop 1)]
  cond)
 'inert? defp

 ### defp offending
 (key -- : "Raise an inert-data error for a dict entry.")
 (|key|
  'domain error.new "a manifest or lock holds only inert data" error.with-message
  'key key pair dict.from-flat
  error.with-data
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
  'type error.new "pkg reads a package file from text" error.with-message assert
  text parse
  dup len 1 =
  'shape error.new "a package file is exactly one form" error.with-message assert
  first)
 'read-one def

 ### defp entry-of
 (key holder -- pair : "Return a key and its value as a pair.")
 (|key holder| key holder key at pair)
 'entry-of defp

 ### def sorted-entries
 (holder -- pairs : "Return a dict's entries in ascending key order.")
 (|holder| holder dict.keys sort holder (entry-of) partial each)
 'sorted-entries def
) 'pkg.data @defm
