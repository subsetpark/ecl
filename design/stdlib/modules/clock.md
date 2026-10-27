## clock

Scheduler-backed time. `now`, `elapsed`, and `sleep` read the one monotonic
clock the Session's scheduler owns, so a program's instants, its sleeps, and
every `task.await-for` deadline agree on the current time. `unix` reads the
process realtime clock, which is always available to CLI programs.

Every quantity is a whole number of milliseconds. A monotonic instant is the
one-key dictionary `{'monotonic ms}` counting from Session construction; a wall
timestamp is `{'unix ms}` counting from 1970-01-01T00:00:00Z. The tag is the
clock domain: an instant handed to a `time` word, or a timestamp handed to
`elapsed`, is `'type`. Monotonic instants are not portable across Sessions and
carry no date; wall time may jump and is not suitable for scheduling.


### elapsed
`( instant -- milliseconds )` — Monotonic milliseconds from an instant produced
by `now` to the present. Anything but `{'monotonic int}` is `'type`.

### now
`( -- instant )` — Read the monotonic clock as `{'monotonic ms}`. Successive
reads never decrease. The first read of a fresh Session is close to
`{'monotonic 0}`.

### sleep
`( milliseconds -- )` — Park the calling unit until the monotonic clock has
advanced by a nonnegative int duration, then continue with nothing pushed. The
unit holds no worker while parked; runnable work proceeds on a one-worker pool.
The deadline is captured once, before any timer state is created, and a
duration of `0` is already expired at that point: the unit yields to the
scheduler and resumes on its next turn without starting the timer thread.
Cancellation before or after registration wakes the unit with `'cancelled`
and retires its timer entry. A negative duration is `'domain`, a non-int is
`'type`, and a duration whose deadline lies beyond any instant the clock can
report is `'overflow`; all three fail before anything is registered.

#### Examples

```ecl
clock.now 'start set 250 clock.sleep start clock.elapsed 250 >=
# => 1
```

### unix
`( -- timestamp )` — Read the process realtime clock as `{'unix ms}`.
Convert with the `time` module. Wall time can jump and must not be used for
scheduling deadlines.
