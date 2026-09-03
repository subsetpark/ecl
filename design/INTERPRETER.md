# ecl — interpreter architecture

This document follows an ecl program from source bytes to observable results
and explains why the interpreter's major boundaries have the shapes they do.

The [language specification](SPEC.md) defines observable language behavior.
The [standard-library reference](STDLIB.md) defines the shipped vocabulary, and
the [environment guide](ENVIRONMENT.md) defines modules, packages, host data,
and command-line behavior. Those documents are authoritative when an
implementation choice and a public contract appear to conflict. Recorded
performance measurements belong in [PERFORMANCE.md](PERFORMANCE.md).

The interpreter executes the same quotation values that ecl programs
manipulate as data. Quotations are its sole executable representation; there is
no bytecode, native-code, or JIT-compiled tier. The rest of the architecture
makes that model safe under late binding, array specialization, concurrency,
cancellation, and live module replacement.

## The system at a glance

A host creates a `Session`, then submits source a unit at a time. The path
through the implementation is:

```text
source bytes
    │
    ▼
UTF-8 lexer and resumable reader
    │  executable quotation values + source provenance
    ▼
frame machine ───────► environment and module resolution
    │
    ├───────────────► primitives and guarded idioms
    │                         │
    │                         ▼
    │                 typed array kernels
    │
    └───────────────► bounded work drivers and task scheduler
                              │
                              ▼
                    values, errors, and explicit I/O
                              │
                              ▼
                    printer and console boundary
```

Each box is a cooperating runtime boundary. Reading creates ordinary runtime
values; resolution occurs when a word executes; a primitive may install a
resumable driver; and a driver may yield to the scheduler many times before
producing a value. The `Session` owns every component for the whole journey.

The main components are these:

| Component | Responsibility | Primary implementation |
| --- | --- | --- |
| Session | Lifetime root, persistent operand stack, host services, and unit transaction | `session.zig` |
| Reader and source archive | Turn source into executable values while retaining optional diagnostic lineage | `lexer.zig`, `reader_*.zig`, `binder.zig`, `spans.zig` |
| Value heap | Values, specialized list storage, dictionaries, ownership, and reclamation | `value.zig`, `heap.zig`, `list.zig`, `dict.zig`, `intern.zig` |
| Names and modules | Late binding, scopes, immutable module images, generations, and durable module state | `env.zig`, `modules.zig` |
| Frame machine | Dispatch quotations, represent continuations, enforce application boundaries, and construct errors | `machine.zig` |
| Bulk execution | Pervasive scalar semantics, typed flat loops, and guarded source-phrase recognition | `kernel_*.zig`, `kernels.zig`, `idioms.zig` |
| Scheduler | Green units, structured task scopes, task and external waits, cancellation, timers, external membership, and retirement service | `scheduler_core.zig`, `scheduler.zig`, `external.zig`, `task_prims.zig` |
| Process ports | Process policy, POSIX process-group ownership, bounded pipe queues, and terminal publication | `process_port.zig`, `stdlib/proc.zig` |
| Network listeners and connections | Listen policy, exact grant matching over normalized IP literals, scope-owned listening sockets, demand-gated accept, bounded connection queues serviced by controller threads, and idempotent close | `net_port.zig`, `stdlib/net.zig` |
| Boundary layers | Embedded modules, native extensions, rendering, terminal safety, the REPL, and the CLI | `prelude.zig`, `stdlib.zig`, `native_*.zig`, `print.zig`, `console.zig`, `line_editor.zig`, `main.zig` |

### Position in the design space

ecl combines several familiar techniques into an interpreter for reflective,
concatenative array programs.

| Concern | ecl's choice | Relationship to prior art |
| --- | --- | --- |
| Program representation | Quotations remain ordinary lists; there is no retained AST or bytecode | Extends Joy's program-as-quotation model; conventional AST and bytecode pipelines mark the neighboring design space |
| Evaluation | One first-order loop over explicit tagged frames | A defunctionalized abstract machine, closest in spirit to CEK-style evaluators, adapted to a concatenative operand stack |
| Binding | Each reader-created word occurrence carries one scope identity | Uses the placement principle of scope-carrying identifiers, scaled to one parent-chain scope because ecl has no macro-expansion scope sets |
| Data performance | Recursive semantic pervasion with specialized flat leaves and typed kernels | Applies the APL/J/K array instinct while preserving one semantics across physical representations |
| Memory | Precise atomic reference counts, ownership passing, copy-on-write, and uniqueness reuse | Shares the reuse insight of precise-RC systems such as Perceus; structural acyclicity keeps precise counting sufficient |
| Fast phrases | Guarded recognition of a closed set of source phrases | Shares the dispatch economics of interpreter superinstructions; each recognition is ephemeral and the source definition remains authoritative |
| Concurrency | Green units in a structured task tree, serviced cooperatively or by a fixed worker pool | Gives tasks the nested lifetimes of structured concurrency |
| Live publication | Immutable snapshots, generation pins, and deferred reclamation | Combines the removal/reclamation separation of RCU with Erlang-like coexistence of old and current module code |
| Authority | Opaque owners and narrow operation-specific capabilities | Uses object-capability attenuation inside a trusted native process whose extensions remain part of the memory-safety boundary |

The design has one performance thesis: keep dispatch unsurprising and amortize
it over substantial operations on flat data. A change to code representation or
dispatch revises that thesis. Performance work normally belongs in
representations, kernels, and bounded drivers, with release-mode evidence
recorded in `PERFORMANCE.md`.

## 1. The Session is the runtime boundary

`Session` is the public interpreter object and the root of every runtime
lifetime. It is an opaque, movable handle to heap-stable `SessionCore` state.
That state owns:

- the host allocator and `ReleaseDomain`;
- the core and session environments;
- the module registry and native-module owner;
- the persistent operand stack;
- the source-span archive;
- the scheduler and root task scope; and
- immutable or explicitly synchronized views of host services such as
  arguments, environment variables, standard input, output, diagnostics, TLS
  trust, project configuration, module search paths, and optional process,
  filesystem, and package-store authority.

Grouping these objects under one owner correlates every dependent lifetime.
Values, module pins, source cursors, task cells, and deferred destruction all
lead back to the same allocation and reclamation root. Callers receive that
pairing as one fact, while worker code receives a narrower authority that can
advance bounded reclamation and cannot drain or destroy the root.

### Units are transactions on the persistent stack

`Session.runUnit` evaluates one source unit. The Session checkpoints its
operand stack, moves that stack into a root `Unit`, and gives the Unit a root
scope plus inherited service capabilities. On success, the Unit's resulting
stack becomes the Session's next persistent stack. A parse error, language
error, or allocation failure restores the checkpoint.

The transaction covers the operand stack. Output already written, native side
effects, filesystem changes, and other host effects remain committed. The
evaluator restores the values it owns and leaves effects owned by other systems
to those systems.

The same unit abstraction supports calculator input, script execution,
applications launched by combinators, and spawned tasks. Constructors make the
starting stack explicit: empty, one borrowed element, explicit seeds, or an
element followed by seeds. User-sized seeding is itself bounded work rather
than hidden inside construction.

### Host state is captured or capability-gated

A Session captures the host environment once, records whether standard input
remains available as data, and owns any TLS or path overrides needed by its
Units. This gives one Session a coherent view even when the embedding process
changes around it.

Host operations are exposed to executing code through narrow facades. A Unit
may enqueue work, write through the console, load through the module loader, or
use immutable host configuration. It cannot reach the raw Session, allocator,
registry, scheduler lifecycle, or reclamation root. Observation, execution,
mutation, and teardown are distinct authorities.

Process execution follows the same rule. A Host may omit it, allow an exact
set of absolute executables, or grant an explicit unrestricted policy together
with cwd, environment, live-count, queue, and capture limits. Session
construction copies that policy and mints one narrow `ProcessAccess`; having
`std.Io` or filesystem access does not imply it. Units may ask Machine to
perform a process operation, but cannot obtain the owner, scheduler scope,
process cell, group identifier, or PID.

Filesystem access is the same shape. A Host may name root directories, each
with a permission set (`read-data`, `inspect`, `list`, `create`, `replace`,
`rename`, `remove`) and shared limits; construction validates the policy,
opens every root once, and fails with `InvalidHostPolicy` rather than
`OutOfMemory` when a root is relative, missing, not a directory, misnamed, or
duplicated, or when a limit is zero. From then on authority is the retained
directory handle, not the configured path: renaming the directory afterward
moves nothing. The `FilesystemOwner` owns the copied policy, the handles, and
the live-operation quota; Units receive one opaque `FilesystemAccess` and can
only ask the owner to look a symbol up, check a grant, or reserve a slot. No
evaluated word can mint, widen, duplicate, serialize, or inspect a root, and a
Session without a policy denies every `fs` word before reaching the host.
Module loading through `load` and `ECL_PATH` remains a separate host facility
and grants no caller-selected file access.

Clocks are two more authorities with different shapes. The scheduler owns
monotonic time as one `MonotonicClock` tagged union, selected at construction
from the Host's `ClockPolicy`: the `host` variant carries the Session's origin
instant and reads the process awake clock; the `manual` variant is an opaque
`ManualClock` whose reading is whole milliseconds and whose only mutation is a
compare-exchange advance with checked addition, refusing a step that would
leave the range without touching the stored value. It moves through
`Scheduler.advanceManualClock`, a method on the host-root handle that the
`WorkerScheduler` facade does not expose, so no evaluated word can move time.
Every deadline capture, arbitration check, timer wake, and `clock.now` sample
reads `WorkerScheduler.now`, so the whole Session agrees on one "now". The wall clock is a separate
`machine.WallClock` union on the inherited context — `absent`, `host` with the
I/O it reads through, `fixed`, or `anchored` to the monotonic clock — converted
from the Host policy at construction. Neither host I/O nor the TLS verification
timestamp is consulted for it, and the default is `absent`.

Package commands add a third authority. `initPackageCommand` is the only
constructor that mints a `PackageOwner`, and it takes one tagged
`PackageGrant` naming exactly the stores a command shape may touch (`inspect`,
`collect`, `verify`, `synchronize`, `vendor`). The shared cache is an
absolute host path the command line resolved once at startup, a relative
`ECL_CACHE` included; the vendor store has no path at all and is only ever the
fixed child `vendor` of the retained project handle, opened without following
a final symlink, so a repository-controlled link cannot become a store.
`pkg.store` words receive the opaque `PackageAccess`, name a store by symbol,
and address entries only by validated canonical store keys. Ordinary and
embedded Sessions never construct it, so their package-store words fail
closed, and no absolute store path is ever passed through evaluated code.
Cache selection from `ECL_CACHE`, `XDG_CACHE_HOME`, and `HOME` is host
startup work shared with runtime module loading.

### Shutdown follows the ownership graph

Session teardown first stops execution and closes task and external-resource
creation. It then retires root scopes, including cancellation and direct-child
reap for every process member, before destroying the process, filesystem, and
package owners; every filesystem driver is retired with the scheduler, so no
handle, staging entry, or quota reservation can still reference an owner when
its root handles close. Stacks, module generations, source provenance, and
native pins follow in dependency order, with bounded retirement drained while
the owners needed by that work are still alive. The allocator is destroyed
last.

That order is an architectural invariant. A pin, cursor, lease, callback, or
task that releases through a domain cannot outlive the domain. Teardown must
close new lifetime creation, settle every descendant, and only then destroy the
authority that issued those lifetimes.

## 2. Source becomes executable data

Most interpreters lex text, build an AST, compile another representation, and
execute that result. ecl stops earlier. Its reader produces `Value`s, and a
list of those values is already executable code.

### Lexing and reading are resumable

`lexer.zig` owns UTF-8 cursor movement, spans, token classification, and lexical
diagnostics. `reader_cursor.zig` validates UTF-8, tokenizes the unit, recognizes
delimited lists and dictionaries, interns symbols and words, and materializes
the resulting values. Every stage is an explicit cursor. A heap work stack
carries nested source independently of the Zig call stack, and a scheduler
caller may advance the reader a bounded amount at a time.

Synchronous hosts call a blocking facade that drives the same reader
continuation to completion. CLI, scheduler, and test entry points therefore
share one parser semantics.

The reader distinguishes three outcomes:

- a complete root quotation;
- an incomplete unit, used by the REPL to request more physical lines; or
- a parse diagnostic.

Lexical state belongs to the reader. `PendingUnit` carries accumulated bytes
and the tokenizer state derived from exactly those bytes. The line editor asks
that state whether a unit is complete and stays independent of quote, string,
character, and comment recognition.

### Quotations are the executable representation

The root program and every quotation are lists. Evaluation has three cases:

- a non-word value is appended to the operand stack;
- a word occurrence is resolved and invoked; and
- applying a quotation evaluates its elements by the same rule.

Program construction produces ordinary values and never triggers compilation.
Concatenating quotations produces another ordinary list that can execute
immediately. This preserves the language's reflective center and avoids
invalidation machinery for generated code, while word resolution and tag
dispatch remain execution costs. Conventional bytecode VMs, including Lua's
register VM, spend representation complexity to reduce those costs and expose
an optimization target. ecl concentrates its optimization budget on the array
operations that dominate useful data work.

### Binder syntax lowers once, at read time

Head binders are the one general source lowering. `binder.zig` validates
local names and rewrites local loads into private core operations over a
Unit-owned locals stack. A local may not cross into a nested quotation; source
must use explicit quotation construction such as `partial` when it wants value
capture.

The lowering produces ordinary forms consumed directly by the frame machine.
This keeps the machine point-free and local lifetime visible: the lowered
prefix moves inputs into locals, indexed reads retrieve them, and a final
operation drops the region. The reader preserves source spans for the produced
forms, keeping diagnostics anchored to the user's source.

### Source metadata lives on a separate code plane

Executable values do not carry file names, line numbers, or slices of source.
`spans.zig` owns a Session-local source archive keyed by identities assigned to
reader-built list headers. The archive retains:

- source buffers and source names;
- element and container spans;
- source slices used by reflection; and
- reader lineage used when module construction re-scopes source code.

The distinction is load-bearing. Value equality and hashing ignore provenance.
Runtime-built or copy-on-write-rebuilt quotations naturally have no source
entry, so their errors omit position and preserve the precision of the
available evidence.
Moving or destroying a value cannot leave a raw source pointer behind. Source
slices retain their backing allocation, while cursors over independently
published module and environment storage carry the corresponding leases or
generation pins.

Only the archive that read a code object may assign or interpret its code
identity. Absorption validates a complete reader result before publication,
then transfers the root, spans, and source into archive ownership. This makes
failure and cancellation ownership explicit on both sides of the commit.

### Formatting is a separate source path

`formatter.zig` builds a formatter-only CST that retains comments, trivia, and
delimiters, then lowers it to a Wadler/Oppen-style document and renders that
document iteratively. The ordinary reader validates the source, and the
formatter discards that executable result without scheduling it. The dedicated
CST gives formatting a lossless source-preservation mechanism while runtime
provenance stays focused on diagnostics.

## 3. Values and storage

The evaluator moves one closed `Value` union. The layout is fixed at 16 bytes:
integers, floats, Unicode scalars, symbols, and word references are inline;
lists, dictionaries, tasks, module values, and ports carry kind-specific
opaque handles. External code inspects handles through their public semantic surfaces.
Allocation and mutation require capabilities issued by `heap.zig`.
The precommit source audit compares this closed Zig tag universe exactly with
the `ValueType` declarations in `design/formal/values.pant`; a kind added to
either side without the other is rejected before the generated specification
can drift.

### Lists have semantic unity and physical specialization

A list is represented either as a generic spine of boxed `Value`s or as a flat
leaf of one element representation:

- bytes and integers;
- floats;
- one-, two-, or four-byte Unicode scalars; or
- interned symbol identifiers.

Ordinary value-list construction profiles elements and selects the narrowest
valid form; code roots and tooling may explicitly request a generic spine.
Strings are character leaves, so ASCII text occupies one byte per scalar while
indexing remains constant time. A byte leaf is also the compact representation
of an ordinary integer list whose elements fit `0...255`; widening is automatic
when a mutation no longer fits.

The representation tag is a construction fact. Semantic operations switch
exhaustively over the closed representation set, so every operation handles
representation directly. ECL code has no raw leaf-memory or generic mutable
payload capability. Host code that needs binary bytes receives a retaining read
capability whose lifetime keeps the list alive.

The arrangement follows the array-language instinct that homogeneous data
deserves homogeneous storage, while retaining the concatenative rule that any
list may also be a quotation. Generic spines are the universal fallback; flat
leaves optimize storage and execution through the same evaluator.

### Dictionaries preserve insertion and ignore it for identity

`dict.zig` stores parallel key, value, and cached-hash vectors. Iteration keeps
insertion order. Equality and hashing treat a dictionary as an unordered
mapping, so the dictionary hash combines entry hashes commutatively. Small
dictionaries use linear search; larger ones add an index without changing the
ordered vectors.

Numeric hashing agrees with numeric equality, including mixed integer/float
comparisons. Dictionary construction is resumable because hashing, duplicate
detection, and materialization can all depend on user-sized input.

### Symbols are process-lifetime names

Symbols and words share one append-only intern table and distinct value tags.
Interned IDs are an in-process representation only: persistence and the native
ABI carry spelling bytes and intern them in the receiving process.

The table makes reads cheap and lets word occurrences fit in one value cell.
It lives for the process lifetime and is shared by every Session, so a spelling
interned anywhere stays interned everywhere and exhausting the table starves
every reader in the process. Growth is therefore a language-level invariant
rather than a limitation to document: the table grows only through reading
source (including `parse`), the module loaders, and the one word whose purpose
is to grow it, `intern`. Every other path from data to a name is lookup-only.
`symbol` converts a string only to a spelling that already exists, and words
that materialize values from external bytes — JSON, CSV, directory listings,
environment variables, HTTP headers — produce strings, never symbols. A new
data-facing word that emits a symbol from input violates this invariant even
when its inputs are small.

### Ownership passing makes precise reference counting useful

Heap objects use atomic reference counts. The operand stack owns every value it
contains, so ordinary push and pop transfer ownership without changing a
count. Operations such as `dup` that create another owner increment the count;
containers and environments retain values they store.

This discipline preserves meaningful uniqueness. When a list has exactly one
owner, a kernel or collection operation may claim a nominal `Unique*`
capability and reuse compatible storage. Publishing the result consumes that
capability. A shared input or an incompatible element width takes the allocate-
and-copy path. No caller performs an unchecked count test followed by a raw
mutable cast.

The broad idea resembles precise-reference-counting reuse systems such as
Perceus, but ecl applies it directly to an interpreter value stack. The
Acquire uniqueness read matters: it synchronizes with another thread's final
Release drop before reuse begins.

### Acyclic ownership replaces a cycle collector

There is no tracing collector. Lists and dictionaries are built bottom-up;
ordinary words retain scope identities; and module ownership uses opaque homes,
pins, and non-owning directory identities. Those representation constraints
keep environment cycles outside the value graph. A proposed value or binding
edge must be reviewed against the acyclicity argument. The known exception is a
task whose result contains its own handle; that creates one bounded self-cycle
that the current runtime cannot reclaim.

### Destruction is deferred and bounded

Dropping the last reference detaches a typed retirement item into the Session's
`ReleaseDomain` in constant work. The host or scheduler later advances graph
destruction in bounded slices.

`HostOwner` is the only authority that can drain the domain synchronously.
Executing Units receive a facade that can release, enqueue, and advance bounded
retirement, but cannot blockingly destroy the Session's graph. This keeps a
nominally constant scheduler turn from hiding an unbounded recursive free.

Port reference lifetime is intentionally distinct from external-resource
lifetime. A port heap object retains a process cell so terminal observations
remain safe. A separate `ControllerGroup` issues one lease to every detached
supervisor, pipe, timeout, and escalation thread and owns the spawning
`TaskScope` membership. The final controller lease is released only after its
thread's process-cell reference, and only that final release detaches scope
membership. The process-cell reference count therefore describes value and
readiness observation, never controller quiescence. Dropping the last port
value cannot orphan a live child, retaining a port cannot detach it from scope
closure, and Session teardown cannot overtake a detached controller thread.

## 4. Words, environments, and modules

Values answer “what data is this?” The binding system answers “what does this
word occurrence mean now?” Separating those questions preserves reflection,
late binding, and each occurrence's definition context.

### The word occurrence is the unit of resolution

A `WordRef` stores an interned name and a `ScopeId`. The reader stamps each
word occurrence with the scope in which its text was read. Copying, moving, or
splicing a word copies that stamp, so a single quotation may contain words from
several origins.

This is a syntactic closure that captures resolution context and no values:

- a stamped word resolves through the chain it was written against;
- an unscoped word constructed at runtime resolves where it is invoked; and
- the quotation containing either word has no single captured environment.

Putting context on the identifier is what makes ordinary list concatenation
correct. A quotation-wide environment would lose the origins of words spliced
from different sources. The design takes its cue from Bawden and Rees's
syntactic closures and Flatt's scope-carrying identifiers, but ecl has no macro
expansion. Its scopes form a parent chain, so one innermost identity plus that
chain is sufficient; a set of expansion scopes and subset disambiguation would
add machinery with no semantic work to do.

Scope IDs index stable cells and carry no ownership. Resolving through a cell
acquires and validates the relevant scope or module owner before dereferencing
it. IDs increase monotonically, and an identifier naming a retired image
resolves to a definite retired-domain failure.

### Lookup is late and definitions are stable publication points

Environments are short chains: a child reaches its parent, a session scope
reaches the session environment and then core, and a module reaches its own
environment and then core. There is no implicit import-order tier. Qualified
module lookup and explicit import are separate operations.

Each environment publishes an immutable name-to-cell shape. A binding cell is
stable, while its immutable payload snapshot may be replaced. Executing a word
therefore performs a fresh lookup and loads the cell's current payload. Existing
code sees a redefinition in a mutable scope while its own values stay unchanged.

A binding payload is one closed choice:

- a source quotation;
- an in-tree builtin callback; or
- a validated native callable.

Effect metadata, documentation, visibility, source slices, and module-local
diagnostic identity travel in the same snapshot. Readers acquire leases;
writers build before taking the publication lock, validate and swap in constant
time, and retire the old snapshot after unlocking.

### An execution site correlates three contexts

An activation needs three related but non-identical facts:

- `scope`: where its own definitions land and what invoked unscoped
  quotations inherit;
- `resolution_scope`: where its stamped body references resolve; and
- `home`: the module image and registration whose privacy and durable state it
  may use.

`ExecutionSite` carries them together and exposes named constructors for root,
image, inherited, and resumed execution. They cannot safely be reconstructed
from one another. A source definition may resolve against its defining chain
while inheriting a caller's module home, and an anonymous module image may have
private code but no registered state slot.

This is a recurring architectural rule: correlated ownership, liveness, and
authority facts cross a boundary as one nominal value.

### Images, registrations, and state have different lifetimes

A module image is immutable code and metadata with its own environment and
root scope. A registry registration publishes an image under a canonical name
as one generation. The registry slot owns the durable stack and the FIFO
arbiter used by `within`; an image supplies the initial stack template.

Separating the three concepts supports all of these cases cleanly:

- an anonymous image exists as a first-class value with no registered state;
- one immutable image may be registered under more than one name;
- replacing a registration publishes a new generation without rewriting the
  old image; and
- old code may finish under a generation pin while new qualified calls reach
  the current generation.

This resembles Erlang's distinction between old and current module code. ecl
uses reference-driven lifetimes, so any historical generation remains alive
while a reader or execution pin needs it. It also resembles read-copy-update:
publication makes a new immutable version reachable, while reclamation waits
for readers and execution pins to leave the old version.

Qualified lookup acquires a generation lease, resolves a public binding, and
turns the result into an execution pin before code runs. A Unit retains each
generation it dispatches through. A module-local word can therefore keep
running during replacement without a raw environment pointer escaping.

The reserved qualifier `core` is decided before any of that. When the
resolution cursor splits a dotted spelling and the module segment is exactly
`core`, it looks the binding segment up in the core environment directly and
never acquires a registry lease, so `core.dup` reaches the primitive from a
session or image that has shadowed `dup`, with no generation, home, or
call-site cache involved. Core is not an image and gains no module lifecycle
by being nameable: the registry refuses the exact name `core` for both module
registration and alias publication, which is the single boundary that owns
registry names, so no later registration can capture the qualifier.

### Stateful module application is an explicit transaction

`within` requests one FIFO state turn, snapshots or drafts the slot's durable
stack, runs the application against that draft, and publishes only after
successful completion. The granted turn is the mutation capability. A Unit has
one consumable turn authority, so the type system excludes nested or
cross-module state applications.

Old code remains executable, but a superseded home cannot publish new durable
state. Removal closes admission, lets outstanding turns settle, and separates
the slot's teardown from delayed generation retirement.

### Loading feeds the same resolution tail

An unresolved qualified name may suspend dispatch while the loader searches
the embedded standard-library manifest, the project/package catalog, source
paths, or native artifacts according to `ENVIRONMENT.md`. The continuation
retains the exact word, source site, operands when necessary, and package
authorization. After publication, execution returns to the same resolved-
binding path used by an already-loaded module.

Loading returns to the common dispatch boundary, which continues to own
privacy, effects, diagnostic naming, generation pinning, idiom guards, and
cancellation.

## 5. The frame machine

`machine.zig` is a first-order abstract machine. Its state is a current
quotation and instruction index, an operand stack, an explicit frame stack, an
execution site, and at most one active work driver. The explicit frames carry
the ecl continuation independently of the Zig call stack.

The closest standard description is a defunctionalized CEK machine: control is
the current quotation, the environment is the `ExecutionSite`, and the
continuation is a tagged `Frame`. ecl adds its visible operand stack and the
application, scheduler, module, and error boundaries required by the language.

### Explicit frames carry continuation

`Frame` is one exhaustive tagged union. Its variants represent:

- suspended evaluation;
- source-effect completion checks;
- combinator and isolated-application continuations;
- resumption after qualified loading; and
- transactional boundaries such as `@attempt`, module construction, and
  stateful application.

Each variant owns exactly the fields meaningful in that phase. Transitions
consume one state and construct another, giving continuation modes,
publication phases, and teardown an exhaustive representation.

Because continuations are explicit, the machine can suspend, move a Unit to
another worker, unwind incrementally, and guarantee language tail calls without
depending on Zig's calling convention.

### The evaluation loop has one order

Each pass through the loop performs the first applicable action:

1. complete pending task-join or park resumption work;
2. return `parked` when an external result is required;
3. advance an installed work driver;
4. honor a requested process exit;
5. resume a saved frame when no quotation is current;
6. return from a completed quotation;
7. check fuel and cancellation at a safe point; or
8. fetch and dispatch one form.

That ordering is part of the machine's design. A driver completes before the
parent evaluation resumes; cancellation is observed at bounded safe points;
and frame resumption cannot accidentally dispatch past work installed by the
continuation.

Dispatch itself has two cases. Non-word forms transfer a retained value to the
operand stack. A word starts bounded resolution, then the common resolved tail
schedules a source body, invokes a builtin, or starts a native call.

### Tail position reuses control

A non-tail call saves the current evaluation in a frame. A tail call replaces
the current `(code, ip, site)` state. Combinators mark their documented tail
positions in the same continuation machinery, so tail recursion and iteration
consume constant frame space. Constructs such as general `linrec` that need
post-recursion work retain one explicit continuation per descent.

Proper tail behavior is therefore a guarantee of the language machine,
independent of host-compiler optimization.

### Applications isolate stack contracts

Higher-order combinators run quotations through application frames. An
application records its stack window, execution context, resumption callback,
and the source quotation selected for any effect failure. Drivers that iterate
`each`, `fold`, `scan`, stateful operations, or user-defined recursion share
that stack protocol.

The window is a nominal value derived from a real stack depth. A callback
cannot pair an arbitrary base with a count, and a nested application that
suspends carries the exact continuation it must resume.

### Failure is a bounded machine transition

Language errors are ordinary dictionary values at observation boundaries, but
the live evaluator carries a compact internal `EclErr`. On failure, one
`FailureDriver`:

1. walks explicit frames to collect the language trace;
2. resolves module-local diagnostic spellings;
3. asks the source archive for the most precise available location;
4. materializes the error dictionary; and
5. unwinds frames, locals, and operands in bounded steps.

`@attempt` is an explicit catch boundary that converts the result to an
`{'ok ...}` or `{'err ...}` envelope. Without such a boundary, the Unit fails
and the Session restores its stack checkpoint. No host exception or host stack
frame becomes public error data.

## 6. Bounded work is the execution currency

Every operation whose cost can scale with user input must expose resumable
progress. This includes reading, hashing, equality, rendering, list and
dictionary construction, pervasion, sorting, imports, module loading, package
work, error unwinding, cancellation walks, and destruction.

The rule is stronger than “check cancellation in long loops”: there must be no
long loop or recursive cleanup hidden inside one nominal scheduler step.

### Cursors make continuation state explicit

Small algorithms return `poll.Progress(T)` with `pending` or `complete`.
Streaming algorithms add `item`. Nested traversals store their work in
non-relocating chunk stacks or lists. Machine-integrated operations install a
typed `WorkDriver`, which owns its cursor, temporary values, source location,
and cleanup behavior across yields.

One `WorkBudget` is threaded through nested work. A child returns its unused
allowance to its parent, so the whole nested operation remains within one
scheduler quantum.

Host-side and provably bounded construction or observation may drive a cursor
synchronously. Worker paths retain the cursor state and yield it back to the
scheduler.

### Construction avoids relocation in cancellable paths

Known-size results allocate exactly once and fill in bounded ranges. Results
whose final representation emerges during traversal use fixed chunks, then
perform one polled materialization pass. This keeps cancellable algorithms away
from repeated relocation or rehashing while they partially own user data.

Consuming APIs state what happens on every exit. An owned input is moved into a
driver, returned to the caller, or retired, making append and publication
ownership exact under failure.

### Boundedness includes retirement

Reclamation competes for scheduler service like evaluation. Final references
detach O(1) retirement records; release cursors later walk the graph. The
scheduler arbitrates between ready execution and retirement so a continuously
ready program cannot strand memory, and a large retired graph cannot make
cancellation latency proportional to the whole graph.

Cold Sessions and blocking public turns also settle or transfer retirement.
Memory left after readers drain must be bounded by live or peak simultaneous
state, independently of the number of historical publications.

## 7. Pervasion, kernels, and guarded idioms

The general frame machine defines evaluation. Bulk array operations move flat
data through closed typed kernels while scalar behavior and the generic
recursive path remain authoritative.

### Pervasion owns shape descent

Primitive scalar operations extend over lists and dictionaries according to
the language's conformability rules. Generic pervasion walks nested values with
bounded cursors. Collection owners centralize selection, traversal order, shape
preservation, and dictionary behavior for every caller.

When descent reaches a specialized flat leaf, the kernel registry classifies
the operation and operand representation as one of:

- a reorderable typed loop;
- bulk data movement;
- a sequential typed operation whose order is semantically significant; or
- generic fallback.

The registry is a closed, compile-time-validated table over the operation and
representation enums. Every added operation or leaf kind must classify each
reachable combination for the program to compile.

### Scalar semantics remain the oracle

Typed loops implement the same conversions, overflow rules, fault indices,
float bit behavior, equality, and output representation as scalar evaluation.
They decide output width before the first write or retain enough evidence to
report the same first fault. Ordered folds and stable comparisons preserve
their semantic order in typed storage.

Flat inputs are borrowed through retaining `LeafReader` capabilities. Outputs
are built through single-publication `LeafWriter`s or through a claimed unique
input whose element width is compatible. Mutable access and its ownership proof
arrive together as one capability.

Scalar broadcasting reads a repeated operand in stride-zero style, avoiding an
array of copies. SIMD is permitted only behind a closed policy whose scalar
prologue, vector blocks, tail, and fault reporting preserve the same contract.

### Idiom recognition is guarded, source-preserving fusion

Some compact source definitions express a useful bulk operation but would
otherwise decompose it back into many interpreter steps. At direct source-word
entry and selected combinator boundaries, `idioms.zig` matches a small closed
table of quotation shapes.

Recognition is guarded by binding identity. Every named token in the pattern
must resolve, in the candidate's actual scope chain, to the expected trusted
builtin or source definition. Shadowing, escaped code from another module,
wrong literal shape, or any other mismatch selects the generic frame-machine
path. The guard result lives for that application and is discarded afterward,
so redefinition receives a fresh check.

This has the role of a superinstruction—one checked phrase becomes one more
substantial host operation—but preserves the properties ecl cares about:

- the source definition remains the only reflected definition;
- late binding remains observable;
- generated and spliced quotations need no recompilation; and
- the generic path is always available as a differential oracle.

Builtins remain appropriate for irreducible representation or host-authority
operations. Compact language logic belongs in the prelude or source modules.
Recognition is the bridge for the small set of source definitions whose
measured cost justifies fusion.

## 8. Scheduling and structured concurrency

A `Unit` is a green execution context. The scheduler may run Units
cooperatively on the calling thread or on a fixed worker pool; both modes use
the same machine, queues, wait protocol, task tree, and retirement domain.
Cooperative mode gives deterministic embeddings and allocation-failure testing
the same semantics as worker execution.

### The policy is a functional core with an imperative shell

`scheduler_core.zig` defines closed state machines for Unit execution, waits,
registration, and task scopes. Given a state and an event, it returns the only
legal decision. `scheduler.zig` owns mutexes, atomics, queues, workers, timer
infrastructure, and the effects of those decisions.

This split makes invalid transitions visible to exhaustive switching and keeps
locking policy out of semantic decisions. Verification also exercises the real
shell, publication ordering, and reclamation paths under workers and
sanitizers.

### Fuel and drivers define safe points

Each Unit has dispatch fuel. Fetching a form spends fuel; a long primitive
spends bounded work through its driver. At exhaustion the machine checks
cancellation and yields. A scheduler slice therefore has a bound independent
of the total source or collection size.
A suspended driver owns the stack handoff it needs. It cannot keep a mutable
slice of the operand stack while another continuation runs, and a park request
defines who owns its payload until delivery, cancellation, or teardown.

### Tasks form a lifetime tree

Spawned tasks register atomically under a `TaskScope`. A scope cannot finish
until its descendants finish; cancellation propagates through the tree; and
closing a scope stops new children before teardown advances. This is the
structured-concurrency rule that lets a parent own the resources its children
borrow.

Task handles refer to write-once task cells. Construction, active execution,
and published terminal results are distinct tagged states. The task becomes
reachable after its execution and parent membership are stable. A cancelled
ready task is prevented from dispatching, and cancellation itself performs no
allocation.

Waits use explicit wait sets for one task, any task, a join, or a deadline.
Setup publishes the wait only after all registrations are ready. Completion,
cancellation, and timeout contend through one arbitration state, so exactly one
result owns delivery and cleanup.

External readiness uses the same arbitration rather than a parallel scheduler.
`external.zig` supplies nominal type-erased readiness and scope-membership
handles whose callbacks state ownership on registration, failed registration,
wake loss, cancellation, and detach. A process pipe or terminal event may wake
a Unit, but scheduler code never imports process backend types. Detaching an
external member first unlinks it, then releases every list, token, and
cancellation-cursor reference and the member capability itself; only that
node's final release decrements the scope's child count and publishes
quiescence. Scheduler and allocator teardown therefore cannot overtake the
cleanup performed by a membership callback.

A native work driver that must wait carries its driver and park request in one
exhaustive continuation variant. This is the external equivalent of the task
join/work cleanup states: no side-band pointer can outlive the stack window or
be deinitialized twice when readiness races cancellation. A deadline timeout
clears any attached work driver before publishing its result.

Process cells own exhaustive constructing, running, closing, terminal, and
reaped phases, independently from a private process-group authority with
`running`, `grace`, `kill_issued`, and `retired` variants. Only its nominal
`OwnedGroup` payload contains the child handle and PGID. A transition consumes
that payload before signaling; the grace timer carries only the matching
escalation identity, and `kill_issued` and `retired` permit no further signal.
Separate bounded stdin, stdout, and stderr queues let each pipe advance
independently. A full queue pauses only its producer; a background wait
publishes one immutable `Child.Term`. POSIX children are created as
process-group leaders. The supervisor observes leader termination with
`waitid(..., WNOWAIT)`, performs the consuming TERM-to-KILL cleanup, and reaps
the leader only afterward. The waitable leader pins its PID slot, so the PGID
cannot be reused while cleanup retains it. The controller group stops issuing
leases at retirement and its final lease may detach scope membership only
after the group state contains no process identity. Every controller lease
owns a process-cell reference. Lease creation and release-count transitions
are serialized by the process-cell mutex; a nonfinal lease drops its cell pin
before publishing the smaller count, so the supervisor can observe the final
count only after every other release completes. The final lease takes the
membership token, drops its cell reference while the external-member reference
still pins the cell, and only then detaches membership, so scope quiescence
cannot race any controller release. Each cell owns a nominal live-process
reservation; after every nonfinal controller has drained, the supervisor
consumes that reservation under the cell lock before publishing the public
reaped state. Observing termination therefore also closes the process owner's
lifetime use. Reaping the group leader therefore
cannot suppress group cleanup or publish scope quiescence while cleanup still
owns process-group authority. Stdin independently transitions
through `open`, `closing`, `closed_cleanly`, or `broken`; `proc.run` cannot
publish success until it observes a terminal stdin state, so a late background
EPIPE remains observable even after all input entered the bounded queue.
Compound `proc.run` readiness uses an opaque process-owned cursor over an
exhaustive set of stdout-terminal, stderr-terminal, input-terminal,
I/O-failure, and reap edges. Polling returns only previously unobserved edges
and consumes them under the process lock, while registration compares newly
published edges with that cursor.
Buffered bytes and writable queue capacity remain level-triggered. A failure
published after polling still wakes the driver, while an observed failure
cannot turn later pipe or reap readiness into a scheduler hot loop.

Every `proc.write` call acquires its nominal write ticket when the call reaches
the primitive, before resumable byte validation and encoding. A driver owns
exactly that ticket until completion or abandonment, so later calls cannot
overtake an earlier call while it yields. An optional process deadline stores
presence separately from its duration: absence is unlimited, while a present
zero duration expires immediately.

### Filesystem operations are bounded drivers over confined handles

Every `fs` word, generic archive extraction, and package-store operation runs
as one scheduler driver. The driver first encodes and validates its inputs
without touching the host: the canonical path grammar, the named root, the
semantic grant, and a live-operation slot from the owner's quota. It then
resolves the path with `filesystem_port.Resolver`, one component per step:
each component is opened or inspected relative to the handle on top of a
stack anchored at the root with `O_NOFOLLOW`; a symlink target is read and
spliced into the resolver's budgeted input, a private `BoundedPath` that the
initial path pays into at construction and that every splice charges before
replacing the text (40 expansions and 64 KiB by default), so a resolver never
holds bytes the limit did not admit; `..` pops one handle and refuses to pop
the root; an absolute target is refused. Linux and macOS share this one walker, and the only
platform-specific code is the atomic no-clobber and exchange rename
(`renameat2` flags on Linux, `renameatx_np` on Darwin). Hosts without those
primitives fail rather than degrade to a check-then-overwrite sequence, and no
supported path ever reopens a root by its configured string or consults the
process working directory.

Transfers move 64 KiB per step; listings observe at most 256 entries and
64 KiB of names per step, and ordering runs through `directory_order.Orderer`,
a resumable pointer collection plus bottom-up merge sort whose sorted slice is
reachable only from its completed state; the source audit forbids general
sort calls in the filesystem, archive, and package-store drivers, so a whole
listing can never be ordered in one scheduler step. Mutation stages complete contents in a private
sibling entry whose unguessable name is known only to the driver, checks
cancellation after the last write, and publishes with one atomic namespace
operation: a no-clobber rename for create and copy, an exchange for replace
(the displaced entry then sits under the staging name and is disposed after
the commit has already succeeded). Cancellation or failure before the commit
unlinks the staging entry and leaves the destination unchanged; a commit that
has succeeded is reported as success. The driver's bounded retirement closes
every handle, disposes any unpublished staging entry, releases listing storage
one entry per step, and releases the quota slot last, so a task scope or
Session cannot publish quiescence while an operation still owns any of them.
The filesystem read, write, and publication primitives run on the worker in
these bounded quanta, the same convention the archive and package-store
drivers already use; only process pipes and network ports (listeners and
connections) use detached controller threads, and a network listener owns a
socket and starts its one acceptor thread only when a unit first parks in
`accept`.

Every failure maps a host error to one closed reason vocabulary at the
`filesystem_port` boundary and attaches the operation, root, path (or both
ends of a transfer), and reason to the pending failure, so programs branch on
stable symbols and never on errno names.

### Network listeners are scope-owned sockets with a lazy acceptor

Inbound listening follows the filesystem model, not the process model. A Host
may supply a `NetPolicy`: either an unrestricted grant or an exact allowlist
of address and port pairs, plus a maximum live-listener count and the kernel
accept backlog. Session construction copies the policy into a `NetOwner`,
parsing every address once through `std.Io.net.IpAddress.parse` (literals
only, never resolution) and normalizing IPv4-mapped IPv6 addresses to IPv4, so
grant comparison is over parsed values and no spelling of an address can
bypass an entry. A literal that does not parse, two entries that normalize to
the same address and port, a zero limit, or an unsupported target fails with
`InvalidHostPolicy` rather than `OutOfMemory`. The owner mints one opaque
`NetAccess`; Units receive only that and cannot reach the owner, the socket,
or the descriptor.

`listen` runs four bounded syscalls on the worker — socket, bind, listen, and
getsockname, all through `std.Io.net.IpAddress.listen`, which stores the
resolved local address on the returned socket — and never parks; a listener
that is never asked to accept has no controller thread, readiness source, or
wait registration. The order is the process port's: validate the configuration, check
the grant, acquire a live-listener reservation (a consuming capability like
the process live slot), open the socket, create the `ListenerCell`, attach it
to the calling unit's `TaskScope` through `attachExternal` and store the
returned membership token, and only then wrap it in a port value with
`heap.createPort`. Every failure on that path releases the reservation and
closes the socket exactly once. The socket is opened before the scope is asked,
because a scope may begin closing between any earlier check and the attach;
when `attachExternal` refuses a closing scope, the just-opened socket is closed
through the same `close` transition and the caller sees `'cancelled`.

A `ListenerCell` has one mutex-protected exhaustive state, `bound` (owning the
server socket and its resolved address) or `closed`, and one reference count
shared by the port value and the scope member; the heap projects a port to a
cell only when the release adapter matches, so a process port and a listener
cannot be confused. `ListenerCell.close` is the single close transition: under
the mutex it moves `bound` to `closed`, stops the acceptor if one is running
(see the next section), closes the socket, and releases the reservation; after
unlocking it detaches the scope membership token once. It is idempotent, and
both the `net.close` word and `cancelExternalMember` call it, so a listener
closed explicitly and later swept by its scope, or the reverse, closes exactly
once and detaches exactly once. When `close` returns the socket is closed, so
the same address and port may be bound again immediately. `local-address` reads
the state under the mutex and copies the address out; a `closed` cell has no
address to report. The cell is destroyed when the last reference drops and is
asserted `closed` at that point. `NetOwner.deinit` asserts a zero live count,
which holds because Session teardown closes the root scope first.

Every failure maps a `std.Io.net.IpAddress.ListenError` to one closed reason
vocabulary at the `net_port` boundary — `'in-use`, `'unavailable`,
`'resources`, `'unsupported`, `'io` — and the `net` module attaches the
requested address, the requested port, and the reason to the pending failure.
Refusals before the host is reached are `'domain` with reasons `'unavailable`,
`'denied`, and `'limit`, matching the process and filesystem capabilities.

### Network connections extend the controller model

Accepting, reading, and writing block indefinitely at the kernel and have no
worker-side readiness source, so they follow the process-pipe model rather
than the filesystem model: detached controller threads perform the blocking
calls and hand results to the scheduler through bounded queues and the
readiness capabilities in `external.zig`. A parked unit holds no worker. The
thread that owns a socket is the only place that closes its descriptor,
releases its live reservation, and detaches its scope membership, exactly as
the process supervisor is for a child.

Ownership is carried by consuming types rather than by convention. An
`OwnedSocket` closes its descriptor at most once; a `ConnectionReservation`
releases its quota slot at most once; an `AcceptedSocket` bundles both with
the connection's `Endpoints` (the peer from `accept`, the local end from
`getsockname`, so a wildcard listener's connection reports the address it was
actually reached on). No other production code in `net_port.zig` calls
`closeFd` on a connection socket or decrements the connection counter. Each
outstanding `accept` owns an `AcceptSlot` whose state is exhaustive:
`waiting` (holding nothing: neither a socket nor a reservation), `ready`
(holding an `AcceptedSocket`), `failed`, `taken`, or `closed`. `endAccept`
releases whatever the slot still holds, so a cancelled accept can neither
leak a socket nor release a slot twice, and a waiting accept costs the
connection quota nothing.

The listener gains one acceptor thread, started by the first `beginAccept`
and never before. It waits in `poll` on the listening socket, switched to
non-blocking, and on the read end of a private wake pipe. It does not block
in `std.Io.net.Server.accept`: `shutdown(2)` on a listening socket does not
wake a blocked `accept` on macOS, closing a descriptor another thread is
blocked on is a reuse hazard everywhere, and `netAcceptPosix` treats `EAGAIN`
as a bug, so the non-blocking socket that `poll` requires would trip it. When
`poll` reports the socket readable, the acceptor takes the listener mutex,
rechecks that a `waiting` slot exists, acquires a `ConnectionReservation`
from `NetOwner` under that mutex, and only then calls `accept4`, still
holding the mutex, and moves the returned socket and its reservation into
that slot as one `AcceptedSocket` before unlocking (`acceptOneLocked`). When
no reservation is available the acceptor makes no syscall: the connection
stays in the kernel backlog, the acceptor marks itself quota-blocked, and it
polls only its wake pipe, not the listening socket, until a release wake
arrives, so a full quota spins no thread and takes no socket it cannot own.
Every failure arm after the acquisition releases the reservation. Because
`endAccept` takes the same mutex, the two cannot interleave: if the
cancellation wins, no `accept4` runs and the connection stays in the kernel
backlog for the next accept; if the accept wins, the socket belongs to that
slot and the cancellation closes exactly that socket. The syscall under the
lock is bounded because the socket is non-blocking. The number of sockets
taken and not yet handed over therefore never exceeds the number of
outstanding accepts (`queued <= demand`), and an idle program leaves
backpressure in the kernel backlog. A connection aborted between `poll` and
`accept4` is skipped; descriptor and buffer exhaustion mark the slot `failed`
with a `resources` reason rather than failing the thread. Readiness keys are
slot pointers, so a wake reaches the slot's owner and the owning driver takes
exactly its own socket. `ListenerCell.close` writes one byte to the wake pipe
and waits under the cell condition until the acceptor reports it has left
`poll` and will not touch the descriptor again; only then does it close the
socket, mark every waiting slot `closed`, and wake their owners. That wait is
bounded by one thread returning from a `poll` the wake byte has already
satisfied, which is not the unbounded worker wait this document forbids; the
process controller's cancellation does not wait because a child may take
hundreds of milliseconds to die, and no such delay exists here.

A `ConnectionCell` has exactly one controller thread. The socket is
non-blocking, and the controller waits in one `poll` over the socket and the
read end of its own wake pipe, asking for readability only while the receive
ring has room and the peer has not finished sending, and for writability only
while the send ring holds bytes. Workers touch only the rings, the flags, and
the wait list, and they write one byte to the wake pipe whenever they change
something the controller's interest depends on: bytes queued to send, room
freed in a full receive ring, or a stop request. One thread owning both
directions is what removes the races a reader/writer pair invites: there is
no second lease to mint before the first thread can finish, no writer failure
that leaves a reader blocked, and one code path that performs final cleanup.

The cell's `Lifecycle` is exhaustive and switched under one mutex:
`prepared` (allocated, no thread), `running` (the controller owns the
socket), `stopping` with a reason (`close` or `abort`), and `terminal` with
the reason it stopped for. Publication completes every fallible step before
concurrency begins: allocate the cell, the rings, and the wake pipe; attach
the member to the *accepting* unit's `TaskScope` (never the listener's, so the
listener may close first and a per-connection child owns exactly its own
connection); then, under the cell mutex, move `prepared` to `running` and
spawn the controller. A scope cancellation that arrives between the attach and
that lock hold finds `prepared`, records `stopping`, and the publisher seeing
`stopping` retires the cell without starting a thread and detaches the
membership it just received, so a scope is never left waiting on a controller
that does not exist; one that arrives after the lock hold finds `running` and
signals the controller through the wake pipe. Every failure before the thread
starts closes the socket, releases the reservation, publishes `terminal`, and
detaches any membership through the same `finalizeLocked`, which asserts it
runs once.

Explicit `close` moves `running` to `stopping(close)`: new writes fail
`'closed`, queued input is dropped because no read can observe it, and the
controller keeps polling for writability until the send ring is empty, then
performs `shutdown(SHUT_RDWR)` and finalizes. Scope cancellation
(`cancelExternalMember`) moves to `stopping(abort)`, discards the send ring,
and the controller shuts down and finalizes at once, so quiescence never waits
on a peer. A socket error in either direction records one `Failure` (`reset`
for `ECONNRESET`, `EPIPE`, and `ENOTCONN`; `io` otherwise), discards the send
ring, and the controller shuts down and finalizes on its next turn, so a
failed write can never leave the other direction blocked. End of stream from
the peer is not termination: the flag is recorded, queued bytes stay readable,
and the program may still write until it closes. A wake on the cell's wait
list is always `.ready`: a socket failure is a change in the cell's
observable state that the driver polls, not a failure of the wait service, so
every failure reaches the word with the peer's address, port, and reason.

Reads and writes observe the cell through one locked snapshot each. `read`
returns queued bytes first; otherwise the reason nothing more can arrive
(`closed` when the program or its scope stopped the connection, which
outranks a later peer failure; `reset` or `io` for a socket failure); otherwise
`eof`; otherwise pending. `write` fails for the same reasons, parks while its
permit is not at the head of the queue or the ring is full, and otherwise
queues bytes and signals the controller. At most one reader may be pending,
and writes are serialized by permits in arrival order, as for process streams.
`observeEndpoint(kind)` selects the local or peer address from the immutable
`Endpoints` and reports it as `available` while no failure reason applies and
as `closed` otherwise, so a terminal connection never exposes an address as if
it were live and a closed `local-address` names the local end rather than the
peer. A peer that never reads leaves at most `send_capacity` bytes queued
after an explicit `close`; `write` parked until those bytes entered the ring,
so the bound is the ring and nothing else.

The connection quota (`max_live_connections`) is a second compare-exchange
counter on `NetOwner` beside the listener quota. It is reserved when a socket
is taken from the backlog, never when an accept parks, so it bounds live
connections only and `accept` has no `'limit` failure. `NetOwner` also keeps
a registry of running acceptors: an intrusive list of listener cells that
`beginAccept` joins once the acceptor thread has started and that
`exitAcceptor` leaves before anything else. `releaseConnection` walks that
list under the owner's acceptor mutex and writes one wake byte to each
acceptor's pipe, so an acceptor blocked at the quota rechecks the counter as
soon as any connection in the Session releases its slot. A wake byte
therefore means "drain and recheck": the acceptor reads its stop flag under
the listener mutex to tell shutdown from a release, and otherwise clears its
quota-blocked mark and returns to polling the socket. The lock order is
fixed with the owner's acceptor mutex as the leaf: `beginAccept` registers
under the listener mutex, `exitAcceptor` and `releaseConnection` (which runs
from finalization paths under a connection cell's mutex) take it beneath
those, and nothing is ever acquired while it is held; it signals pipes and
returns. `ListenerCell.close` signals its own pipe and
waits until the acceptor has exited, so no cell is on the registry after
`close` returns. `NetOwner.deinit` asserts that the registry is empty and
both counters are zero, which holds because Session teardown closes the root
scope and every running controller holds the membership the scope waits on.
Failures on a connection are `'io` with the peer's address and port and one
of `'closed`, `'reset`, `'io`; the listener quota alone refuses with
`'domain` `'limit`; the mapping has one owner in `net_port.zig`.

### Absolute deadlines govern timer races

Timeouts capture an absolute deadline before lazy timer startup. Every
competitor revalidates against that deadline before committing a winner. An
already expired or already terminal wait completes from its entry state and
leaves timer infrastructure dormant.

The timer thread and indexed heap are created lazily. Blocking host I/O runs on
workers, making pool capacity the explicit bound around an OS call.

Timer state holds `Deadline` values, never raw timestamps. The only
constructor is `MonotonicClock.deadlineAfter`, a checked factory that refuses
an instant the clock can never report — past the i96 nanoseconds of a host
timestamp, past i64 milliseconds for the manual clock — so an unreachable
deadline cannot enter the heap. A `TimerNode` carries its deadline only inside
its `linked` membership; a detached node has no instant to misread. Both
timed primitives ask the scheduler to check the deadline before parking and
raise `'overflow` from the word itself; the registration path repeats the
check and, should the clock cross the boundary in between, selects the
`overflow` wake reason.

`clock.sleep` is the same wait with nothing to wait for but the clock. It is
its own `ParkRequest` variant and `WaitKind`, owns no task value, registers no
task cell, and reaches the timer arm of `WaitSet.advanceSetup` through the
ordinary states. Park results are typed by operation: `ParkResume` has one
family per request kind — `task_wait`, `sleep`, `external`, plus the root-only
`scope_closed` — and `WaitSet.materializeResume` switches first on the wait
kind and then on the wake reason, so a sleep can only produce a `SleepResume`
(`elapsed`, `cancelled`, `io`, `overflow`, `out_of_memory`) and a task wait can
only produce a `TaskWaitResume`. The machine's resume switch is exhaustive per
family, which is what lets a cancelled sleep say it was sleeping and a
cancelled readiness wait say it was awaiting host readiness rather than
borrowing the task-wait wording. Cancellation, `Io`, and allocation failure
flow through the identical arbitration, and delivery retires the timer entry
through the same `removeTimer` before the owner is woken. A zero duration is
already expired when the deadline is captured, so the unit parks and is
re-enqueued without the timer thread.

Every clock read inside the scheduler goes through `WorkerScheduler.now`.
Under a `manual` clock the timer thread never waits with a host deadline: it
blocks on its wake event, which `advanceManualClock` sets after storing the new
reading, and re-reads the clock after every wake, so an advance that lands
before the event is reset is seen by the following heap check and one that
lands after is seen through the event. Shutdown is unchanged: root-scope close
cancels sleeping tasks, their waits retire their timer entries, and the heap is
destroyed only after the timer thread has joined.

### Scheduling is nondeterministic; joins define deterministic observations

Workers may execute ready Units in any order. Determinism is restored where
the language specifies an order: join materialization, indexed `any` results,
and collection assembly. Random kernels use explicit key/counter addressing so
parallel scheduling does not silently change a deterministic stream; host
entropy is a separately authorized boundary.

The executor shares service among task dispatch, wait delivery, cancellation,
and retirement. No class may monopolize a worker indefinitely, and the root
blocking turn settles retirement even when the worker pool has not started or
is otherwise idle.

## 9. Publication and reclamation

Environments, bindings, module directories, generations, task results, and
stateful module stacks all publish information read concurrently. They use one
common pattern:

1. build and validate an unreachable candidate;
2. acquire the narrow writer or publication lock;
3. verify the expected current state;
4. publish initialized metadata and the reachable pointer in O(1);
5. detach the old version;
6. unlock; and
7. enqueue typed bounded retirement.

Locks protect validation and the commit. Allocation, user-code execution,
recursive destruction, and calls into the shared reclamation domain happen
outside those locks.

### Readers own evidence of liveness

Readers pair every immutable pointer with evidence that its allocation remains
alive:

- a binding or shape lease;
- a directory or generation lease;
- a module generation pin;
- a scope-cell borrow paired with image liveness; or
- a source slice that retains its backing allocation.

Observation capabilities return metadata or pinned cursors. They do not expose
raw homes, mutable scopes, owner factories, or an upgrade path to execution.
Upgrading, when legal, consumes a distinct owner-issued capability.

### Publication state is tagged ownership

Multi-phase handoffs use tagged unions whose variants own exactly the metadata
valid in that phase. Examples include provisional versus published module
registrations, constructing versus active versus terminal tasks, and draft
versus committed state applications.

This representation may be larger than a flag plus nullable fields. Frame and
state size ceilings move with an explanation when that space is required to
encode the invariant.

### Memory ordering belongs to each publisher

Every lock-free multi-field publication documents its happens-before relation.
Writers initialize payload and count metadata before publishing a reachable
head. Readers announce, acquire, and validate in the order paired with
replacement and reclamation. Each weaker ordering requires a proof for that
publisher; debug assertions serve only as secondary checks.

The RCU analogy supplies the removal/reclamation split. The local proof covers
ecl's specific combination of reference counts, leases, pins, mutex-protected
commits, and deferred cursors.

## 10. Standard code and native extensions

The interpreter starts with a small trusted core, then builds most vocabulary
as ordinary ecl definitions and modules.

### Prelude and standard modules retain source authority

`prelude.ecl` is embedded and evaluated during Session construction to populate
the core environment. `stdlib.zig` is a compile-time manifest of embedded
source and host-backed modules. Embedded modules win before filesystem search,
so a stray file cannot silently replace shipped code; explicit registration
and in-session shadowing remain language operations.

The placement rule is:

- use source for compact language logic;
- use a builtin when the operation requires representation access or host
  authority ecl cannot express; and
- use guarded idiom recognition when a source definition should remain
  authoritative but measured bulk performance needs a fused path.

Hosted modules combine source definitions with narrowly registered builtins.
Their manifest, documentation, effects, provenance, and package requirements
are validated before publication. Package discovery and synchronization are
described in `ENVIRONMENT.md`; they enter the evaluator through the same module
loader and bounded-driver conventions as other sources.

`http.server` is the model for a protocol module in source over host ports.
Its one effect boundary is a single private word that calls `net.write`, and
that word takes an ordinary response dict, validates and encodes it in full
through the public `render-response`, and only then writes; a rejected dict is
answered 500 as data. The source audit holds the module to that one call site,
so a malformed wire message is unreachable through the server even though a
malformed response dict remains an ordinary value.

`proc` is a builtin for the same reason as other host-backed modules: process
creation and pipe readiness require authority and representation ECL source
cannot possess. Its public values remain ordinary dictionaries, byte lists,
and opaque ports. The convenience `run` word is a client of the same controller
as streaming ports; it is not a blocking second implementation.

### The native ABI is narrow and transactional

A native artifact describes one module. The loader validates its descriptor,
module name, exported definitions, effects, documentation, callbacks, and
requested capabilities before constructing immutable binding snapshots. A
native library remains loaded for the Session lifetime; there is no native hot
reload.

The exact wire ABI is the callback's sole interpreter surface. It contains:

- read-only value and nested-path views;
- an output builder constrained by the declared stack effect;
- a host table containing only requested capabilities; and
- a typed rescheduling result for work that continues beyond one leaf call.

The machine presents the callback a transactional input window. A successful
return validates and commits the declared outputs. Failure restores the ecl
operand stack, while external effects performed by the callback remain
external effects.

Capability negotiation follows the same attenuation principle as systems such
as WASI: authority must be passed explicitly and can be narrowed. Native
modules remain trusted machine code in the interpreter process, so extension
correctness is part of the process's memory-safety boundary.

The public author SDK is a separate Zig module root under `src/native/`, which
prevents an extension from importing interpreter internals as an accidental
API. ABI declarations use the exact C calling convention and variadic shape of
their foreign prototypes.

## 11. Values become output

Evaluation has two observable output paths. Explicit I/O words write during
execution through the Session's console. Otherwise the host receives a
`UnitOutcome` and may render the Session stack or an error value after the unit
finishes.

### Rendering is iterative and has two policies

`print.zig` uses one explicit action worklist, keeping value depth off the host
stack. Canonical rendering is complete, single-line, and free of elision; values
with a readable syntax round-trip through it. Display rendering is for people
at the REPL or `io.pp`: it may lay rectangular rows on separate lines and
replaces very large lists or strings with a count-bearing marker before scanning
their full shape.

The renderer reads semantic values through collection APIs whose capabilities
keep storage alive across suspension. Error rendering is the rendering of an
ordinary error dictionary; source fields appear when the source archive
supplied them.

### The console owns terminal policy

All terminal output goes through `console.zig`. That boundary owns serialized
whole writes, escaping, terminal geometry, row planning, and cursor placement.
Editor redraw capabilities accept typed terminal actions and validated display
payloads.

The console asks the terminal or host for facts it can know and enables only
features supported by those facts. An unmeasurable terminal selects the
canonical line reader. A measurable terminal derives cursor placement through
bounded redraw from the kernel's terminal facts.

This is an instance of the owning-boundary rule: the sink that writes bytes
owns escaping for every producer upstream.

### The REPL is a host around the same Session

TTY detection in `main.zig` is the only path that constructs the line editor.
The editor owns UTF-8 edit storage and cursor movement; the reader owns lexical
completeness; the Session owns name observation; and the console owns terminal
effects. Opaque capabilities join those layers without exposing the Session or
pairing unrelated bytes and offsets.

The REPL accumulates physical lines into one `PendingUnit`, calls the same
`Session.runUnit` used by scripts, and prints the same display rendering a host
could request. Ctrl-C discards the pending unit while preserving the Session;
stack values, definitions, modules, and history survive into the next
successful turn.

Non-TTY stdin, files, `-e`, explicit output words, and formatting are CLI
policies around these shared evaluator surfaces.

## 12. Cross-cutting architectural rules

The components above share a small set of rules. These are the rules a design
change must preserve or explicitly revise.

### Put an invariant at its owner

A cross-cutting policy has one owning boundary. The console owns escaping, the
lexer owns lexical state, collection storage owns self-aliasing writes, the
module registry owns generation publication, and the release domain owns
deferred destruction. Callers receive a type or operation that already embeds
the policy.

### Make authority and phase nominal

Use opaque handles, nominal IDs, validated factories, capability values,
typestate, tagged unions, and exhaustive switches. A public Zig struct with a
private field type remains constructible through inferred literals, so genuine
encapsulation uses an opaque representation and validated factory.

Invalid combinations of allocator and reclamation root, scope and liveness,
module image and state slot, stack base and continuation mode, or provisional
and published metadata should be unrepresentable in every optimization mode.

### State ownership on success and failure

A consuming operation documents whether it takes, returns, publishes, or
retires its input on every exit. Builders, publication cursors, native calls,
module construction, and driver installation follow this rule. Cancellation
must be able to retire a continuation by walking its owned fields without
reconstructing what phase it reached.

### Bound work by user input, including cleanup

Every user-sized traversal, materialization, unwind, cancellation walk, and
destruction is a cursor or bounded chunk. Exact-size output and fixed chunks are
preferred to relocation in cancellable paths. Reaching the final reference or
holding a publication lock never grants permission to do an unbounded walk.

### Separate publication from reclamation

Build before the lock, commit in constant time, and retire after unlocking.
Every reader owns a lease, pin, or borrow for as long as it uses snapshot-owned
storage. Residual retired memory must be bounded after delayed readers release
and settlement runs.

### Enforce architecture with the strongest available mechanism

The order of preference is:

1. make invalid code fail to type-check;
2. use compile-time validation and exhaustive switching;
3. use the AST-aware source audit for rules Zig's type system cannot express;
4. test behavior through public or production-connected interfaces.

Behavioral tests exercise runtime or public interfaces. Source audits prove
source shape.

## 13. Verification strategy

Verification assigns each architectural claim to its strongest proof surface.

| Claim | Proof surface |
| --- | --- |
| Closed representations and phase machines | Zig types, opaque factories, `comptime` registries, exhaustive switches, and layout assertions |
| Repository and source-shape rules | The recursive AST-aware source audit over every classified first-party Zig file, plus the prelude layout audit |
| Language behavior | Runtime and CLI tests through `Session`, the executable, native fixtures, and checked snapshots |
| Filesystem confinement | Public `Session` tests over temporary directories with default-deny, per-grant, symlink-escape, staging-residue, cancellation, and concurrent-winner cases, plus the resolver's own component tests |
| Fast paths are unobservable | Differential tests comparing idiom-enabled and generic execution, and typed-leaf versus boxed-spine execution |
| Bounded work | Safe-point counts, fault-index tests, cancellation cases, memory ceilings, and large public workloads |
| Ownership under failure | Focused allocator-failure injection plus the initialized-Session OOM gate |
| Concurrent publication and lifetime | One- and many-worker suites, delayed-reader retention tests, cancellation/reload properties, and Linux TSan |
| Parser, editor, scheduler, and native robustness | Separate production-connected fuzz targets, with PTY tests for kernel-owned terminal behavior |

The ordinary local gate is `zig build precommit`; iteration may use
`zig build check` and targeted public behavior. The exact local, CI,
release-candidate, OOM, TSan, allocator, fuzz, and PTY procedures live in
[`agent-guides/testing.md`](../agent-guides/testing.md). Keeping those procedures
centralized lets test topology evolve independently of the interpreter
architecture.

Performance evidence comes from ReleaseSafe or ReleaseFast builds. A report
records target, optimization mode, workload, and repeated measurements.

## Design lineage and further reading

These references locate the choices above in the wider implementation field.

- Manfred von Thun, [*The Joy Programming Language*](https://hypercubed.github.io/joy/html/j00ovr.html), for quotation, concatenation, and programs as stack transformations.
- Robert Nystrom, [*Crafting Interpreters: A Map of the Territory*](https://craftinginterpreters.com/a-map-of-the-territory.html), for the source, AST, bytecode, and machine-code paths neighboring ecl's direct quotation execution.
- Roberto Ierusalimschy, Luiz Henrique de Figueiredo, and Waldemar Celes, [*The Implementation of Lua 5.0*](https://www.lua.org/doc/sblp2005.pdf), for a compact account of a register-bytecode VM and its representation tradeoffs.
- John C. Reynolds, [*Definitional Interpreters for Higher-Order Programming Languages*](https://homepages.inf.ed.ac.uk/wadler/papers/papers-we-love/reynolds-definitional-interpreters-1972.pdf), Matthias Felleisen and Daniel P. Friedman, [*Control Operators, the SECD-Machine, and the Lambda-Calculus*](https://scholarworks.iu.edu/dspace/items/d85303cb-faee-4396-bf56-b03b35758a47), and Jeremy Gibbons, [*Continuation-Passing Style, Defunctionalization, Accumulations, and Associativity*](https://ora.ox.ac.uk/objects/uuid:6e2d6de6-b01f-4263-bf12-3568bc3d8df0), for the path from recursive evaluators through CEK-style machines to first-order continuations.
- Alan Bawden and Jonathan Rees, [*Syntactic Closures*](https://doi.org/10.1145/62678.62687), and Matthew Flatt, [*Binding as Sets of Scopes*](https://popl16.sigplan.org/details/POPL-2016-papers/12/Binding-as-Sets-of-Scopes), for attaching binding context to syntax and identifiers.
- Philip Wadler, [*A Prettier Printer*](https://homepages.inf.ed.ac.uk/wadler/papers/prettier/prettier.pdf), for the document algebra used by source formatting.
- Justin Slepak, Olin Shivers, and Panagiotis Manolios, [*The Semantics of Rank Polymorphism*](https://arxiv.org/abs/1907.00509), for a modern formal account of the array-language family whose pervasive operations inform ecl.
- Alex Reinking, Ningning Xie, Leonardo de Moura, and Daan Leijen, [*Perceus: Garbage Free Reference Counting with Reuse*](https://www.microsoft.com/en-us/research/uploads/prod/2021/06/perceus-pldi21.pdf), for precise ownership accounting and reuse under reference counting.
- M. Anton Ertl and David Gregg, [*Optimizing Indirect Branch Prediction Accuracy in Virtual Machine Interpreters*](https://doi.org/10.1145/780822.781162), for superinstructions and the dispatch economics shared by guarded idioms.
- Nathaniel J. Smith, [*Notes on Structured Concurrency*](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/), for task lifetimes that nest like ordinary control flow.
- Linux kernel documentation, [*What is RCU?*](https://www.kernel.org/doc/html/latest/RCU/whatisRCU.html), for separating publication/removal from later reclamation.
- Erlang/OTP, [*Compilation and Code Loading*](https://www.erlang.org/doc/system/code_loading.html), for concurrent execution of old and current module generations.
- WASI, [*Design Principles*](https://github.com/WebAssembly/WASI/blob/main/docs/DesignPrinciples.md), for explicit, attenuated host capabilities and the rejection of ambient authority.
