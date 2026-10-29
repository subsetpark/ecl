## str

All case and whitespace operations use the ASCII character classes; every
non-ASCII scalar passes through unchanged.

### contains?

#### Examples

```ecl
"hello" "ell" str.contains?
# => 1
```

### format

#### Examples

```ecl
["Ada" 2] "name={} n={}" str.format
# => "name=Ada n=2"
```

### replace

#### Examples

```ecl
"a-b-c" "-" "+" str.replace
# => "a+b+c"
```

### trim

#### Examples

```ecl
"  hello  " str.trim
# => "hello"
```

### upper

#### Examples

```ecl
"Hello, wörld!" str.upper
# => "HELLO, WöRLD!"
```
