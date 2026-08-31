# Legacy core-language material

This file preserves, verbatim, core-language sections removed from the former
monolithic specification before they were reviewed and incorporated into the
top-down language report. It records no language-design decisions made during
the current specification session and is not assembled into `SPEC.md`.

Its statements retain legacy status until they are individually reviewed,
revised, migrated into the language specification, or retired.

## Errors

Errors are crash-only. There is no try/catch and no handler quotation: an
error propagates until the enclosing unit dies, and the transactional
stack makes that death clean. Failure is observed from outside, as data,
at one explicit boundary word: `@attempt` (and its concurrent form,
`@spawn`/`await`). The REPL is the implicit top-level boundary; a script's
boundary is the process.

Every error is a dict:

| key | value |
|---|---|
| `'kind` | symbol — the dispatch taxonomy |
| `'msg` | string, preformatted |
| `'word` | qualified symbol of the innermost raising word, when known |
| `'trace` | list of qualified word symbols, innermost first — ecl-level only |
| `'data` | kind-specific payload dict (e.g. expected/got shapes, required vs observed effect and element index) |

Source position fields appear when known. Absence is absence: fields not
known are not present (test with `has?`), never nil — there is no nil.
Code assembled at runtime has no source position by construction. No host
exception or host stack frame ever leaks into an error.

A completion-time source-word effect violation reports the opening delimiter
of the deepest reader-built quotation selected by ordinary tail control in
that checked activation. The checked body is the initial location, so a word
with no such selection still points to its body. An empty quotation points to
its opening `(`; it does not need a first token. Non-tail helper calls and
isolated or inline application iterations do not replace this location, so an
element quotation is not mistaken for a source branch and iteration cost does
not acquire provenance allocation or reference-count traffic per element.
This does not hide an application's own contract failure. Within one
application, dynamically applied tail-control quotations replace that
application's location. A guard predicate is disposable observation and does
not replace the enclosing selection; after restoration, the selected `cond`
action or true `while` body replaces it at the preserved boundary, and tail
control inside that action may refine it further. A new iteration starts a
fresh boundary. The error reports the deepest such quotation's opening
delimiter and preserves its element index, falling back to the application
quotation when no dynamic selection occurred. If the selected tail or failing
application quotation was assembled at runtime, all three source fields remain
absent rather than falling back to a less-specific or invented position.

Resolving those source fields is strict O(1) in the number of sources archived
after the selected quotation and in pointer-hash collisions. Diagnostic
materialization uses the selected code header's direct session identity; it
does not scan session history to discover which span table owns the header.
That identity is session-local: the archive also verifies exact header
membership and the archive-owned construction namespace before reading the
indexed entry. Only the archive's opaque issuer can assign an identity to a
header built in that namespace; a generic heap owner supplies no such
authority. Absorption validates all candidate headers before reserving or
assigning identities and rejects a namespace mismatch without consuming its
inputs. Once validation and fallible index-page allocation complete, the
archive adopts the root and source record before exposing any index slot; a
cancelled partial assignment therefore retains stable location storage, and
teardown reports whether the caller or archive owns the artifacts. A quotation
transferred from a different Session therefore has no
source fields when merely looked up in the receiving Session, even when its
numeric identity collides with a local quotation; attempting to publish that
foreign construction into the receiving archive is an invariant error.

The core kinds are a closed set: `'underflow`, `'undefined-word`, `'type`,
`'shape`, `'conform`, `'overflow`, `'domain`, `'contract`, `'parse`,
`'io`, `'cancelled`, `'timeout`, `'user`. User kinds are any other symbol.
`raise` throws a dict; `fail` is sugar for raising
`{'kind 'user 'msg msg}`.

`(q) @attempt` runs a self-contained quotation as a new unit on an isolated
substack and always pushes exactly one result value: `{'ok (values)}`
or `{'err <error dict>}`. Uniform arity is what makes reified failure safe
in a stack language: a failure never shares a stack with the code
observing it. A result is an ordinary dict, so raw `at`/`has?` reach into
it directly; the named vocabulary that validates the envelope first —
`result.ok?`, `result.or-raise`, `result.or-else` and the rest — is the
`result` module (see The standard library). Errors are plain immutable data
and cross task boundaries unchanged.

## Concurrency

Concurrency is structured tasks — futures with enforced lifetime — over
share-nothing units. Immutability makes sharing safe without copying.

- `@spawn` `( unit-input -- task )` runs a quotation, or a plan's body seeded
  by its values (the `@attempt` contract: an unseeded quotation takes its inputs
  via `seed`/`partial`/environment, never the ambient stack), on its own
  isolated substack, concurrently.
- `await` `( task -- result )` parks the current unit until the task
  completes and delivers the same `{'ok …}`/`{'err …}` result shape as
  `@attempt`. It is idempotent — the result is cached — so task handles
  are observationally value-like. **`@attempt` is observationally
  equivalent to `spawn await`.**
- `await-for` adds a deadline in milliseconds: on expiry it returns
  `{'err {'kind 'timeout}}` without cancelling the task. A task that is
  already terminal beats even a zero deadline.
- `await-any` races a nonempty list of tasks, returning the index and
  result of the first to finish; among tasks already terminal at entry,
  the lowest index wins.
- `cancel` makes a task die with `{'err {'kind 'cancelled}}`; it is a
  no-op on a finished task. Cancellation is unconditional and safe because
  tasks are transactions: killing one discards an isolated substack.
- `await-all` (defined as `(await) each`) waits for every task and
  preserves each result as data, in input order; it never re-raises and
  never cancels siblings.
- `@each` `( l q -- l' )` applies the quotation to every element
  concurrently, enforcing exactly one result per element, and returns
  results in input order. After the leftmost failure it cancels the
  remaining elements, waits for quiescence, and re-raises that failure —
  parallel failure is deterministic. Elements are guaranteed no
  cross-element rendezvous: they may run fully serially, so a program
  whose elements must run concurrently to make progress is incorrect.

**Structured lifetime.** A dying unit cancels its unawaited tasks — "a
failed unit leaves nothing" extends to processes. Dropped handles are
cancelled at scope end; there are no detached daemons. The session is the
root scope. `tasks` lists pending descendant tasks in `@spawn` preorder.

**Determinism.** Await order is program order, so `await-all` results and
`@each`'s leftmost-error rule are schedule-invariant. Nondeterminism
enters only where chosen (`await-any`) and in IO interleaving across
concurrent tasks; within one task IO is ordered. Sequential combinators
(`each`, `for`, `fold`) guarantee left-to-right order, so IO inside them
is well-defined.

**Process exit.** `exit` belongs to the root unit outside `@attempt`: a
call from a descendant task or inside `@attempt` raises a catchable
`'domain` error. An allowed exit first cancels and quiesces the root task
scope, then terminates the process with the given status.

## Printing and round-trip

Printing does not expose storage representation. A list prints with `[...]`
when its value has canonical array shape — a homogeneous flat vector, or
rectangular nesting of such lists — and with `(...)` otherwise; both are the
same value kind, and either bracket pair is accepted on input. Thus `(1 2 3)`
prints as `[1 2 3]`, while the ragged result of `[[1 2] [3]] 10 *` prints as
`([10 20] [30])`.

- `str` produces the compact single-line canonical form and carries the
  round-trip guarantee for recursively readable values: reading `str` output
  yields a structurally matching value. Tasks, modules, unit plans, and
  aggregates containing them instead contain diagnostic displays and have no
  read-back guarantee.
- `io.pp` and the REPL stack display are best-effort human layout: the same
  delimiters and atom spellings, with the rows of rectangular matrices
  (and one enclosing group axis) separated by newline-plus-indentation.
  Their output carries no round-trip guarantee. A bracket-form numeric or
  symbol list longer than 256 elements displays as `[<N-values-elided>]`; a
  parenthesized list does so as `(<N-values-elided>)`; and a character list longer
  than 256 elements displays as `"<N-characters-elided>"`. Elision happens
  before matrix-shape scanning or child rendering, keeping ordinary terminal
  probes bounded. Only `str` is canonical and never elides.
- In display layout, a dictionary stays compact when it is a small scalar
  record. A dictionary with more than three pairs, a nested dictionary, or a
  matrix-valued key or value prints one pair per indented line. Nested
  dictionaries apply the same rule recursively. Flat vector fields stay
  compact. Canonical `str` output is always compact and unaffected by this
  display choice.
- `io.stack` uses that same per-value display layout but prints each visible
  stack slot as its own bottom-up indexed block: `[0]` is the bottom of the
  visible operand window and the largest index is its top. Continuation lines
  align after the index prefix. This vertical diagnostic layout is distinct
  from the denser side-by-side REPL display.
- The stack display keeps stack order left to right whatever a value's
  height. Each value occupies the rectangle its own layout needs, and the
  rectangles sit side by side sharing a bottom row, so a matrix grows the
  display upward instead of stacking its neighbours vertically. Padding is
  counted in bytes, matching the column arithmetic of the row breaks above,
  and no row is padded past its last value. The display is not wrapped to
  the terminal: width is a measured fact the display has no access to.
- Dictionaries preserve insertion order in both compact and multiline display.

Printing at unit end: script files and `load` print only explicitly
(`io.pp`/`io.prin`); `-e`, stdin, and calculator invocations print the final
stack; the REPL prints the stack after every unit.
