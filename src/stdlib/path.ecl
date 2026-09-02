### module path
# Lexical slash-path operations over Unicode strings. Nothing here reads the
# filesystem, consults the working directory, or follows links, and a
# normalized string is never proof of containment: `fs` enforces that at its
# directory handles.
[]
(
 ### defp checked
 (value message -- string : "Validate a string argument or raise 'type with the message.")
 (|value message| value str.str? 'type error.new message error.with-message assert value)
 'checked defp

 ### def absolute?
 (path -- bool : "Return 1 when the path begins with a slash.")
 ("path.absolute? expects a string path" checked "/" str.starts?)
 'absolute? def

 ### def relative?
 (path -- bool : "Return 1 when the path does not begin with a slash.")
 ("path.relative? expects a string path" checked "/" str.starts? not)
 'relative? def

 ### defp skip-component?
 (part -- bool : "Return 1 for an empty or `.` component, which normalization drops.")
 (dup "" match? swap "." match? or)
 'skip-component? defp

 ### defp poppable?
 (parts -- bool : "Return 1 when the last retained component is real rather than a leading `..`.")
 (dup len 0 > (last ".." match? not) (pop 0) if)
 'poppable? defp

 ### defp pop-component
 (parts -- parts : "Drop the last retained component.")
 (dup len 1 - take)
 'pop-component defp

 ### defp append-part
 (state part -- state : "Retain one component.")
 (over 'parts at swap append 'parts swap put)
 'append-part defp

 ### defp parent-step
 (state -- state :
  "Apply one `..` component: pop a real component, clamp at an absolute root, or retain it.")
 (dup 'parts at dup poppable?
  (pop-component 'parts swap put)
  (pop dup 'absolute at () (".." append-part) if)
  if)
 'parent-step defp

 ### defp clean-step
 (state part -- state : "Apply one raw component to the normalized component list.")
 (dup skip-component? (pop) (dup ".." match? (pop parent-step) (append-part) if) if)
 'clean-step defp

 ### def normalize
 (path -- path :
  "Lexically clean a slash path: collapse repeated separators and `.` components, resolve `..`
   against preceding components, keep leading `..` in a relative path, clamp an absolute path at
   `/`, and return `.` for an empty result.")
 ("path.normalize expects a string path" checked
  dup "/" str.starts?
  swap "/" split
  over 'absolute swap 'parts [] 4 pack dict.from-flat
  (clean-step) fold
  'parts at "/" core.join
  swap ("/" swap cat) () if
  dup "" match? (pop ".") () if)
 'normalize def

 ### def join
 (segments -- path :
  "Join string segments with `/` and normalize the result; empty segments are ignored and an empty
   or all-empty list yields `.`.")
 (dup type 'list match?
  'type error.new "path.join expects a list of string segments" error.with-message assert
  dup (str.str?) all?
  'type error.new "path.join expects a list of string segments" error.with-message assert
  ("" match? not) filter "/" core.join normalize)
 'join def

 ### def dirname
 (path -- path :
  "Return the normalized directory portion before the last slash, or `.` when the path has no
   slash.")
 ("path.dirname expects a string path" checked
  "/" split
  dup len 1 =
  (pop ".")
  (pop-component "/" core.join "/" cat normalize)
  if)
 'dirname def

 ### defp strip-trailing-slashes
 (path -- path : "Remove every trailing slash.")
 (dup "/" str.ends? (pop-component strip-trailing-slashes) () if)
 'strip-trailing-slashes defp

 ### def basename
 (path -- name :
  "Return the last element after trailing slashes are removed: `/` for a path of only slashes and
   `.` for an empty path.")
 ("path.basename expects a string path" checked
  dup "" match?
  (pop ".")
  (strip-trailing-slashes dup "" match? (pop "/") ("/" split last) if)
  if)
 'basename def

 ### def extension
 (path -- extension :
  "Return the suffix beginning at the final dot of the last element, including the dot, or the empty
   string when that element has no dot.")
 ("path.extension expects a string path" checked
  "/" split last "." split
  dup len 1 =
  (pop "")
  (last "." swap cat)
  if)
 'extension def

 ### def components
 (path -- components :
  "Normalize the path and return its non-separator components; `.` and `/` yield an empty list and
   retained leading `..` components remain.")
 ("path.components expects a string path" checked normalize
  dup "." match? (pop []) ("/" split ("" match? not) filter) if)
 'components def

 ### defp valid-component?
 (component -- bool : "Test one component of the canonical `fs` grammar.")
 (|c| c "" match? not c "." match? not and c ".." match? not and c "\u{0}" str.contains? not and)
 'valid-component? defp

 ### def valid-relative?
 (path -- bool :
  "Return 1 when the string is a canonical relative path accepted by `fs`: `.` alone, or nonempty
   components separated by single slashes with no `.`, `..`, or NUL and no leading or trailing
   slash. Normalize first when accepting untrusted text; this predicate never normalizes.")
 ("path.valid-relative? expects a string path" checked
  dup "." match?
  (pop 1)
  (dup "" match? (pop 0) ("/" split (valid-component?) all?) if)
  if)
 'valid-relative? def
) 'path @defm
