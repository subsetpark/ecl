## time

Pure UTC time over the millisecond timestamps `clock.unix` produces. Every
word accepts and returns whole milliseconds; a timestamp is `{unix ms}` and
nothing else — a `{monotonic ms}` instant, an untagged int, a float payload,
or a dictionary with any other key is `` `type ``. Arithmetic is checked: leaving
the int millisecond range is `` `overflow ``. Calendar words use the proleptic
Gregorian calendar with no leap seconds, so Unix time here is the POSIX count
in which every day has exactly 86,400,000 milliseconds. The representable
range runs from `-292275055-05-16T16:47:04.192` through
`292278994-08-17T07:12:55.807`. Nothing in this module reads a clock.

### add

### cmp

### days

### diff

### format

#### Examples

```ecl
0 time.from-unix time.format
# => "1970-01-01T00:00:00.000Z"
```

### from-unix

### from-utc

### hours

### minutes

### parse

#### Examples

```ecl
"2024-02-29T12:34:56.789+05:30" time.parse time.format
# => "2024-02-29T07:04:56.789Z"
```

### seconds

### to-unix

### to-utc

#### Examples

```ecl
951782400000 time.from-unix time.to-utc
# => {year 2000 month 2 day 29 hour 0 minute 0 second 0 millisecond 0 weekday 1}
```
