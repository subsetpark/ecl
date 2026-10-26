## str

All case and whitespace operations use the ASCII character classes; every
non-ASCII scalar passes through unchanged.

### contains?
`( string needle -- bool )` — Return 1 when a needle occurs anywhere in a
string. The empty needle is present at index zero.

#### Examples

```ecl
"hello" "ell" str.contains?
# => 1
```

### ends?
`( string suffix -- bool )` — Return 1 when a string ends with a suffix.

### format
`( values template -- string )` — Interpolate `{}` placeholders. Strings
contribute their contents; other values contribute canonical `str`. `{{` and
`}}` emit literal braces.

#### Examples

```ecl
["Ada" 2] "name={} n={}" str.format
# => "name=Ada n=2"
```

### index-of
`( string needle -- index )` — Return the zero-based index of a needle's first
occurrence; return 0 for the empty needle and raise `'domain` when a nonempty
needle is absent.

### lower
`( string -- string )` — Lowercase ASCII letters, leaving every other scalar
unchanged.

### pad-left
`( string width -- string )` — Pad with leading spaces up to a width; return a
longer string unchanged.

### pad-right
`( string width -- string )` — Pad with trailing spaces up to a width; return a
longer string unchanged.

### repeat
`( string count -- string )` — Concatenate a nonnegative number of copies of a
string.

### replace
`( string needle replacement -- string )` — Replace every occurrence of a
needle. An empty needle inserts the replacement between adjacent scalars only,
with no boundary insertion.

#### Examples

```ecl
"a-b-c" "-" "+" str.replace
# => "a+b+c"
```

### starts?
`( string prefix -- bool )` — Return 1 when a string begins with a prefix.

### str?
`( value -- bool )` — Return 1 when a value is a string: a list whose every
element is a char. The empty string answers 1, and so does the empty list —
they are one value. Never raises.

### trim
`( string -- string )` — Remove ASCII whitespace from both ends.

#### Examples

```ecl
"  hello  " str.trim
# => "hello"
```

### trim-left
`( string -- string )` — Remove leading ASCII whitespace.

### trim-right
`( string -- string )` — Remove trailing ASCII whitespace.

### upper
`( string -- string )` — Uppercase ASCII letters, leaving every other scalar
unchanged.

#### Examples

```ecl
"Hello, wörld!" str.upper
# => "HELLO, WöRLD!"
```
