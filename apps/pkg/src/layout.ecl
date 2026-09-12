### module pkg.layout
# Closed generation locations belong to the application, never the interpreter.
[]
(
 ### defp require
 (condition -- : "Reject an invalid application generation reference.")
 ('domain error.new "invalid package generation reference" error.with-message assert) 'require defp

 ### defp identifier?
 (value -- bool : "Recognize a single lowercase hexadecimal generation identifier.")
 (dup str.str? ("sha256-" swap cat pkg.name.hash?) (pop 0) if) 'identifier? defp

 ### def generation?
 (value -- bool : "Recognize project-local or vendored immutable generation locations.")
 (dup str.str?
  ("/" split dup len 3 =
   (dup first ".ecl" match? over 1 at "generations" match? and swap 2 at identifier? and)
   (dup len 2 = (dup first "vendor" match? swap 1 at identifier? and) (pop 0) if)
   if)
  (pop 0) if) 'generation? def

 ### def project-generation
 (identifier -- path : "Name one immutable project-local generation.")
 (dup identifier? require ".ecl/generations/" swap cat) 'project-generation def

 ### def vendor-generation
 (identifier -- path : "Name one self-contained vendored generation.")
 (dup identifier? require "vendor/" swap cat) 'vendor-generation def

 ### def local-root
 (generation -- relative-root :
  "Locate live project sources relative to a complete generation map.")
 (dup generation? require "/" split len 3 = ("../../..") ("../..") if) 'local-root def

 ### def reference
 (generation -- text : "Render the root runtime map reference without package metadata.")
 (dup generation? require "/ecl.modules" cat str wrap
  "{{'format 1 'map {}}}\n" str.format) 'reference def

 ### def from-reference
 (text -- generation : "Read a root reference to one application-owned immutable generation.")
 (pkg.data.read-one dup type 'dict match? require dup ['format 'map] dict.keys-exactly? require
  dup 'format at 1 match? require
  'map at dup str.str? require dup "/ecl.modules" str.ends? require
  dup len 12 - take dup generation? require) 'from-reference def
) 'pkg.layout @defm
