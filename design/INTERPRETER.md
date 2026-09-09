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
| Port controllers | Typed job submission, FIFO admission and cancellation, independent execution, joined retirement, and shared scope lifetime | `port_controller.zig`, `port_transfer.zig` |
| Process ports | POSIX process-group ownership, bounded pipe queues, and terminal publication | `process_port.zig`, `stdlib/proc.zig` |
| Network listeners and connections | Normalized IP literals, scope-owned listening sockets, demand-gated accept, bounded connection queues serviced by controller threads, and idempotent close | `net_port.zig`, `stdlib/net.zig` |
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

`Session` is the internal interpreter boundary and the root of every runtime
lifetime. It is an opaque, movable handle to heap-stable `SessionCore` state.
The CLI, repository tests, and tools use one build-private runtime aggregation.
There is no supported interface for Zig applications to construct or drive ECL.
The separate `ecl-native` SDK supports the other direction: ECL calls trusted
Zig extensions through semantic facades and the native ABI.

That state owns:

- the host allocator and `ReleaseDomain`;
- the core and session environments;
- the module registry and native-module owner;
- the persistent operand stack;
- the source-span archive;
- the scheduler and root task scope; and
- immutable or explicitly synchronized views of host services such as
  arguments, environment variables, standard input, output, diagnostics, TLS
  trust, project configuration, module search paths, process, filesystem, and
  network owners, and optional package-store authority.

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

Task construction remains in the core vocabulary. The embedded `task` module
exposes handle observation, waiting, and cancellation through the same scheduler
capabilities as core constructors; loading the module grants no additional authority.

### Host state is captured or capability-gated

A Session captures the host environment once, records whether standard input
remains available as data, and owns any TLS or path overrides needed by its
Units. The CLI captures its startup directory and environment snapshot once
and shares those inputs across every execution entrypoint. One private CLI
runtime owns writer buffers, writers, named-root storage, and its Session. It
is initialized at its final address and remains there until Session teardown
releases every borrow. Failed construction retains no live Session. Project
discovery begins at that startup directory.

Host operations are exposed to executing code through narrow facades. A Unit
may enqueue work, write through the console, load through the module loader, or
use immutable host configuration. It cannot reach the raw Session, allocator,
registry, scheduler lifecycle, or reclamation root. Observation, execution,
mutation, and teardown are distinct authorities.

Every initialized Session has the same complete runtime shape. Its constructor
requires I/O, output and diagnostic writers, a startup directory, an environment
snapshot, scheduler configuration, and an explicit command mode. Evaluation,
language tests, and package commands differ only in the additional authorities
their modes mint. Process, filesystem, and network owners are unconditional.

Inherited context distinguishes prelude bootstrap from runtime execution.
Both phases require a module registry. The bootstrap phase builds the core
before a Session is published; it is not a reduced Session. Runtime context
requires the native loader and complete service access, including a Console
with output and diagnostic writers. Context is copied into descendants without changing module-loading order. All access borrows
Session-owned state, which survives until tasks, modules, and retirement work
have settled. Shared test fixtures keep isolated directories, streams, and
explicit environment inputs alive through Session teardown.

Monotonic and wall clocks always exist at runtime. The CLI uses real clocks;
manual monotonic and fixed or anchored wall clocks, cooperative scheduling, and
TLS verification overrides are internal deterministic-testing inputs. They
confer no permissions and introduce no command-line modes.

The dependency-neutral `startup_environment.zig` owns validated environment
entries and backing bytes together with their allocator. Session owns this one
snapshot; evaluation and the process owner borrow immutable views. Shutdown and
initialization rollback release the snapshot only after its dependent owners;
normal teardown first joins the scheduler and destroys the process owner. Child
environment maps retain their independent overrides.

The process owner requires an explicit startup directory and retains its owned
sentinel-terminated copy, together with live-count, queue, and capture limits.
Its opaque `ProcessAccess` lets Units
request operations without obtaining the owner, scheduler scope, process cell,
group identifier, or PID. Executable and working-directory syntax is validated
at the process boundary; the operating system determines access.

The filesystem owner opens named roots once and owns their handles and the
live-operation quota. Invalid roots or limits fail construction with
`InvalidHostConfig`, distinctly from allocation failure. Authority remains the
retained directory handle after a rename, and every root supports all filesystem
operations subject to operating-system permissions. Units receive opaque
`FilesystemAccess` for root lookup and operation admission. Root-relative path
resolution enforces containment; module loading remains a separate operation.

Clocks are two runtime inputs with different shapes. The scheduler owns
monotonic time as one `MonotonicClock` tagged union, selected at construction
from internal clock configuration: the `host` variant carries the Session's origin
instant and reads the process awake clock; the `manual` variant is an opaque
`ManualClock` whose reading is whole milliseconds and whose only mutation is a
compare-exchange advance with checked addition, refusing a step that would
leave the range without touching the stored value. It moves through
`Scheduler.advanceManualClock`, a method on the host-root handle that the
`WorkerScheduler` facade does not expose, so no evaluated word can move time.
Every deadline capture, arbitration check, timer wake, and `clock.now` sample
reads `WorkerScheduler.now`, so the whole Session agrees on one "now". The wall clock is a separate
`machine.WallClock` union on the runtime context: realtime I/O, a fixed value,
or a base anchored to the monotonic clock. CLI construction selects realtime;
the other variants support deterministic tests independently of TLS time.

Package command mode alone mints a `PackageOwner`, and carries one tagged
`PackageGrant` naming exactly the stores a command shape may touch (`inspect`,
`collect`, `verify`, `synchronize`, `vendor`). The shared cache is an
absolute host path the command line resolved once at startup, a relative
`ECL_CACHE` included; the vendor store has no path at all and is only ever the
fixed child `vendor` of the retained project handle, opened without following
a final symlink, so a repository-controlled link cannot become a store.
`pkg.store` words receive the opaque `PackageAccess`, name a store by symbol,
and address entries only by validated canonical store keys. Ordinary evaluation
Sessions never construct it, so their package-store words fail closed, and no
absolute store path is ever passed through evaluated code.
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
remain safe. A separate `ControllerGroup` owns the spawning `TaskScope`
membership and execution leases, including cancellation setup before a
supervisor starts. Quiescence requires a retired process group and all leases
to return. Final lease retirement publishes reaped readiness, returns capacity,
and drops the execution reference before scope detachment. Startup rollback
and joined controller jobs use that same boundary. Value and readiness
references remain independent of controller quiescence.
Dropping the last port value cannot orphan a live child, retaining a port
cannot detach it from scope closure, and Session teardown joins controller
jobs before releasing their owners.

Which scope holds that membership can change. A live external resource is a
member of exactly one task scope at a time, and a closed one is a member of
none; the membership a port holds is the whole of what its owning scope owns
on its behalf. `@give` is the only thing that moves one, and it moves it as a
transaction against the scope of a unit being constructed: the destination is
attached while the origin still holds its own membership, so the resource is
never unowned and is never reachable by the new unit before that unit's scope
owns it, and the swap becomes permanent only once the spawn can no longer
fail. A refused or abandoned move detaches the destination's membership and
leaves the origin's untouched. Every port kind implements this, which the heap
requires at compile time so no port can become one that cannot be moved.

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

Execution and shadow inspection consume the same bounded lexical candidate
walk: the written or current scope chain, followed by public core bindings.
Each candidate carries its location and owned binding lease; execution may
also request a captured cell for its cache. Execution consumes the first hit,
while shadow inspection continues through later hits. Qualified loading,
generation pins, and execution authority remain outside that shared walk.

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
- invocation-effect completion checks;
- combinator and isolated-application continuations;
- resumption after qualified loading; and
- transactional boundaries such as `@attempt`, module construction, and
  stateful application.

Each variant owns exactly the fields meaningful in that phase. Transitions
consume one state and construct another, giving continuation modes,
publication phases, and teardown an exhaustive representation.

Declared effects at a module boundary belong to the language invocation, not
to an implementation callback's return. Input contracts are validated before
execution; the frame stack owns output checking until successful completion.
Builtin and native invocations retain a suspended caller beneath that check.
Their current activation is tagged as an invocation rather than source
dispatch, so it carries the calling context without authority to execute the
caller's remaining forms. Driver replacement, parking, and nested quotations
all complete above the same boundary. Loader replay can dispatch only the
retried invocation before returning to it. Failure and cancellation unwind
the boundary without checking successful outputs; native transactions own no
separate effect-check lifecycle.

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

A driver replacement prepares its successor with independent input ownership
before retiring the installed continuation. Installation then cannot fail.
The driver's declared storage policy selects retirement at compile time:
only inline-capable field-owned drivers can release an inline slot, while
address-stable self-owned drivers retire their complete allocated state.

### Boundedness includes retirement

Reclamation competes for scheduler service like evaluation. Final references
detach O(1) retirement records; release cursors later walk the graph. The
scheduler arbitrates between ready execution and retirement so a continuously
ready program cannot strand memory, and a large retired graph cannot make
cancellation latency proportional to the whole graph.
The release domain charges each newly retired owner until its final step,
including while a drainer holds it and across continuation requeues. Above a
backlog watermark, root and worker schedulers withhold ordinary evaluation
slices. Throttled evaluations wait in FIFO order outside the runnable queue.
Each wake owns a reserved slice admission, so newcomers cannot consume it;
outstanding admissions are bounded by the executor count, including the root.
Cancellation withdraws a pressure waiter without acquiring admission. Wait
delivery and terminal task work remain runnable. Root and worker evaluation
use the same admission protocol, and relieving pressure wakes idle executors.
An admitted evaluation makes at least one transition, then yields at evaluator
step boundaries if pressure has risen. Thus in-flight producers cannot keep
allocating for an entire instruction quantum after the backlog fills, and a
reserved admission always carries progress even if pressure rises again.
Already admitted slices and descendants of retired owners may add work; the
watermark bounds accumulation across evaluation turns, not live program data
or the size of an individual retired graph. Retirement is runnable destruction
of unreachable owners, never a wait for an evaluating task to release a borrow.

Retirement has its own object-work quantum, independent of scalar kernel
polling. Backpressure, rather than a ratio between those quanta, prevents
producers from continually outrunning reclamation. Root and worker turns
attempt retirement without waiting behind another drainer, then return to
execution and control; blocking host settlement joins remaining work at the
public turn boundary.

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
Cooperative mode gives deterministic tests and allocation-failure testing
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

Process and network registrations share one keyed wait-list lifetime protocol.
Each registration retains its backend and wake target until consuming
cancellation. Notification delivers the wake while the registration is still
linked under the backend lock, then unlinks it; cancellation cannot release
either owner during delivery. Backend predicates and wake reasons remain local
to the resource whose state they observe.

Process pipes and sockets use the same fixed-capacity byte queue and bounded
transfer drivers. A read owns its active reader through materialization. A
write's encoding and transfer phases each own the ordered write ticket;
completion consumes it and leaves only buffer cleanup. Backend adapters map
resource failures and readiness into those shared transitions, preserving
backend-specific error data and shutdown semantics.

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
cannot be reused while cleanup retains it. The runtime activity group owns one process-cell pin across startup,
all joined jobs, and synchronous cancellation setup. Callback return retires
borrowed activity; backends never receive a separately releasable lease.
Root retirement closes activity admission and carries the completed outcome
until the last activity drains. The runtime then publishes reaped state and
returns live capacity under the cell lock, releases its execution pin, and
detaches scope membership. Startup rollback follows the same transition, so
an outstanding cancellation callback delays capacity return even when no root
thread started. Observing reaped state closes the process owner's lifetime use.
Reaping the group leader therefore
cannot suppress group cleanup or publish scope quiescence while cleanup still
owns process-group authority. Stdin independently transitions
through `open`, `closing`, `closed_cleanly`, or `broken`; `proc.run` cannot
publish success until it observes a terminal stdin state, so a late background
EPIPE remains observable even after all input entered the bounded queue.
The ECL `proc.run` composition uses separate tasks for input, each output
stream, and a registered wait exchange. It observes task completion in arrival
order, so a failed collector or pipe operation cannot be hidden behind a
blocked sibling. A containing task owns the resource, and task cancellation
joins that ownership before the caller sees a deadline or transport failure.
Capture retains bounded chunks and materializes the final byte lists through
ordinary resumable list operations. Deadlines use the scheduler's shared
clock and task wait arbitration.

Every `proc.write` call acquires its nominal write ticket when the call reaches
the primitive, before resumable byte validation and encoding. A driver owns
exactly that ticket until completion or abandonment, so later calls cannot
overtake an earlier call while it yields. An optional process deadline stores
presence separately from its duration: absence is unlimited, while a present
zero duration expires immediately.

### Filesystem operations are bounded drivers over confined handles

Every `fs` word, generic archive extraction, and package-store operation runs
as one scheduler driver. The driver first encodes and validates its inputs
without touching the host: the canonical path grammar, the named root, and a live-operation slot from the owner's quota. It then
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
drivers already use. Process pipes, native callbacks, and network ports use
host-owned controller jobs. Network resource initialization owns socket and
acceptor startup before publication.

Every failure maps a host error to one closed reason vocabulary at the
`filesystem_port` boundary and attaches the operation, root, path (or both
ends of a transfer), and reason to the pending failure, so programs branch on
stable symbols and never on errno names.

### Network resources use registered controllers

Session construction validates network resource limits and creates a network
owner. Requested addresses are parsed and normalized before binding. The owner
derives allocation and retirement from the Session host and outlives retained
resource identities. Workers receive its opaque access capability. Resource
initialization, accept, and socket I/O execute through host-owned controllers.

The common resource service owns controller lanes, scope membership,
cancellation, and joined cleanup. Its network adapter owns typed listener or
connection state. Listener initialization binds the socket and starts its
acceptor before the initialized resource becomes visible. The private prepared
state owns rollback; the accepting state owns the socket, wake descriptors,
and registry entry together. Closing wakes the acceptor and retains that
bundle until controller return. Retirement first detaches the acceptor under
the listener lock, then destroys its storage outside that lock. Terminal publication follows descriptor
closure and quota return, so joined cleanup permits rebinding. An acceptor
failure closes its resource instead of silently restarting it.

Both task scopes and resource-dependent activity groups publish initial
membership and ownership atomically, with storage prepared before locking.
The backend's activity belongs to the service's group. Transferring the service
changes scope ownership without detaching that activity or its cleanup duty.
The service joins the group before cleanup becomes observable. An initialization
failure before group attachment still closes and joins the private backend.

An accept exchange occupies its FIFO lane through cancellation acknowledgement
and controller return. Address operations progress on a separate lane. The
acceptor consumes the kernel backlog only for an outstanding slot with
connection capacity available. Prepared slot storage is allocated outside the
listener lock; linking and admission under the lock do not allocate. A slot's
exhaustive state owns candidate storage through waiting, failure, or closure,
an accepted socket and its reservation, or no payload after consumption. Slot
removal moves that payload out under the lock and reclaims it after unlocking. A waiting
slot consumes no connection capacity. Failed and cancelled handoffs dispose
of their own payload exactly once.

An accepted socket carries its close authority, quota reservation, and immutable
local and peer addresses together. The accept exchange moves it into a new
common resource with no listener dependency. The new service initializes the
connection backend in its own activity group. Until result publication, the
exchange's provisional group owns that resource. `port.result` atomically
publishes it into the receiving scope; failed publication leaves provisional
ownership intact. Closing the listener cannot close a claimed independent
connection or consume a completed exchange's result.

Connection state distinguishes prepared, running, stopping, and terminal
execution. Its controller owns a nonblocking socket, a wake pipe, and bounded
receive and send rings. Producers and readers use readiness capabilities and
hold no worker while parked. One reader may wait per input endpoint. Writer
permits carry FIFO turns, including through resumable byte validation; each
call remains contiguous. Finishing output rejects new writers while preserving
admitted turns and queued bytes, and sends directional EOF only after they
drain. Peer EOF leaves buffered input readable and the reverse direction open.

Graceful shutdown refuses new writes, drains accepted output, and then shuts
the socket down. Abortive closure discards queued output and interrupts polling
through the wake pipe. A transport failure records one terminal reason and
wakes observers; buffered input precedes that failure. Socket retirement closes
descriptors and releases connection capacity only once, independently of the
remaining identity references. No worker holds a descriptor outside this owner.

The acceptor registry lends only live wake pipes. It removes a record before
closing those descriptors. Returning connection capacity wakes quota-blocked
acceptors without taking their listener mutexes. The registry mutex is a leaf
in the lock order; no listener or connection mutex is acquired beneath it.
Session teardown joins resource scopes and settles retained values before
destroying the network owner and its executor.

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
are validated before publication. Core and hosted builtin words use one
complete declaration carrying implementation, spelling, effect, and
documentation. Installation validates that declaration and publishes its
metadata directly; primitive families own their declarations, and kernel
spellings remain owned by their closed operation enums. The source audit
checks semantic spelling conventions across all classified production sources;
documentation completeness and effect syntax are compile-time requirements.

Port operation declarations bind documentation, typed handlers, lanes, and
supported exchange endpoints together. Built-in and extension bridges derive
selectors from the same ABI-independent declaration types. Registered lane
metadata is authoritative; controller invocation does not select a second lane.
Both bridges dispatch the handlers carried by those declarations. Extension
modules generate their selector bindings from the registered declarations;
public names may differ from local endpoint names without coordinating IDs.
Named endpoint references generate private masks before publication, rejecting
resource-owned or repeated endpoints in an operation's exchange set.
Controller endpoint borrows fix their issuing kind, owner, transport, and
direction at acquisition and expire at controller return. Their opaque types
expose only the matching directional operations. Transport outcomes distinguish
EOF, cancellation, and failure; buffered accepted data precedes failure.
A complete controller byte write holds one shared FIFO writer admission across
bounded chunks. A transport-owned wake epoch closes the gap between a pending
write and its blocking wait, including cancellation and predecessor completion.
Structured construction uses one bounded controller driver for typed backends
and the extension bridge. Sending, returning a result, and creating a child
complete their prerequisite validation within that driver. The ABI carries
semantic construction requests, not interpreter or builder advancement states;
cancellation is checked between construction quanta before publication.
Construction requires opaque invocation authority minted by the controller lane. Each public mutation settles its bounded internal work before returning;
worker code cannot construct this controller facade or obtain its advancement
state.

Each Session I/O service owns its registered library instance and a complete
I/O backend.
A module candidate publishes sealed capabilities as literal word
bodies and pins its instance until publication or abandonment. Capability
values retain that identity independently of service cleanup. Module registration
binds the Session I/O backend inside the adapter, so module loading does not
select a resource backend. A generic module-constant provider carries names,
effects, documentation, and sealed values; domain adapters own their declarations
and typed backend access. Registration validates declaration-name uniqueness at
compile time, so one provider cannot replace its own earlier binding during
publication. Retained issuer metadata has no backend discriminator.
Factories register through one opaque opening
interface: bounded configuration validation precedes admission, resumable
openings own partial work, and resource initialization precedes stack publication.
The opening borrows its factory and validated request until retirement. It derives
its scheduler from the calling scope and never receives an interpreter callback.
Bounded diagnostic details retain their values before the request retires.
Built-in controllers do not pass through the extension ABI.

Process resource metadata pins its issuing instance through final reclamation.
Connection metadata carries the same issuer lifetime. Its outgoing transport
distinguishes open, finishing, and EOF: finish closes admission, existing writer
permits preserve their turns, and the controller ends that direction after both
the writer lane and byte ring empty. Incoming progress is independent.
An endpoint projects a declared direction only after validating that instance
and the resource kind. Its retained resource pin grants no scope ownership.
Endpoint adapters register through one semantic interface for built-in and
third-party resources. Registration binds typed adapter callbacks behind an
opaque endpoint selector and one directional endpoint capability. The common
endpoint boundary has no backend-family discriminator: it consumes byte
progress, bounded capacity, readiness, and runtime message queues. ABI
translation belongs to the native adapter. Common byte drivers own validation
and transfer continuations; transports own shared reader exclusion, writer
admission, and FIFO ordering. A write permit pins its transport independently
and consumes both its turn and prepared interface storage on finish or
cancellation. Adapter references are consumed only after successful capability
publication, so failed registration leaves cleanup with the caller.

Resources use the same registered lifecycle interface for every adapter.
The core dispatches close, graceful shutdown, cleanup readiness, and ownership
transfer without inspecting backend types. Registration derives allocation
authority from the resource owner and seals a nominal adapter identity for
adapter-side projection. A resource explicitly grants either direct ownership
or provisional publication support. Atomic handoff consumes only the latter
capability's ownership projection; it has no knowledge of native libraries or
built-in resource layouts. Publication snapshots retain the common resource
handle as well as its adapter reference, so releasing the last language value
cannot invalidate an in-flight handoff.

Registered operation selectors validate their issuing resource before request
validation, then return an admitted exchange or admission readiness through
the same interface for every adapter. Exchange capabilities seal their
adapter identity, own one execution reference, and expose only cancellation,
cleanup, and completion interests. Result observation and claiming go directly
through the common result owner. Neither operation admission nor exchange
observation dispatches on a backend family or uses backend readiness codes.

Package discovery and synchronization are
described in `ENVIRONMENT.md`; they enter the evaluator through the same module
loader and bounded-driver conventions as other sources. Host-side lock and
catalog validation share one inert-record decoder for exact fields, required
values, and owned text; each owner retains its own schema and input limits.

`http.server` shows the shape of a protocol module in source over host ports:
one effect boundary, a single private word that validates and encodes a whole
response before writing it, which the source audit holds to that one call
site. Malformed response values stay ordinary data; malformed wire output is
unreachable.

`net` and `proc` are ECL modules over registered factory, operation, and endpoint
capabilities. Their adapters own host authority and typed socket or process
state. Public words create resources and exchanges through the common vocabulary.
The process `run` composition owns a child scope, drains both outputs alongside
input and completion tasks, applies bounded capture and an optional task deadline,
and joins that scope before returning or raising an error.

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

Port views carry only their value kind. Forwarding retains the opaque heap
identity in the invocation's candidate table, including for a bounded path
inside an aggregate; it grants no backend access or scope ownership authority.
Nested reads and forwarding share one metered path resolver. Candidates remain
invocation-local, while aggregate builders own values retained across yields.
Tasks and modules remain unavailable as native value views.

Heap port capabilities distinguish factories, operation selectors, endpoint
selectors, resources, exchanges, and endpoints. The role is part of the opaque
heap representation and is checked together with backend identity before payload
projection. Only resource and exchange roles carry scope-transfer authority;
borrowed roles retain permitted use and issuer lifetime without acquiring an
independent scope membership. Their constructors cannot supply transfer hooks.
All resource producers use the owning resource constructor.

The structured-message validation boundary retains an immutable root while a
resumable traversal checks each occurrence. Its opaque handle exposes a value
only after the complete traversal succeeds. Words, tasks, and modules are
rejected recursively; nodes, portable scalar/text bytes, and capability
attachments have independent budgets. Repeated references are charged at every
occurrence, so shared aggregate storage cannot bypass transport limits. Failed
validation is terminal, and retirement enqueues both the root and traversal
storage without walking the input synchronously. Validation grants no scope
publication or ownership-transfer authority. Initial requests, messages, and
terminal results all cross this boundary before delivery.

Native port definitions are copied and validated with the module descriptor.
Their identity is the pinned module instance and validated definition index;
names are descriptive metadata. Typed SDK adapters expose backend state only
to controller callbacks. Validated definitions distinguish callable words from
registered factories and selectors. Capability bindings are single-value
quotations in the immutable module image; each capability independently pins
its issuing instance. Repeated lookup shares that identity. Selectors carry
validated resource kinds, fixed operation lanes, and endpoint permissions;
registration rejects duplicate endpoint identities and undeclared permissions
before publishing any binding.

Resource lifecycle dispatch uses an opaque registered semantic interface
(`port_resource.zig`). A borrowed lifecycle capability requires a retained port
identity throughout its use. Each adapter reports joined cleanup through the
common controller service.
Connection cleanup readiness is distinct from send-ring drainage: returning the
last accepted byte to the kernel does not prove the socket controller has joined.
Common close and shutdown drivers park on cleanup readiness for every backend.

HTTP exchanges share controller groups, external scope membership, terminal
failures, and byte transport with ports, without creating language port values or
participating in capability transfer. The Session's opaque HTTP service owns
configuration, admission, and execution authority; inherited runtime context
carries submission access. Each admitted request progresses from preparation to
owned active input, joined response, and consumed response. One host controller
exclusively owns the cancellable I/O future. Scheduler cancellation only changes
state and signals that controller and transport; workers never await or cancel
futures. Joined publication follows both I/O completion and controller join.
Request admission survives all borrowers and bounded response retirement, and
Session teardown joins scope members before destroying the service, TLS inputs,
or reclamation root. The source audit classifies this service with controller
infrastructure and excludes I/O future construction from work-driver steps.

An HTTP invocation captures one absolute scheduler deadline before preparation.
Runnable work and success publication recheck it. Deadline-bearing external
waits install the same timer arbitration before registering readiness, including
already-ready sources; progress never establishes a new deadline. Untimed
external waits retain their existing behavior. Network execution receives owned
bytes and immutable service inputs. Encoded bytes are counted before decompression
and decoded bytes afterward, including redirect bodies; an accounting allocator
bounds backend scratch separately from allocation failure. The evaluator drains
bounded transport during execution into fixed chunks and performs one polled,
exact-size materialization. HTTP retains its own header normalization and ordinary
dictionary/text/byte-list construction, with no port-message node limits.

Registered byte endpoints use a shared bounded transport (`port_bytes.zig`).
An exchange owns its pipes; each attenuated endpoint retains the exchange and
exposes only its declared direction. A sealed descriptor index resolves endpoint
permissions without scanning a module during admission. Pipe construction
precedes admission, so allocation failure cannot publish a partial transport.
Scheduler-facing pipes and blocking controller authority are distinct opaque
capabilities. The shared writer lane orders complete calls, a reader claim
excludes overlapping reads, and explicit transport phases distinguish pending
finish, stable EOF, and failure. Finish preserves admitted writer turns; failure
preserves accepted output unless cleanup is abortive. Cancellation wakes blocked
transport independently of the operation lane. Copies are bounded per turn,
and endpoint drivers use the shared resumable byte-transfer machinery.

Every byte transport uses the same monotonic stream phase for pending finish,
EOF, and failure. Accepted bytes precede its terminal fact. Once established,
EOF or failure cannot be replaced by a later resource error or cleanup. Process
outputs record terminal facts separately, so failure of another pipe cannot
rewrite an output that has finished. TCP receive EOF likewise survives closing
the resource and borrowing another endpoint.

Message endpoints use `port_messages.zig`, with bounded queues and one shared
resource byte budget. Unique delivery ownership is distinct from retained
observation. A validated envelope carries its capacity reservation through
controller receipt and forwarding, preventing an input producer from consuming
the capacity needed to forward that same message. Scheduler receivers prepare
their event and reserve stack capacity before claiming the queue's delivery;
failed preparation leaves queue ownership intact. Budget readiness has its own
mutex and generation, so returning shared capacity never locks another queue.
Terminal failure preserves accepted output; abortive cleanup detaches queued
messages and unclaimed results before retiring their graphs outside publication
locks. This breaks capability cycles through an exchange's own messages or
result. Scope membership remains until controller return and this retirement
handoff have completed.

The `port` vocabulary is an embedded ECL module over the host operations in
`port.core`. Its non-streaming call composition uses the same exchange result
claim and cleanup boundary as explicit callers. It observes the result through
an inline error boundary and closes the exchange before forwarding that outcome,
without introducing a second task-scope owner for returned resources.

Configuration and initial requests cross a bounded validation boundary before
resource creation or operation admission. A nominal validated view grants
retention of their immutable roots. Controllers receive only read-only wire
views with bounded paths, never heap handles or allocator authority. Root
retirement follows the containing resource or exchange lifetime.

Ordinary native words may forward opaque port values. Registered factories,
operations, and endpoints grant resource authority through the common API;
host-owned exchange identities carry suspended controller work independently
of ordinary native invocations.
Cancellation notification is a bounded concurrent callback; initialization,
execution, and cleanup belong to host-owned controllers. Initialization precedes
all lane execution, and cleanup follows every lane executor’s completion.

The native resource owner reserves Session capacity before attaching a provisional
cell to its scope. Initialization cannot run before the heap identity, membership,
and controller lifetime are owned. Opening publishes an initialized resource
to its caller; failed opening closes and joins provisional startup. Ordered lanes use the same FIFO ticket boundary
as network and process writers. A ticket holds its lane through cancellation
until execution acknowledges reuse and returns, or the resource closes. The
operation phase is the authority for dispatch and cancellation; no independent
active-operation pointer can disagree with it. Native
kinds' registered operation selectors declare lanes, validated against a
bounded, state-independent classifier. The
host partitions the total admission budget across lanes so a saturated lane
cannot consume another lane's progress capacity. Declared byte and message
endpoints separate scheduler execution from controller blocking. Every exchange
owns a validated structured request and only its declared endpoint transports.
Every admitted controller operation has a heap exchange identity and independent
scope membership. Retaining or forwarding an exchange preserves its identity
without changing that ownership. Forwarding shares
use, while `@give` moves ownership through the same bounded batch protocol as
resources. Abortive cleanup retains the scope membership until controller
return, including recovery acknowledgement. The lane's post-return transition
settles that membership outside both operation and resource locks. Readiness
registration observes terminal state under the same mutex as notification.
Lane admission starts in a preparation state that owns its FIFO reservation
but cannot execute. Opaque admission storage is allocated before acquiring the
publication lock; capacity rejection retains that uninitialized candidate.
Publishing the exchange handle and scope membership makes
the ticket dispatchable. Cancellation can retire an unpublished reservation,
and a late publication cannot restore it or invoke the backend.
Endpoint borrows retain a tagged resource or exchange lifetime, independently
of the original heap handle. Resource transports are prepared before startup
and survive exchange retirement. Closure wakes their blocked transport, and
the root controller discards queued capabilities before scope detachment so
self-referential resource messages cannot prevent final reclamation.
Controller transport waits borrow a monotonic cancellation latch from their
invocation. Ticket cancellation publishes that latch before notifying resource
queues and their shared budget, without changing persistent endpoint state.
Wait predicates check the latch under the same transport lock as notification;
acknowledgement and controller return still govern lane reuse.

Native controllers build messages through a host-owned construction stack.
Its fixed capacity derives from the message node limit, and its owning heap
buffer retires abandoned roots without a synchronous graph walk. Aggregate
materialization, symbol insertion, validation, and removal of consumed inputs
advance in bounded steps. A completed validator grants publication authority;
partial construction has none. Native code receives neither heap storage nor
allocator authority, and controller return retires its construction state.
Reply endpoint construction projects only a declared, admitted message input
of the current exchange. The resulting sender pins that exchange's identity
without transferring its ownership or extending its operational lifetime.
Native-to-ECL requests therefore use the same bounded message and cancellation
paths as ordinary traffic, with no interpreter re-entry authority.

Native terminal failures distinguish runtime allocation exhaustion from bounded
domain error data. Endpoint transport preserves that distinction through
buffered output and completion; cleanup retains its normal join obligations.
The common result owner carries an immutable terminal fact separately from its
available, claimed, or discarded value. Adapters publish terminal facts only
after controller return and cancellation settlement; ABI errors are translated
before reaching this owner. Completion observation remains repeatable, while
claiming consumes an available terminal value under the receiving scope and
result locks. Replacing or discarding an envelope detaches it under the result
lock and retires it after unlocking. Queue delivery and result claims share one scope-first publication transaction.
Delivery owns observation, output preparation, and claim arbitration; drivers
receive only values, readiness, EOF, or terminal transport failures. A changed
snapshot requires reacquisition. Revoked child authority instead detaches the
undeliverable envelope under the source lock and transfers its cleanup to
bounded retirement after unlocking. It can never leave that envelope available
as a retry candidate. A scope that has begun closing refuses a claim without
consuming its source. The receiving evaluator reserves stack capacity before that
transition, so allocation failure cannot consume a result without publishing it.
The driver's completion carries that reservation with its owned output; only
the evaluator commits it after driver retirement, without further allocation.

An external-child scope owns provisional resources and separately
represents permanent parent dependencies. It admits only external members and
queues the scheduler's bounded cancellation cursor; native controllers cannot
use it to re-enter ECL. Closing pins its parent until every child's final
retirement has propagated. A resource's controller joins its dependency scope
before destroying backend state, while an exchange retains its task-scope
membership until its provisional-child scope is closed.
The permanent dependency attachment owns both its scope membership and its
issuing parent identity. Controller parent-state projection validates that
attachment's module and nominal registered resource identity. Each native kind
owns a distinct identity token pinned by its module instance; names describe
kinds but cannot authorize typed state projection or child creation. Descriptor
validation rejects missing or duplicate tokens. Detaching consumes the attachment only
after child cleanup and controller join; consequently even a child's destruction
callback may use the borrowed native parent state. Independent resources carry
no parent-state authority, and scope transfer preserves the attachment.
Controller failures carry both a terminal cause and an operation or resource
disposition. A resource failure retires its failing exchange before closing
the resource and interrupting dependent children. This preserves the exchange's
accepted output and repeatable terminal observation while preventing subsequent
admission. Cleanup remains asynchronous to the reporting controller and joins
all dependent work before backend destruction.
Exchange retirement follows its own ownership state. Resource closure marks
only outstanding lane members for abort; it cannot retroactively discard a
completed exchange's result or buffered output. Terminal observation, result
claiming, and explicit exchange cleanup therefore remain independent of the
issuing resource's cleanup timing.
Closed group metadata keeps its allocation authority independently of the
scheduler facade: a final controller-retirement pin may outlive task-scope
quiescence, but cannot require scheduler access for destruction.

Validated roots carry a bounded attachment index. Results and queued messages
retain that index with their immutable root. The common resource boundary owns
their publication protocol. Only a resource registered with provisional ownership
support grants the ownership projection needed for atomic publication. Already published
resources remain shared uses when carried by a message or result.
Claims snapshot unpublished child
identities, prepare destination memberships outside locks, and revalidate under
the receiving scope, source, provisional scopes, and child locks. Scope and
child locks have stable identity ordering. A successful transition replaces
all provisional memberships together; stale snapshots grant no destination
authority. Replaced memberships and pins retire after unlocking. Published
capabilities are ordinary shared uses and acquire no new ownership on receipt.
Cancellation carries the issuing scope identity and revalidates its authority
under the resource's lifetime lock. A cursor retaining an old membership cannot
cancel a resource after ownership has moved, even before deferred unlinking.
Only owner-issued creation installs dependency membership; scope transfer cannot
reparent a resource. Heap identity release closes unpublished resources, while
controller, scope, and readiness pins release metadata without changing use.

Graceful shutdown closes operation admission and runs one registered callback
on an independently reserved control lane. Its terminal outcome is stable.
Abortive close interrupts that callback through the same bounded cancellation
path as other backend work. The root joins both operation and control lanes
before cleanup; callback return alone never grants cleanup authority.

Closing cancels active and queued work and prevents further admission. Cancelling
only a queued operation removes that operation. Active cancellation either
closes the cell or invokes its declared recovery protocol. Recovery requires
explicit acknowledgement of reusable state; returning without it closes every
lane. Close overrides recovery and interrupts all active streams. Lane executors
are joined before controller cleanup, and the root controller is joined before
scope detachment.
The internal port executor owns typed jobs and their execution guards. Its
retirement queue accepts only completed jobs and joins each before invoking its
retirement callback; a blocked backend cannot hold up another job's retirement.
Retirement callbacks perform bounded release and never wait for other jobs.
Executor shutdown closes admission and joins the reaper after all callbacks
have returned. Reusable job records are reserved against the owner's resource
limits before cancellation can require them; submission and retirement do not
allocate after preparation. Unused records need no initialization walk. One
additional record covers the retirement callback returning live capacity.
Network polling, process supervision, stream I/O, timers, and native callbacks
all submit typed jobs to this boundary. The native byte ABI is an adapter,
not the representation of built-in operations. Only running jobs receive the
capability to run and await child lanes; worker submission authority cannot
join or destroy executors.
The resource owner joins completed controllers outside ECL workers, so scope
teardown can await cleanup without blocking a worker. Closed heap identities retain
their module pin independently of backend cleanup. Session shutdown closes creation,
settles resources and calls, and releases native images only after those lifetimes.

External resource publication uses the shared scope-attachment boundary.
Membership storage for a batch of up to sixteen resources is prepared before
publication locks are acquired. Under the receiving scope lock, one owner-issued
guard validates the source and commits every membership with the source
ownership transition. Cancellation can observe the whole batch or none of it.
Prepared allocation failure and a changed snapshot release pins outside both
scope and source locks without consuming the delivery. Terminal rejection
removes the undeliverable source instead. Provisional publication is an opaque
service-owned capability with provisional, published, and revoked states.
Revocation is terminal; its retained group pin grants reclamation lifetime only.
The transaction orders group closure against destination attachment and consumes
publication authority on success, before the former owner can cancel through
its replaced membership. An already-published identity is shared without
reattachment, including when an older snapshot's group has since closed. Its
ownership state distinguishes provisional attachment from released ownership;
a release racing initial attachment consumes the eventual membership instead of
resurrecting a closed resource. Attachment and detachment occur outside the
resource lock, while membership publication and backend startup revalidation
use that lock. The creator retains the provisional cell until publication or
backend rollback completes.

All registered resources bind scope ownership and terminal publication to a
runtime-owned activity group. Its provisional state owns startup rollback; successful submission transfers the root into the
executor. Draining owns the root outcome and every outstanding activity until
all jobs have joined and all borrowed callbacks have returned. Only that
transition can publish terminal facts, drop the group's execution pin, and
detach scope memberships. The backend does not supply an independent reference
or a claimed quiescence condition at completion. Retained value references
remain independent of this execution lifetime. A listener's acceptor joins before terminal detachment.

An ordered controller lane binds its resource lock and owns admission,
dispatch, and queue retirement. Opaque prepared storage is allocated outside
the resource lock for both operations and writers. Admission under that lock
validates capacity, initializes and links the node without allocation, and pins
the operation or resource until retirement. Rejected admission retains the
prepared storage for reuse or destruction after unlocking. There is no
externally held unadmitted ticket and no independent
lane argument on cancellation or completion. An operation payload and its ticket share one allocation and reference count.
Queue and observer ownership independently keep that allocation alive; only
their final release destroys the payload and ticket. A writer allocation pins
its admitted resource until both its turn and permit ownership end.

The common controller service validates lane capacity, admits prepared
exchanges, supplies admission readiness, sequences initialization and graceful
shutdown, interrupts outstanding operations, and joins execution and dependent
children before cleanup becomes observable. Adapter state supplies typed
backend work and transport; ABI descriptors and operation codes remain outside
this lifecycle. Admission preparation owns its result and resource pin before
acquiring the publication lock, and rejection retires them after unlocking.

TCP resources use the same service and exchange owners. Their adapters bind
listening sockets during initialization and prepare operation storage before
publication locks. An accepted socket moves with its connection quota into a
provisional child resource owned by the accepting exchange. Claim publication
transfers the resource into the receiving scope without a listener dependency.
The service owns backend activity through a dependent group and joins it before
resource cleanup becomes observable. Both task scopes and dependent groups use
one atomic initial-membership publication boundary.

The process adapter retains an owned parsed specification through asynchronous
initialization. Its pipe and supervision activity belongs to the common
resource's dependent activity group, so transferring the resource transfers
responsibility for joining that activity. Process exit and resource closure
are separate terminal facts: exit settles wait operations, while closure
retires the service and its controller capacity. The issuing process owner
outlives retained resource identities and their reclamation, including after
scope cleanup has joined execution.

A shared exchange owner carries scope membership, cancellation settlement,
provisional child ownership, terminal results, and readiness for registered
controller adapters. The typed adapter supplies execution and transport, while
the exchange owner makes cleanup wait for lane retirement and child closure.
Adapter state contains domain selectors and backend failure data; the shared
owner observes semantic terminal outcomes without knowing their source.

Callback operations expose observation and cancellation handles. The runtime
claims the active turn under the resource and operation locks, lends an
invocation-local running capability, and completes execution only when the
callback returns. Executor ownership is recorded under the operation mutex and
ends before acquiring the resource lock for queue retirement. Cancellation
cannot interrupt a returned callback still awaiting retirement. All execution
state observation, cancellation, and acknowledgement share the operation mutex.
Only that borrowed capability can acknowledge active
cancellation. Callback cancellation can request acknowledgement or resource
closure; it cannot select the synchronous writer-release policy. Queue removal,
successor promotion, notifications, and release of the queue pin follow one
runtime-owned transition. Cancellation and completion still arbitrate under
the locks; ownership prevents callers from completing through another lane
or freeing an operation that its queue still owns.

Network and process writers receive a distinct permit that derives writes,
readiness, and retirement from its admitted resource. Incremental calls retain
the turn until finish or cancellation; retiring a queued writer preserves the
active writer. Retiring an active writer acknowledges that enqueueing has
stopped. Accepted bytes remain resource-owned, and socket duplex progress and
process stdin/stdout/stderr progress continue independently. Flush, process
reaping, stream EOF, and resource cleanup are separate observations. Native
callbacks may still mutate backend state after task cancellation, so their
lane requires acknowledgement and callback return before reuse.

Port capacity lives in factory-owned resource storage, bound to its issuing
owner and release policy. Initialization borrows the cell being constructed;
the factory returns capacity and storage on failure. No separately copyable
quota token exists. Terminal retirement returns the allocation’s capacity once;
retained metadata keeps the allocation and its allocator without retaining quota.
Limits and release milestones remain backend-specific: connection capacity
wakes blocked acceptors, process capacity follows reaping, listener capacity
follows socket closure, and native capacity follows controller joining.
Retaining a closed value does not retain a live-capacity reservation.

Network, process, and native ports share the same scope-transfer boundary.
Backends supply their locked lifetime predicate and ownership location; the
shared protocol prepares destination storage outside publication locks, then
revalidates the origin under the destination scope and resource locks before
linking cancellation authority and recording the transfer together. Rejected
preparation never grants the destination authority, even temporarily. Commit
and rollback consume the resulting ownership transition. Backend
shutdown retains its own execution model while using the common ownership,
readiness, and byte-ring representations.

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
| Filesystem confinement | Public `Session` tests over temporary directories with named-root, symlink-escape, staging-residue, cancellation, and concurrent-winner cases, plus the resolver's own component tests |
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
