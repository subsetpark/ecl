### module io
(: "Text over byte streams. Every word here that touches a stream encodes or decodes UTF-8 at that
    boundary, through `bytes` and `chars`; the console conveniences are the same words applied to
    `stream.out` and `stream.err`.")
(
 `io.core [pp prin print eprint inspect debug stack] import

 ### def read
 (stream -- string : "Read a byte endpoint to EOF and decode it as UTF-8.")
 (stream.read-all chars) `read def

 ### def read-line
 (stream -- string : "Read one line of UTF-8 text through its newline, newline included.")
 (stream.read-line chars) `read-line def

 ### def lines
 (stream -- strings : "Read a byte endpoint to EOF and split the decoded text at every newline.")
 (read "\n" str.split dup empty? (dup last "" match? (-1 drop) when) unless) `lines def

 ### def write
 (stream chardata -- :
  "Encode string or list of strings `chardata` as UTF-8 and write it to a byte endpoint.")
 (dup empty? (bytes) (dup first type `list match? ((bytes) each raze) (bytes) if) if stream.write)
 `write def

 ### def write-line
 (stream string -- : "Encode `string` as UTF-8 and write it followed by a newline.")
 ("\n" cat write) `write-line def

 ### def stdin
 (-- string : "Read all of stdin as text.")
 (stream.in read) `stdin def
) `io @defm
