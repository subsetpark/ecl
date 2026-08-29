### module pkg.name
# Validate package names and immutable source locators, and compare ownership prefixes.
(
 ### defp chars-in?
 # Test whether a nonempty string contains only characters from a given set.
 (string characters -- bool :
  "Return 1 when a string is nonempty and contains only characters from the given set.")
 (|string characters|
  string empty? not
  string characters (in?) partial all?
  and)
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
 (text -- bool : "Return 1 for a valid package-name segment.")
 (dup empty? (pop 0) ((first lead-chars in?) (segment-chars chars-in?) bi and) if)
 'segment? defp

 ### def valid?
 (value -- bool :
  "Return 1 for a dot-separated package name. Each segment starts with a lowercase letter and
   continues with lowercase letters, digits, or hyphens.")
 ([(str.str? not) (pop 0)
   (empty?) (pop 0)
   ("." split (segment?) all?)]
  cond)
 'valid? def

 ### def hash?
 (value -- bool : "Return 1 for sha256- followed by 64 lowercase hexadecimal digits.")
 ([(str.str? not) (pop 0)
   ("sha256-" str.starts? not) (pop 0)
   (7 drop (len 64 =) ((hex-chars in?) all?) bi and)]
  cond)
 'hash? def

 ### def url?
 (value -- bool : "Return 1 for a nonempty HTTPS URL.")
 (dup str.str? (("https://" str.starts?) (len 8 >) bi and) (pop 0) if)
 'url? def

 ### def owns?
 (package-name module-name -- bool :
  "Return 1 when the module name equals the package name or starts with the package name and a
   dot.")
 (|package module|
  package str.str?
  'type error.new "pkg.name.owns? expects two package names" error.with-message assert
  module str.str?
  'type error.new "pkg.name.owns? expects two package names" error.with-message assert
  package valid?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  module valid?
  'domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  package module match?
  module package "." cat str.starts?
  or)
 'owns? def

 ### defp related?
 (left right -- bool : "Return 1 when either package name owns the other as a prefix.")
 (|left right| left right (owns?) (swap owns?) bi2 or)
 'related? defp

 ### def collides?
 (names -- bool : "Return 1 when any two package names have overlapping ownership prefixes.")
 (dup ("." cat) each grade at
  2
  (|neighbors| neighbors first neighbors 1 at related?)
  stencil
  (1 =) any?)
 'collides? def
) 'pkg.name @defm
