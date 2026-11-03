## proc

#### Spawn specification

| Field | Value | Required / default |
| --- | --- | --- |
| `` `executable `` | Absolute executable path string; no `PATH` lookup | Required |
| `` `args `` | List of argument strings, excluding the executable name | `[]` |
| `` `cwd `` | Absolute directory path string without `.` or `..` components | Startup working directory |
| `` `env `` | String-to-string dictionary, for example `{"LANG" "C"}` | `{}`; the child's complete environment |

#### Examples

On a POSIX host with `/bin/cat`, capture a byte-exact round trip:

```ecl
{executable "/bin/cat" stdin [104 101 108 108 111 10]} proc.run
# {term {kind exited code 0} stdout [104 101 108 108 111 10] stderr []}
```

A fuller specification adds arguments, a working directory, and environment:

```ecl
{executable "/bin/echo"
 `args ["hello world"]
 `cwd "/tmp"
 `env {"LANG" "C"}
 `stdout-limit 4096
 `stderr-limit 4096
 `timeout-ms 1000} proc.run
`stdout at chars
# "hello world\n"
```

These examples require the named executables and directory to exist, and the
host to permit the requested paths and capture bounds. Use `bytes` to encode
text for stdin and `chars` to decode complete UTF-8 output. Arbitrary process
output may not be valid UTF-8.
