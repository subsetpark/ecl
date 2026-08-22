### module pkg.name
# Validate package names and immutable source locators, and compare ownership prefixes.
(
 ### defp chars-in?
 # Test whether a nonempty string contains only characters from a given set.
 (|string characters|
  string empty? not
  string characters (in?) partial all?
  and)
 (string characters -- bool :
  "Return 1 when a string is nonempty and contains only characters from the given set.")
 'chars-in? defp

 ### defp lead-chars
 # Valid first characters for a package-name segment.
 "abcdefghijklmnopqrstuvwxyz"
 'lead-chars setp

 ### defp segment-chars
 # Valid later characters for a package-name segment.
 "-0123456789abcdefghijklmnopqrstuvwxyz"
 'segment-chars setp

 ### defp hex-chars
 # Lowercase hexadecimal digits.
 "0123456789abcdef"
 'hex-chars setp

 ### defp segment?
 (dup empty? (pop 0) ((first lead-chars in?) (segment-chars chars-in?) bi and) if)
 (text -- bool : "Return 1 for a valid package-name segment.")
 'segment? defp

 ### def valid?
 ([(str.str? not) (pop 0)
   (empty?) (pop 0)
   ("." split (segment?) all?)]
  cond)
 (value -- bool :
  "Return 1 for a dot-separated package name. Each segment starts with a lowercase letter and
   continues with lowercase letters, digits, or hyphens.")
 'valid? def

 ### def hash?
 ([(str.str? not) (pop 0)
   ("sha256-" str.starts? not) (pop 0)
   (7 drop (len 64 =) ((hex-chars in?) all?) bi and)]
  cond)
 (value -- bool : "Return 1 for sha256- followed by 64 lowercase hexadecimal digits.")
 'hash? def

 ### def url?
 (dup str.str? (("https://" str.starts?) (len 8 >) bi and) (pop 0) if)
 (value -- bool : "Return 1 for a nonempty HTTPS URL.")
 'url? def

 ### def owns?
 (|package module|
  package str.str?
  {'kind 'type 'msg "pkg.name.owns? expects two package names"} assert
  module str.str?
  {'kind 'type 'msg "pkg.name.owns? expects two package names"} assert
  package valid?
  {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
  module valid?
  {'kind 'domain 'msg "a package name is dot-joined lowercase segments"} assert
  package module match?
  module package "." cat str.starts?
  or)
 (package-name module-name -- bool :
  "Return 1 when the module name equals the package name or starts with the package name and a
   dot.")
 'owns? def

 ### defp related?
 (|left right| left right (owns?) (swap owns?) bi2 or)
 (left right -- bool : "Return 1 when either package name owns the other as a prefix.")
 'related? defp

 ### def collides?
 (dup ("." cat) each grade at
  2
  (|neighbors| neighbors first neighbors 1 at related?)
  stencil
  (1 =) any?)
 (names -- bool : "Return 1 when any two package names have overlapping ownership prefixes.")
 'collides? def
 )
'pkg.name
@defm
