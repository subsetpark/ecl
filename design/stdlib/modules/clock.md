## clock

Scheduler-backed time. `now`, `elapsed`, and `sleep` read the one monotonic
clock the Session's scheduler owns, so a program's instants, its sleeps, and
every `task.await-for` deadline agree on the current time. `unix` reads the
process realtime clock, which is always available to CLI programs.

Every quantity is a whole number of milliseconds. A monotonic instant is the
one-key dictionary `{monotonic ms}` counting from Session construction; a wall
timestamp is `{unix ms}` counting from 1970-01-01T00:00:00Z. The tag is the
clock domain: an instant handed to a `time` word, or a timestamp handed to
`elapsed`, is `` `type ``. Monotonic instants are not portable across Sessions and
carry no date; wall time may jump and is not suitable for scheduling.

### sleep

#### Examples

```ecl
clock.now `start set 250 clock.sleep start clock.elapsed 250 >=
# => 1
```
