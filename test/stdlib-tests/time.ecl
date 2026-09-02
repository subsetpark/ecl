### module stdlib.test.time
[]
(
 'stdlib.test.support
 ('equal 'raises 'raises-word 'raises-containing 'documented)
 import

 ### defp utc-fields
 (timestamp -- fields : "Return year month day hour minute second millisecond weekday as a list.")
 (time.to-utc
  ['year 'month 'day 'hour 'minute 'second 'millisecond 'weekday]
  swap (swap at) partial each)
 'utc-fields defp

 ### test epoch-boundaries
 (-- : "Decompose and render the Unix epoch and the instants around it.")
 (0 time.from-unix time.format "1970-01-01T00:00:00.000Z" equal
  -1 time.from-unix time.format "1969-12-31T23:59:59.999Z" equal
  1 time.from-unix time.format "1970-01-01T00:00:00.001Z" equal
  0 time.from-unix utc-fields [1970 1 1 0 0 0 0 3] equal
  -1 time.from-unix utc-fields [1969 12 31 23 59 59 999 2] equal
  86400000 time.from-unix utc-fields [1970 1 2 0 0 0 0 4] equal
  -86400000 time.from-unix utc-fields [1969 12 31 0 0 0 0 2] equal
  946684800000 time.from-unix utc-fields [2000 1 1 0 0 0 0 5] equal
  "2024-02-29T00:00:00Z" time.parse utc-fields [2024 2 29 0 0 0 0 3] equal)
 'epoch-boundaries test

 ### test extremes
 (-- :
  "Decompose and rebuild the largest and smallest int millisecond counts in the proleptic Gregorian
   calendar.")
 (9223372036854775807 time.from-unix utc-fields
  [292278994 8 17 7 12 55 807 6] equal
  -9223372036854775808 time.from-unix utc-fields
  [-292275055 5 16 16 47 4 192 6] equal
  {'year 292278994 'month 8 'day 17 'hour 7 'minute 12 'second 55 'millisecond 807}
  time.from-utc time.to-unix 9223372036854775807 equal
  {'year -292275055 'month 5 'day 16 'hour 16 'minute 47 'second 4 'millisecond 192}
  time.from-utc time.to-unix -9223372036854775808 equal
  ({'year -292275055 'month 5 'day 16 'hour 16 'minute 47 'second 4 'millisecond 191}
   time.from-utc)
  'overflow 'time.from-utc raises-word
  ({'year 292278994 'month 8 'day 17 'hour 7 'minute 12 'second 55 'millisecond 808}
   time.from-utc)
  'overflow 'time.from-utc raises-word
  ({'year 292278995 'month 1 'day 1} time.from-utc) 'overflow 'time.from-utc raises-word
  ({'year 9223372036854775807 'month 1 'day 1} time.from-utc) 'overflow 'time.from-utc raises-word)
 'extremes test

 ### test leap-years
 (-- : "Apply the proleptic Gregorian leap rule to construction and parsing.")
 ({'year 2000 'month 2 'day 29} time.from-utc time.format "2000-02-29T00:00:00.000Z" equal
  {'year 2024 'month 2 'day 29} time.from-utc utc-fields [2024 2 29 0 0 0 0 3] equal
  ({'year 1900 'month 2 'day 29} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2023 'month 2 'day 29} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2100 'month 2 'day 29} time.from-utc) 'domain 'time.from-utc raises-word
  ("2023-02-29T00:00:00Z" time.parse) 'domain 'time.parse raises-word
  {'year 2000 'month 12 'day 31} time.from-utc 86400000 time.add utc-fields
  [2001 1 1 0 0 0 0 0] equal)
 'leap-years test

 ### test invalid-fields
 (-- : "Reject calendar fields outside their ranges and malformed field dictionaries.")
 (({'year 2024 'month 0 'day 1} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2024 'month 13 'day 1} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2024 'month 1 'day 0} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2024 'month 1 'day 32} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2024 'month 4 'day 31} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2024 'month 1 'day 1 'hour 24} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2024 'month 1 'day 1 'minute 60} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2024 'month 1 'day 1 'second 60} time.from-utc) 'domain "leap seconds" raises-containing
  ({'year 2024 'month 1 'day 1 'millisecond 1000} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2024 'month 1 'day 1 'hour -1} time.from-utc) 'domain 'time.from-utc raises-word
  ({'year 2024 'month 1} time.from-utc) 'domain "requires year, month, and day" raises-containing
  ({'year 2024 'month 1 'day 1 'zone "UTC"} time.from-utc) 'domain "accepts only" raises-containing
  ({'year 2024 'month 1 'day 1.0} time.from-utc) 'type 'time.from-utc raises-word
  ({"year" 2024 'month 1 'day 1} time.from-utc) 'type 'time.from-utc raises-word
  (2024 time.from-utc) 'type 'time.from-utc raises-word
  ({'year 2024 'month 1 'day 1 'weekday 5} time.from-utc) 'domain "weekday" raises-containing
  {'year 2024 'month 1 'day 1 'weekday 0} time.from-utc time.format "2024-01-01T00:00:00.000Z" equal)
 'invalid-fields test

 ### test fractional-precision
 (-- : "Keep three fractional digits and discard the rest.")
 ("2024-01-01T00:00:00.5Z" time.parse time.to-unix 1704067200500 equal
  "2024-01-01T00:00:00.123456789Z" time.parse time.to-unix 1704067200123 equal
  "2024-01-01T00:00:00.1239Z" time.parse time.to-unix 1704067200123 equal
  "2024-01-01T00:00:00.000Z" time.parse time.to-unix 1704067200000 equal
  "2024-01-01T00:00:00Z" time.parse "2024-01-01T00:00:00.000Z" time.parse equal
  ("2024-01-01T00:00:00.Z" time.parse) 'parse 'time.parse raises-word)
 'fractional-precision test

 ### test offsets
 (-- : "Convert numeric offsets to UTC and accept lower-case designators.")
 ("2024-02-29T12:34:56.789+05:30" time.parse time.format "2024-02-29T07:04:56.789Z" equal
  "2024-02-29t12:34:56.789z" time.parse time.format "2024-02-29T12:34:56.789Z" equal
  "1969-12-31T23:59:59.500-01:00" time.parse time.format "1970-01-01T00:59:59.500Z" equal
  "2024-01-01T00:00:00+00:00" time.parse time.to-unix 1704067200000 equal
  "2024-01-01T00:00:00-00:00" time.parse time.to-unix 1704067200000 equal
  "2024-01-01T02:00:00+02:00" time.parse "2024-01-01T00:00:00Z" time.parse equal
  ("2024-01-01T00:00:00+24:00" time.parse) 'domain 'time.parse raises-word
  ("2024-01-01T00:00:00+00:60" time.parse) 'domain 'time.parse raises-word)
 'offsets test

 ### test malformed
 (-- : "Reject text outside the RFC 3339 date-time grammar with 'parse.")
 (("2024-01-01 00:00:00Z" time.parse) 'parse 'time.parse raises-word
  ("2024-01-01T00:00:00" time.parse) 'parse 'time.parse raises-word
  ("2024-01-01T00:00:00Z " time.parse) 'parse 'time.parse raises-word
  ("2024-1-01T00:00:00Z" time.parse) 'parse 'time.parse raises-word
  ("2024-01-01T00:00Z" time.parse) 'parse 'time.parse raises-word
  ("2024-01-01T00:00:00+0530" time.parse) 'parse 'time.parse raises-word
  ("2024-01-01T00:00:00Ｚ" time.parse) 'parse 'time.parse raises-word
  ("" time.parse) 'parse 'time.parse raises-word
  ("2024-01-01T00:00:00.0000000000000000000000000000000000000Z" time.parse)
  'parse 'time.parse raises-word
  ("2024-01-01T00:00:60Z" time.parse) 'domain 'time.parse raises-word
  ("2024-13-01T00:00:00Z" time.parse) 'domain 'time.parse raises-word
  ("2024-01-01T24:00:00Z" time.parse) 'domain 'time.parse raises-word
  (5 time.parse) 'type 'time.parse raises-word)
 'malformed test

 ### test round-trips
 (-- : "Preserve millisecond timestamps through format and parse in both directions.")
 (("1970-01-01T00:00:00.000Z" "1969-12-31T23:59:59.999Z" "2000-02-29T23:59:59.999Z"
   "9999-12-31T23:59:59.999Z" "0000-01-01T00:00:00.000Z" "2024-07-04T12:00:00.250Z")
  (dup time.parse time.format equal) for
  (0 -1 1 1704067200123 -62167219200000 253402300799999 951868799999)
  (dup time.from-unix time.format time.parse time.to-unix equal) for
  (0 -1 1704067200123 -62167219200000 9223372036854775807 -9223372036854775808)
  (dup time.from-unix time.to-utc time.from-utc time.to-unix equal) for)
 'round-trips test

 ### test format-range
 (-- : "Render only four-digit years.")
 (253402300799999 time.from-unix time.format "9999-12-31T23:59:59.999Z" equal
  -62167219200000 time.from-unix time.format "0000-01-01T00:00:00.000Z" equal
  (253402300800000 time.from-unix time.format) 'domain 'time.format raises-word
  (-62167219200001 time.from-unix time.format) 'domain 'time.format raises-word
  (9223372036854775807 time.from-unix time.format) 'domain 'time.format raises-word)
 'format-range test

 ### test arithmetic
 (-- : "Shift, difference, and order timestamps with checked millisecond arithmetic.")
 (5 time.from-unix 7 time.add time.to-unix 12 equal
  5 time.from-unix -7 time.add time.to-unix -2 equal
  7 time.from-unix 5 time.from-unix time.diff 2 equal
  5 time.from-unix 7 time.from-unix time.diff -2 equal
  5 time.from-unix 7 time.from-unix time.cmp -1 equal
  7 time.from-unix 5 time.from-unix time.cmp 1 equal
  5 time.from-unix 5 time.from-unix time.cmp 0 equal
  1 time.seconds 1000 equal
  1 time.minutes 60000 equal
  1 time.hours 3600000 equal
  1 time.days 86400000 equal
  -2 time.days -172800000 equal
  0 time.from-unix 1 time.days time.add utc-fields [1970 1 2 0 0 0 0 4] equal
  (9223372036854775807 time.from-unix 1 time.add) 'overflow 'time.add raises-word
  (-9223372036854775808 time.from-unix -1 time.add) 'overflow 'time.add raises-word
  (9223372036854775807 time.from-unix -1 time.from-unix time.diff) 'overflow 'time.diff raises-word
  (9223372036854775807 time.seconds) 'overflow 'time.seconds raises-word
  (-9223372036854775808 time.days) 'overflow 'time.days raises-word
  (1.5 time.seconds) 'type 'time.seconds raises-word
  (5 time.from-unix 1.5 time.add) 'type 'time.add raises-word)
 'arithmetic test

 ### test clock-domains
 (-- : "Keep monotonic instants and Unix timestamps from passing for each other.")
 (5 time.from-unix {'unix 5} equal
  ({'monotonic 5} time.to-unix) 'type 'time.to-unix raises-word
  ({'monotonic 5} time.format) 'type 'time.format raises-word
  ({'monotonic 5} 1 time.add) 'type 'time.add raises-word
  ({'unix 5 'extra 1} time.to-unix) 'type 'time.to-unix raises-word
  ({'unix 1.5} time.to-unix) 'type 'time.to-unix raises-word
  ({"unix" 5} time.to-unix) 'type 'time.to-unix raises-word
  (5 time.to-unix) 'type 'time.to-unix raises-word
  ({} time.to-unix) 'type 'time.to-unix raises-word
  (1.5 time.from-unix) 'type 'time.from-unix raises-word
  {'unix 5} {'monotonic 5} match? 0 equal
  clock.now 'monotonic at type 'int equal
  (clock.now time.format) 'type 'time.format raises-word
  (clock.now time.to-unix) 'type 'time.to-unix raises-word
  ({'unix 5} clock.elapsed) 'type 'clock.elapsed raises-word
  clock.now clock.elapsed 0 >= 1 equal)
 'clock-domains test

 ### test sleeping
 (-- : "Sleep for zero and small durations and reject malformed durations.")
 (0 clock.sleep
  [] (0 clock.sleep 7) @spawn await {'ok [7]} equal
  [] (1 clock.sleep 8) @spawn await {'ok [8]} equal
  (-1 clock.sleep) 'domain 'clock.sleep raises-word
  (1.5 clock.sleep) 'type 'clock.sleep raises-word
  ("soon" clock.sleep) 'type 'clock.sleep raises-word)
 'sleeping test

 ### test wall-clock
 (-- : "Read the wall clock the test command grants as a tagged Unix timestamp.")
 (clock.unix 'unix at type 'int equal
  clock.unix dict.keys ['unix] equal)
 'wall-clock test

 ### test documentation
 (-- : "Require documentation for every clock and time word.")
 (('time.from-unix 'time.to-unix 'time.add 'time.diff 'time.cmp 'time.to-utc
   'time.from-utc 'time.parse 'time.format 'time.seconds 'time.minutes
   'time.hours 'time.days 'clock.now 'clock.elapsed 'clock.unix 'clock.sleep)
  documented)
 'documentation test
) 'stdlib.test.time @defm
