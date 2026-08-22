# Archive fixtures

Each `*.tgz.hex` file is an ASCII hexadecimal encoding of the exact bytes
passed to `archive.unpack-tgz`. Keeping the corpus textual makes malicious tar
headers reviewable and stable in source control.

`empty.tgz.hex` contains no members, `valid.tgz.hex` contains a directory and
two regular files, and the PAX and GNU fixtures encode the same long regular
file name through their respective extensions. The remaining fixtures isolate
absolute and parent-traversing paths, symbolic and hard links, character and
block devices, a FIFO, a duplicate path, a member declaring more than the 1
GiB extraction limit, and malformed gzip, tar-header, and PAX-record input.

Regenerate the corpus deterministically with:

```sh
timeout 30 python3 test/fixtures/archive/generate.py < /dev/null
```
