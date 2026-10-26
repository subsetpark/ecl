## time

Pure UTC time over the millisecond timestamps `clock.unix` produces. Every
word accepts and returns whole milliseconds; a timestamp is `{'unix ms}` and
nothing else — a `{'monotonic ms}` instant, an untagged int, a float payload,
or a dictionary with any other key is `'type`. Arithmetic is checked: leaving
the int millisecond range is `'overflow`. Calendar words use the proleptic
Gregorian calendar with no leap seconds, so Unix time here is the POSIX count
in which every day has exactly 86,400,000 milliseconds. The representable
range runs from `-292275055-05-16T16:47:04.192` through
`292278994-08-17T07:12:55.807`. Nothing in this module reads a clock.

### add
`( timestamp milliseconds -- timestamp )` — Shift a timestamp by a signed int
duration.

### cmp
`( left right -- ordering )` — Three-way order two timestamps as −1, 0, or 1.
Whole-value `match?` also compares timestamps; `<` and `=` do not.

### days
`( n -- milliseconds )` — `n` days of 86,400 seconds as milliseconds.

### diff
`( later earlier -- milliseconds )` — `later` minus `earlier`, signed.

### format
`( timestamp -- string )` — Render as `YYYY-MM-DDTHH:MM:SS.mmmZ`: always UTC,
always three fractional digits, so `format` then `parse` returns the same
timestamp and `parse` then `format` returns the same text for every string in
that shape. A year outside 0000 through 9999 cannot be written in four digits
and is `'domain`.

#### Examples

```ecl
0 time.from-unix time.format
# => "1970-01-01T00:00:00.000Z"
```

### from-unix
`( milliseconds -- timestamp )` — Tag an int as `{'unix ms}`. Negative counts
name instants before 1970.

### from-utc
`( fields -- timestamp )` — Build a timestamp from a dictionary of int fields.
`'year`, `'month`, and `'day` are required; `'hour`, `'minute`, `'second`, and
`'millisecond` default to 0; `'weekday` is optional and must agree with the
date. Any other key is `'domain`; a non-symbol key or non-int value is `'type`.
Month is 1 through 12, day is 1 through the month's length in that year, hour
0 through 23, minute and second 0 through 59, millisecond 0 through 999;
anything else is `'domain`. `to-utc` output round-trips exactly.

### hours
`( n -- milliseconds )` — `n` hours as milliseconds.

### minutes
`( n -- milliseconds )` — `n` minutes as milliseconds.

### parse
`( string -- timestamp )` — Parse an RFC 3339 `date-time`:
`YYYY-MM-DDTHH:MM:SS`, an optional fraction of one or more digits, then `Z` or
a numeric `±HH:MM` offset that is subtracted to reach UTC. `T` and `Z` may be
lower case. The first three fractional digits are kept and the rest are
discarded, so `"…​:00.1239Z"` and `"…​:00.123Z"` parse alike. Text outside the
grammar — a space separator, a missing designator, trailing characters, a
non-ASCII scalar, an empty fraction — is `'parse`; a well-formed field outside
its range, including second `60`, is `'domain`.

#### Examples

```ecl
"2024-02-29T12:34:56.789+05:30" time.parse time.format
# => "2024-02-29T07:04:56.789Z"
```

### seconds
`( n -- milliseconds )` — `n` seconds as milliseconds.

### to-unix
`( timestamp -- milliseconds )` — The int inside a timestamp.

### to-utc
`( timestamp -- fields )` — Decompose into
`{'year 'month 'day 'hour 'minute 'second 'millisecond 'weekday}`, all ints.
`'weekday` counts from Monday as 0 through Sunday as 6. Years before 1 are
negative in astronomical numbering (year 0 is 1 BC and is a leap year).

#### Examples

```ecl
951782400000 time.from-unix time.to-utc
# => {'year 2000 'month 2 'day 29 'hour 0 'minute 0 'second 0 'millisecond 0 'weekday 1}
```
