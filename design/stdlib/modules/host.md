## host

### cwd
`( -- path )` — Return the absolute startup directory captured by the Session
host as UTF-8 text. This does not consult `PWD` or change the working directory.

### executable
`( -- path )` — Ask the operating system for the current executable's absolute
path and return UTF-8 text. This does not consult `PATH` or trust the executable
name supplied in the argument vector. Raise `` `io `` when the host cannot provide
the path or it is not UTF-8. This is an observation, not an open-file identity:
subsequent deletion or replacement can make the path unavailable or stale.
Neither metadata operation grants authority beyond the existing filesystem and
process facilities. Text construction is cancellable.
