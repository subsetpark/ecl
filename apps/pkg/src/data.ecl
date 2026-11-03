### module pkg.data
# Parse package metadata without evaluating it; a parsed form is only ever data.
[]
(
 ### def read-one
 (text -- form : "Parse text containing exactly one form and return it without evaluation.")
 (|text|
  text str.str?
  `type error.new "pkg reads a package file from text" error.with-message assert
  text parse-one) `read-one def

 ### defp entry-of
 (key holder -- pair : "Return a key and its value as a pair.")
 (|key holder| key holder key at pair) `entry-of defp

 ### def sorted-entries
 (holder -- pairs : "Return a dict's entries in ascending key order.")
 (|holder| holder dict.keys sort holder (entry-of) partial each) `sorted-entries def
) `pkg.data @defm
