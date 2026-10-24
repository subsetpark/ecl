### module time
# Pure UTC time over tagged Unix millisecond timestamps. A timestamp is the
# one-key dictionary {'unix ms}; a monotonic instant from clock.now is
# {'monotonic ms}, and each word accepts only its own domain. Nothing here
# reads a clock.
#
# Every failure is raised against the public word the program called, so a
# checked kernel overflow inside the arithmetic is reported as this module's
# own 'overflow. Calendar arithmetic follows Hinnant's days-from-civil
# algorithm without wider intermediates: 146097 days is a whole number of
# weeks, so the weekday never needs the era, and a negative day count is
# scaled from its successor so the full int millisecond range stays reachable.
[]
(
 ### defp fail
 (kind message word -- : "Raise an error attributed to a public time word.")
 (|kind message word| 'kind kind 'msg message 'word word 6 pack dict.from-flat raise) 'fail defp

 ### defp type-error
 (word expected -- : "Raise a type error naming the public word and what it expected.")
 (|word expected| 'type word chars " expected " cat expected cat word fail) 'type-error defp

 ### defp int-arg
 (value word expected -- value : "Return an int argument or raise a type error naming the word.")
 (rolldown dup type 'int match? (nip nip) (pop type-error) if) 'int-arg defp

 ### defp unix?
 (value -- bool : "Return 1 when a value is exactly a {'unix milliseconds} timestamp.")
 (dup type 'dict match?
  (dup dict.size 1 = (dup 'unix dict.has? (dup 'unix at type 'int match?) (0) if) (0) if nip)
  (pop 0)
  if) 'unix? defp

 ### defp millis
 (timestamp word -- milliseconds : "Unwrap a timestamp or raise a type error naming the word.")
 (swap dup unix? (nip 'unix at) (pop "a {'unix milliseconds} timestamp" type-error) if) 'millis defp

 ### defp tag
 (milliseconds -- timestamp : "Tag an int millisecond count as a Unix timestamp.")
 ('unix swap 2 pack dict.from-flat) 'tag defp

 ### defp checked
 (values quotation word -- result :
  "Run integer arithmetic on seed values, reporting overflow against a public word.")
 (|values quotation word|
  word
  word chars " left the millisecond range" cat
  values quotation @attempt
  dup 'ok dict.has?
  ('ok at first nip nip)
  ('err at dup 'kind at 'overflow match? (pop swap 'overflow rollup fail) (nip nip raise) if)
  if) 'checked defp

 ### defp fdiv
 (dividend divisor -- quotient : "Divide by a positive divisor, rounding toward negative infinity.")
 (over over mod 0 < (div 1 -) (div) if) 'fdiv defp

 ### defp fmod
 (dividend divisor -- remainder : "Return the nonnegative remainder by a positive divisor.")
 (dup (mod) dip over 0 < (+) (pop) if) 'fmod defp

 ### defp leap?
 (year -- bool : "Apply the proleptic Gregorian leap-year rule.")
 (|year| year 4 mod 0 = year 100 mod 0 = not year 400 mod 0 = or and) 'leap? defp

 ### defp days-in-month
 (year month -- count : "Return the length of a valid month in a given year.")
 (|year month| [31 28 31 30 31 30 31 31 30 31 30 31] month 1 - at month 2 = year leap? and +)
 'days-in-month defp

 ### defp digit?
 (char -- bool : "Return 1 for an ASCII decimal digit.")
 (dup \0 >= swap \9 <= and) 'digit? defp

 ### defp era-parts
 (year month day -- era day-of-era :
  "Split a valid civil date into its 400-year era and the day within that era.")
 (|year month day|
  year 400 fdiv
  year 400 fmod
  month 2 <= (dup 0 = (pop 399 swap 1 - swap) (1 -) if) when
  month dup 2 > (3 -) (9 +) if 153 * 2 + 5 div day + 1 -
  swap dup 365 * over 4 div + swap 100 div - +) 'era-parts defp

 ### defp day-milliseconds
 (days since-midnight -- milliseconds :
  "Combine a day count and a time of day without leaving the int range early.")
 (|days since-midnight|
  days 0 <
  days over + 86400000 *
  swap 86400000 * since-midnight swap - +) 'day-milliseconds defp

 ### defp civil-date
 (era day-of-era -- year month day : "Decompose a day within an era into a civil date.")
 (|era day-of-era|
  day-of-era
  day-of-era 1460 div -
  day-of-era 36524 div +
  day-of-era 146096 div -
  365 div
  dup 365 * over 4 div + over 100 div - day-of-era swap -
  dup 5 * 2 + 153 div
  dup 153 * 2 + 5 div rolldown swap - 1 +
  swap dup 10 < (3 +) (9 -) if
  rolldown over 2 <= era 400 * + +
  rollup swap) 'civil-date defp

 ### defp civil-from-days
 (days -- year month day : "Decompose a day count since 1970-01-01 into a civil date.")
 (719468 + dup 146097 fdiv swap over 146097 * - civil-date) 'civil-from-days defp

 ### defp clock-fields
 (since-midnight -- hour minute second millisecond : "Split milliseconds since midnight.")
 (|since-midnight|
  since-midnight 3600000 div
  since-midnight 3600000 mod 60000 div
  since-midnight 60000 mod 1000 div
  since-midnight 1000 mod) 'clock-fields defp

 ### defp civil
 (milliseconds -- year month day hour minute second millisecond weekday :
  "Decompose a Unix millisecond count into UTC calendar fields; weekday counts from Monday as 0.")
 (|milliseconds|
  milliseconds 86400000 fdiv civil-from-days
  milliseconds 86400000 fmod clock-fields
  milliseconds 86400000 fdiv 3 + 7 fmod) 'civil defp

 ### defp pad0
 (number width -- string :
  "Render a nonnegative int with leading zeros to a width of at most four.")
 (|number width| "0000" number str cat width neg take) 'pad0 defp

 ### defp render
 (year month day hour minute second millisecond -- string : "Render RFC 3339 UTC text.")
 (|year month day hour minute second millisecond|
  year 0 < year 9999 > or
  ('domain "time.format requires a year from 0000 through 9999" 'time.format fail)
  when
  year 4 pad0 "-" cat month 2 pad0 cat "-" cat day 2 pad0 cat
  "T" cat hour 2 pad0 cat ":" cat minute 2 pad0 cat ":" cat second 2 pad0 cat
  "." cat millisecond 3 pad0 cat "Z" cat) 'render defp

 ### defp utc-fields
 (year month day hour minute second millisecond weekday -- fields : "Build the to-utc dictionary.")
 (|year month day hour minute second millisecond weekday|
  'year year 'month month 'day day 'hour hour 'minute minute 'second second
  'millisecond millisecond 'weekday weekday 16 pack dict.from-flat) 'utc-fields defp

 ### defp time-of-day
 (hour minute second millisecond -- milliseconds : "Combine validated clock fields.")
 (|hour minute second millisecond|
  hour 3600000 * minute 60000 * + second 1000 * + millisecond +) 'time-of-day defp

 ### defp field-names
 (-- names : "Return the accepted calendar field names.")
 (['year 'month 'day 'hour 'minute 'second 'millisecond 'weekday]) 'field-names defp

 ### defp check-field
 (pair -- : "Validate one calendar field entry for from-utc.")
 (dup first
  dup type 'symbol match? not ('time.from-utc "symbol field names" type-error) when
  field-names in? not
  ('domain
   "time.from-utc accepts only year, month, day, hour, minute, second, millisecond, and weekday fields"
   'time.from-utc fail)
  when
  1 at type 'int match? not ('time.from-utc "integer calendar fields" type-error) when)
 'check-field defp

 ### defp from-utc-fail
 (message -- : "Raise a domain error against from-utc.")
 ('domain swap 'time.from-utc fail) 'from-utc-fail defp

 ### defp civil-instant
 (year month day hour minute second millisecond weekday? weekday -- timestamp :
  "Validate decoded from-utc fields and build their timestamp.")
 (|year month day hour minute second millisecond weekday? weekday|
  month 1 < month 12 > or ("time.from-utc month must be 1 through 12" from-utc-fail) when
  day 1 < day year month days-in-month > or ("time.from-utc day is outside its month" from-utc-fail)
  when
  hour 0 < hour 23 > or ("time.from-utc hour must be 0 through 23" from-utc-fail) when
  minute 0 < minute 59 > or ("time.from-utc minute must be 0 through 59" from-utc-fail) when
  second 0 < second 59 > or
  ("time.from-utc second must be 0 through 59; leap seconds are not representable" from-utc-fail)
  when
  millisecond 0 < millisecond 999 > or
  ("time.from-utc millisecond must be 0 through 999" from-utc-fail)
  when
  year month day era-parts
  dup 719465 - 7 fmod weekday <> weekday? and
  ("time.from-utc weekday disagrees with the date" from-utc-fail)
  when
  hour minute second millisecond time-of-day 3 pack
  (|era day-of-era since-midnight| era 146097 * day-of-era + 719468 - since-midnight
   day-milliseconds)
  'time.from-utc checked tag) 'civil-instant defp

 ### defp malformed
 (-- : "Raise the RFC 3339 grammar error.")
 ('parse "time.parse expected an RFC 3339 date-time such as 1970-01-01T00:00:00Z" 'time.parse fail)
 'malformed defp

 ### defp out-of-range
 (-- : "Raise the RFC 3339 field range error.")
 ('domain "time.parse found a calendar field outside its range" 'time.parse fail) 'out-of-range defp

 ### defp text?
 (value -- bool : "Return 1 when a value is a string.")
 (dup type 'list match? ((type 'char match?) all?) (pop 0) if) 'text? defp

 ### defp shaped?
 (char pattern -- bool :
  "Match one character against a d (digit), T (date-time separator), or literal.")
 (|char pattern|
  pattern \d match? char digit? and
  pattern \T match? char \T match? char \t match? or and
  or
  pattern \d match? pattern \T match? or not char pattern match? and
  or) 'shaped? defp

 ### defp shaped
 (text pattern -- : "Require text of the pattern's length to match it character by character.")
 ((shaped?) zip-with (1 =) all? not (malformed) when) 'shaped defp

 ### defp fraction-digits
 (digits -- millisecond rest : "Read a fraction's digits, keeping the first three.")
 (|digits|
  digits (digit? not) each first-where
  dup 0 = (malformed) when
  digits over 3 min take "000" cat 3 take int
  swap digits swap drop) 'fraction-digits defp

 ### defp fraction
 (rest -- millisecond rest : "Read an optional fraction after the seconds.")
 (dup len 0 = (0 swap) (dup first \. match? (1 drop fraction-digits) (0 swap) if) if) 'fraction defp

 ### defp offset
 (rest -- milliseconds : "Read a numeric offset that ends the text.")
 (|rest|
  rest first \+ match? rest first \- match? or not (malformed) when
  rest len 6 < (malformed) when
  rest 1 drop 5 take "dd:dd" shaped
  rest 1 drop 2 take int
  rest 4 drop 2 take int
  over 23 > over 59 > or (out-of-range) when
  swap 3600000 * swap 60000 * +
  rest len 6 > (malformed) when
  rest first \- match? (neg) when) 'offset defp

 ### defp zone
 (rest -- milliseconds : "Read the UTC designator or numeric offset that ends the text.")
 (dup len 0 = (malformed) when
  dup first dup \Z match? swap \z match? or
  (len 1 = not (malformed) when 0)
  (offset)
  if) 'zone defp

 ### defp parsed-instant
 (millisecond offset year month day hour minute second -- timestamp :
  "Validate parsed RFC 3339 fields and convert them to UTC.")
 (|millisecond offset year month day hour minute second|
  month 1 < month 12 > or (out-of-range) when
  day 1 < day year month days-in-month > or (out-of-range) when
  hour 23 > minute 59 > or second 59 > or (out-of-range) when
  year month day era-parts swap 146097 * + 719468 -
  hour minute second millisecond time-of-day day-milliseconds
  offset - tag) 'parsed-instant defp

 ### def from-unix
 (milliseconds -- timestamp : "Tag an integer Unix millisecond count as {'unix milliseconds}.")
 ('time.from-unix "an integer Unix millisecond count" int-arg tag) 'from-unix def

 ### def to-unix
 (timestamp -- milliseconds : "Return the Unix millisecond count inside a timestamp.")
 ('time.to-unix millis) 'to-unix def

 ### def add
 (timestamp milliseconds -- timestamp : "Shift a timestamp by a signed millisecond duration.")
 (|timestamp duration|
  duration 'time.add "a timestamp followed by integer milliseconds" int-arg
  timestamp 'time.add millis swap 2 pack (+) 'time.add checked tag) 'add def

 ### def diff
 (later earlier -- milliseconds : "Return later minus earlier in milliseconds.")
 (|later earlier|
  earlier 'time.diff millis
  later 'time.diff millis swap 2 pack (-) 'time.diff checked) 'diff def

 ### def cmp
 (left right -- ordering : "Three-way compare two timestamps as -1, 0, or 1.")
 (|left right| right 'time.cmp millis left 'time.cmp millis swap core.cmp) 'cmp def

 ### def seconds
 (n -- milliseconds : "Convert whole seconds to milliseconds.")
 ('time.seconds "an integer count" int-arg 1000 2 pack (*) 'time.seconds checked) 'seconds def

 ### def minutes
 (n -- milliseconds : "Convert whole minutes to milliseconds.")
 ('time.minutes "an integer count" int-arg 60000 2 pack (*) 'time.minutes checked) 'minutes def

 ### def hours
 (n -- milliseconds : "Convert whole hours to milliseconds.")
 ('time.hours "an integer count" int-arg 3600000 2 pack (*) 'time.hours checked) 'hours def

 ### def days
 (n -- milliseconds : "Convert whole days of 86,400 seconds to milliseconds.")
 ('time.days "an integer count" int-arg 86400000 2 pack (*) 'time.days checked) 'days def

 ### def to-utc
 (timestamp -- fields : "Decompose a timestamp into UTC calendar fields.")
 ('time.to-utc millis civil utc-fields) 'to-utc def

 ### def from-utc
 (fields -- timestamp : "Build a timestamp from UTC calendar fields.")
 (|fields|
  fields type 'dict match? not ('time.from-utc "a dictionary of UTC calendar fields" type-error)
  when
  fields dict.pairs (check-field) for
  fields 'year dict.has? fields 'month dict.has? and fields 'day dict.has? and not
  ("time.from-utc requires year, month, and day" from-utc-fail)
  when
  fields 'year at
  fields 'month at
  fields 'day at
  fields 'hour 0 at-or
  fields 'minute 0 at-or
  fields 'second 0 at-or
  fields 'millisecond 0 at-or
  fields 'weekday dict.has?
  fields 'weekday 0 at-or
  civil-instant) 'from-utc def

 ### def format
 (timestamp -- string : "Render a timestamp as YYYY-MM-DDTHH:MM:SS.mmmZ.")
 ('time.format millis civil pop render) 'format def

 ### def parse
 (text -- timestamp : "Parse an RFC 3339 date-time, converting any offset to UTC.")
 (|text|
  text text? not ('time.parse "a string" type-error) when
  text len 35 > (malformed) when
  text (int 127 >) each (1 =) any? (malformed) when
  text len 19 < (malformed) when
  text 19 take "dddd-dd-ddTdd:dd:dd" shaped
  text 19 drop fraction zone
  text 4 take int
  text 5 drop 2 take int
  text 8 drop 2 take int
  text 11 drop 2 take int
  text 14 drop 2 take int
  text 17 drop 2 take int
  parsed-instant) 'parse def
) 'time @defm
