### module pkg.name
# Validate package names and immutable source locators, and compare ownership prefixes.
(
 ### defp chars-in?
 # Test whether a nonempty string contains only characters from a given set.
 (string characters -- bool :
  "Return 1 when a string is nonempty and contains only characters from the given set.")
 (|string characters|
  string empty? not
  string characters (in?) cons all?
  and) `chars-in? defp

 ### setp lead-chars
 # Valid first characters for a package-name segment.
 "abcdefghijklmnopqrstuvwxyz"
 `lead-chars setp

 ### setp segment-chars
 # Valid later characters for a package-name segment.
 "-0123456789abcdefghijklmnopqrstuvwxyz"
 `segment-chars setp

 ### setp hex-chars
 # Lowercase hexadecimal digits.
 "0123456789abcdef"
 `hex-chars setp

 ### defp segment?
 (text -- bool : "Return 1 for a valid package-name segment.")
 (dup empty? (pop 0) ((first lead-chars in?) (segment-chars chars-in?) bi and) if) `segment? defp

 ### def valid?
 (value -- bool :
  "Return 1 for a dot-separated package name. Each segment starts with a lowercase letter and
   continues with lowercase letters, digits, or hyphens.")
 ([(str.str? not) (pop 0)
   (empty?) (pop 0)
   ("." str.split (segment?) all?)]
  cond) `valid? def

 ### def hash?
 (value -- bool : "Return 1 for sha256- followed by 64 lowercase hexadecimal digits.")
 ([(str.str? not) (pop 0)
   ("sha256-" str.starts? not) (pop 0)
   (7 drop (len 64 =) ((hex-chars in?) all?) bi and)]
  cond) `hash? def

 ### defp port-suffix?
 (suffix -- bool : "Accept no port or a colon followed by zero or more ASCII decimal digits.")
 (dup empty? (pop 1)
  (dup ":" str.starts? swap 1 drop ("0123456789" in?) all? and) if) `port-suffix? defp

 ### defp hostname?
 (authority -- bool : "Require a host before an optional port, including bracketed IPv6 hosts.")
 (dup "[" str.starts?
  (1 drop "]" str.split dup len 2 =
   (|parts| parts first empty? not parts 1 at port-suffix? and) (pop 0) if)
  (dup ":" str.split first
   (|authority host| host empty? not authority host len drop port-suffix? and) apply)
  if) `hostname? defp

 ### def url?
 (value -- bool : "Return 1 for a nonempty HTTPS URL.")
 (dup str.str?
  (|url|
   url "https://" str.starts? url len 8 > and
   url "@" str.contains? not and
   url "\\" str.contains? not and
   url "#" str.contains? not and
   url (int 32 >) all? and
   url 8 drop "/" str.split first "?" str.split first hostname? and) (pop 0) if) `url? def

 ### def commit?
 (value -- bool : "Return 1 for a full lowercase SHA-1 Git commit identifier.")
 (dup str.str? ((len 40 =) (hex-chars chars-in?) bi and) (pop 0) if) `commit? def

 ### def owns?
 (package-name module-name -- bool :
  "Return 1 when the module name equals the package name or starts with the package name and a
   dot.")
 (|package module|
  package str.str?
  `type error.new "pkg.name.owns? expects two package names" error.with-message assert
  module str.str?
  `type error.new "pkg.name.owns? expects two package names" error.with-message assert
  package valid?
  `domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  module valid?
  `domain error.new "a package name is dot-joined lowercase segments" error.with-message assert
  package module match?
  module package "." cat str.starts?
  or) `owns? def

 ### defp related?
 (left right -- bool : "Return 1 when either package name owns the other as a prefix.")
 (|left right| left right (owns?) (swap owns?) bi or) `related? defp

 ### def collides?
 (names -- bool : "Return 1 when any two package names have overlapping ownership prefixes.")
 (dup ("." cat) each grade at
  2
  (|neighbors| neighbors first neighbors 1 at related?)
  stencil
  (1 =) any?) `collides? def

 `pkg.test.support `t alias

 ### test ownership
 (-- : "Recognize only a package's own name and dotted descendants.")
 ("foo" "foo" pkg.name.owns? 1 t.equal
  "foo" "foo.bar" pkg.name.owns? 1 t.equal
  "foo" "foo.bar.baz" pkg.name.owns? 1 t.equal
  "foo" "foobar" pkg.name.owns? 0 t.equal
  "foo.bar" "foo" pkg.name.owns? 0 t.equal
  "a.b" "a.b.c" pkg.name.owns? 1 t.equal
  "a.b" "a.c" pkg.name.owns? 0 t.equal
  (5 "foo" pkg.name.owns?) `type "two package names" t.raises-containing
  ("foo" "Foo.Bar" pkg.name.owns?)
  `domain
  "lowercase segments"
  t.raises-containing
  ("foo" "foo..bar" pkg.name.owns?)
  `domain
  "lowercase segments"
  t.raises-containing)
 `ownership test

 ### test url-hostnames
 (-- : "Reject empty URL hosts while retaining ports, queries, and IPv6 literals.")
 (("https://?query" "https://:443/path" "https:///path" "https://[]/path"
   "https://[::1/path")
  (pkg.name.url? 0 t.equal) for
  ("https://example.com/path" "https://example.com:443/path"
   "https://example.com?query" "https://[::1]/path" "https://[::1]:443/path")
  (pkg.name.url? 1 t.equal) for
  ({kind archive url "https://?query"} pkg.manifest.validate-source)
  `domain "HTTPS" t.raises-containing
  ("https://:443/path" pkg.fetch.archive) `domain "HTTPS" t.raises-containing)
 `url-hostnames test

 ### test url-ports
 (-- : "Require an empty authority suffix or a colon followed by decimal port digits.")
 (("https://[::1]suffix/path" "https://[::1]:abc/path"
   "https://[::1]]/path" "https://[::1]:443:80/path"
   "https://example.com:abc/path" "https://example.com:443:80/path"
   "https://example.com:+443/path" "https://[::1]:٤٤٣/path")
  (pkg.name.url? 0 t.equal) for
  ("https://example.com:/path" "https://[::1]:/path"
   "https://example.com:00443?query" "https://[::1]:00443?query")
  (pkg.name.url? 1 t.equal) for
  ({kind archive url "https://[::1]suffix/path"} pkg.manifest.validate-source)
  `domain "HTTPS" t.raises-containing
  ("https://example.com:abc/path" pkg.fetch.archive) `domain "HTTPS" t.raises-containing)
 `url-ports test

 ### test documentation
 (-- : "Require documentation for every package-name export.")
 ((pkg.name.valid? pkg.name.hash? pkg.name.url?
   pkg.name.owns? pkg.name.collides?)
  t.documented)
 `documentation test
) `pkg.name @defm
