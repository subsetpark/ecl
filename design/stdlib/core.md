## Prelude and core

### *%

#### Examples

```ecl
4294967295 4294967295 *%
# => -8589934591
1103515245 4198498305 *% 12345 +% 4294967295 band
# => 1325825702
```

### +

#### Examples

```ecl
1 2 +
# => 3
```

### +%

#### Examples

```ecl
9223372036854775807 1 +%
# => -9223372036854775808
```

### @attempt

#### Examples

```ecl
[1 2] (3 +) @attempt
# => {ok [1 5]}
```

### @attempt!

#### Examples

```ecl
(40 2 +) @attempt!
# => {ok [42]}
```

### @give

#### Examples

```ecl
{address "127.0.0.1" port 0} net.listen
wrap [] (net.local-address `port at 0 >) @give task.await
# => {ok [1]}
```

### @spawn!

#### Examples

```ecl
(40 2 +) @spawn! task.await
# => {ok [42]}
```

### @spawn

#### Examples

```ecl
[] (40 2 +) @spawn task.await
# => {ok [42]}
```

### at

#### Examples

```ecl
[10 20 30] [2 0] at
# => [30 10]
```

### bytes

#### Examples

```ecl
"hé" bytes
# => [104 195 169]
```

### char

#### Examples

```ecl
955 char
# => \λ
```

### chars

#### Examples

```ecl
`foo chars [104 195 169] chars
# => "foo" "hé"
```

### cmp

#### Examples

```ecl
[1 2] [1 3] cmp [["b" 1]] [["a" 2]] cmp [1] [1 0] cmp
# => -1 1 -1
```

### collect

#### Examples

```ecl
9 (1 2 3 +) collect
# => 9 [1 5]
```

### cond

#### Examples

```ecl
10 20 [(pop 10 =) (pop pop 111) (pop pop 222)] cond
# => 111
```

### cut

#### Examples

```ecl
[0 1 2 3 4 5 6] [0 2 5] cut
# => [[0 1] [2 3 4] [5 6]]
"hello world" [6] cut
# => ["world"]
```

### each

#### Examples

```ecl
[1 2 3] (dup *) each
# => [1 4 9]

{a 1 b 2} (1 +) each
# => {a 2 b 3}
```

### exports

#### Examples

```ecl
`archive exports
# => (next-member open-tgz read-member sha256 unpack-tgz)
```

### effect

#### Examples

```ecl
`+ effect
# => (x y -- z)
```

### first

#### Examples

```ecl
(dup swap) first
# => dup
```

### flip

#### Examples

```ecl
(["a" "long"] ["bc" "d"]) flip
# => (("a" "bc") ("long" "d"))
["ab" "cd"] flip
# => ("ac" "bd")
```

### float

#### Examples

```ecl
"2.5e1" float 3 float
# => 25.0 3.0
```

### fold

#### Examples

```ecl
[1 2 3 4] 0 (+) fold
# => 10
```

### grade

#### Examples

```ecl
[3 1 2] grade
# => [1 2 0]
```

### group

#### Examples

```ecl
[a b a] group
# => {a [0 2] b [1]}
```

### in?

#### Examples

```ecl
[2 5] [1 2 3] in?
# => [1 0]
```

### infra

#### Examples

```ecl
[1 2 3] (dup) infra
# => [1 2 3 3]
```

### int

#### Examples

```ecl
"42" int "a" first int
# => 42 97
```

### intern

#### Examples

```ecl
"fresh-name" intern
# => fresh-name
```

### literal

#### Examples

```ecl
`x literal wrap call
# => x
```

### match?

#### Examples

```ecl
[1 2] [1 2] match?
# => 1
```

### pack

#### Examples

```ecl
1 2 3 3 pack
# => [1 2 3]
```

### parse

#### Examples

```ecl
"[1 2]" parse first
# => [1 2]
```

### put

#### Examples

```ecl
[10 20 30] [0 2] 99 put
# => [99 20 99]
```

### range

#### Examples

```ecl
5 range
# => [0 1 2 3 4]
```

### reshape

#### Examples

```ecl
[1 2 3 4] [2 3] reshape
# => [[1 2 3] [4 1 2]]
```

### rotate

#### Examples

```ecl
[1 2 3 4 5] 2 rotate
# => [3 4 5 1 2]
```

### scan

#### Examples

```ecl
[1 2 3 4] 0 (+) scan
# => [1 3 6 10]
```

### sort

#### Examples

```ecl
[3 1 2] sort
# => [1 2 3]
```

### split

#### Examples

```ecl
"a,b,c" "," split
# => ("a" "b" "c")
```

### stencil

#### Examples

```ecl
[1 2 3 4] 3 (sum) stencil
# => [6 9]
```

### str

#### Examples

```ecl
"abc" str
# => "\"abc\""
```

### symbol

#### Examples

```ecl
"foo" symbol `foo match?
# => 1
```

### take

#### Examples

```ecl
[1 2 3] 5 take
# => [1 2 3 1 2]
```

### type

#### Examples

```ecl
"abc" type
# => list
```

### unfold

#### Examples

```ecl
0 (5 <) (dup 1 + swap) unfold pair
# => (5 [0 1 2 3 4])
```

### update

#### Examples

```ecl
[1 2 3] [2 0] (10 *) update
# => [10 2 30]
```

### where

#### Examples

```ecl
[0 2 1] where
# => [1 1 2]
```

### windows

#### Examples

```ecl
[1 2 3 4] 3 windows
# => [[1 2 3] [2 3 4]]
```

### zip-with

#### Examples

```ecl
[1 2 3] [10 20 30] (+) zip-with
# => [11 22 33]
```

### from-digits

#### Examples

```ecl
[1 0 1] 2 from-digits
# => 5
[[1 0] [0 1] [1 1]] 2 from-digits
# => [5 3]
[1 2 3] [24 60 60] from-digits
# => 3723
```

### iterations

#### Examples

```ecl
1 3 (10 +) iterations
# => [1 11 21 31]
```

### partial

#### Examples

```ecl
4 3 (+) partial call
# => 7
```

### while-values

#### Examples

```ecl
1 (5 <) (1 +) while-values
# => [1 2 3 4 5]
```

### with

#### Examples

```ecl
[3] (dup) with call
# => 3 3
```

### @each!

#### Examples

```ecl
[1 2 3] (10 *) @each!
# => [10 20 30]
```

### all?

#### Examples

```ecl
[2 4 6] (2 mod 0 =) all?
# => 1
```

### filter

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) filter
# => [2 4]
```

### partition

#### Examples

```ecl
[1 2 3 4] (2 mod 0 =) partition pair
# => [[2 4] [1 3]]
```

### case

#### Examples

```ecl
3 [1 ("one") 3 ("three") ("other")] case
# => "three"
```

### chunk

#### Examples

```ecl
[0 1 2 3 4 5 6] 3 chunk
# => [[0 1 2] [3 4 5] [6]]
```

### sum

#### Examples

```ecl
[1 2 3] sum
# => 6
[[1 2] [3 4]] sum
# => [4 6]
[] sum
# => 0
```

### to-digits

#### Examples

```ecl
13 [2 2 2 2] to-digits
# => [1 1 0 1]
3723 [24 60 60] to-digits
# => [1 2 3]
-7 [10 10] to-digits
# => [9 3]
```
