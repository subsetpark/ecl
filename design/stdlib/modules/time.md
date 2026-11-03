## time

### format

#### Examples

```ecl
0 time.from-unix time.format
# => "1970-01-01T00:00:00.000Z"
```

### parse

#### Examples

```ecl
"2024-02-29T12:34:56.789+05:30" time.parse time.format
# => "2024-02-29T07:04:56.789Z"
```

### to-utc

#### Examples

```ecl
951782400000 time.from-unix time.to-utc
# => {year 2000 month 2 day 29 hour 0 minute 0 second 0 millisecond 0 weekday 1}
```
