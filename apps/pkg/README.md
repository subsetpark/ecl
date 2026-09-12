# Package application contract

The maintained package application owns project discovery, manifests, lockfiles,
source selection, fetching, installation, verification, and publication. The
interpreter consumes only `ecl.modules`; it never discovers or interprets
`ecl.pkg`, `ecl.lock`, or application recovery records.

## Portable project state

`ecl.pkg` remains the project manifest. The root `ecl.lock` is portable project
data intended for version control. It pins the complete resolved graph: exact
versions, source identities, full Git commits, archive hashes, and dependency
edges. It contains no machine-specific cache paths or generation identifiers.
A fresh checkout containing these two files must reproduce the locked graph.

Ordinary `sync` uses the existing lock without reselecting dependencies or
resolving tags again. A lock incompatible with the manifest is an error;
dependency updates require an explicit update operation. An initial sync may
resolve a graph when no lock exists. Offline sync applies the same selection
rules and fails when the exact pinned artifacts are unavailable.

Each immutable generation contains its own complete resolution snapshot,
installed dependencies, sealed artifacts, and a complete relative module map.
The snapshot supplements the root lock: a running generation always uses its own
snapshot, even while the root lock is being updated. Neither synchronization nor
recovery deletes previous project generations.

## Publication and recovery

All application mutations hold the project's advisory mutation lock. Publication
uses this order:

1. Materialize and validate a private generation against the proposed project
   lock. Publish the complete generation to its absent immutable destination.
2. Atomically create an application recovery record beneath `.ecl/`. It records
   the manifest observed for this operation, the previous root lock and map
   states (including absence), the proposed lock, and the new generation map
   reference. The generation's resolution snapshot must match that proposed
   lock exactly. No root file has changed yet.
3. Atomically publish the root `ecl.lock`.
4. Atomically publish the root `ecl.modules` reference. This is activation.
5. Remove the recovery record.

The two root files cannot be atomically replaced together. Interruption after
step 3 can leave a newer project lock beside the previous active generation.
That generation remains runnable and internally consistent because its map and
resolution snapshot are immutable. A fresh checkout of the newer root lock
reproduces the newer locked graph independently of local recovery state.

Before another mutation, the application validates any recovery record and its
generation, then completes the publication idempotently. It requires the
manifest to match the recorded observation and each root file to match either
its recorded previous state or its proposed state. Unexpected edits, malformed
records, or invalid generations cause an explicit recovery conflict; recovery
must not overwrite unrelated user edits or resolve a different graph. A valid
pending transaction is completed before selecting work for the new command.

Failure before activation leaves the previous runnable generation available.
Cancellation after activation never rolls it back; a surviving recovery record
is completed or removed by the next mutating command. Read-only startup and
verification do not recover, repair, fetch, or write package state. Verification
checks the active generation against its own snapshot and reports any pending
publication or root-lock mismatch separately.

Namespace operations promise atomic visibility under process interruption.
Filesystem or machine crash durability is limited by the host filesystem APIs;
the protocol must not claim a multi-file durable transaction.

The `pkg.transaction` module implements record preparation and idempotent replay
through public filesystem resources. Its caller holds the project mutation lock
and supplies a generation validator with stack effect `(project path --)`.
That validator checks the complete generation, including its runtime map and
artifact seals, without repairing or resolving sources. The transaction module
also independently checks the generation's exact resolution-snapshot bytes.
Records contain data only; recovery never executes their contents. The ordinary
coordination guarantee covers writers participating in the application lock.

## Required publication acceptance

Acceptance must reproduce a fresh checkout from its manifest and root lock,
preserve pinned commits after tags move, and prove that ordinary sync leaves
the locked graph unchanged. Explicit updates must produce a new portable lock.
Interruption at every boundary above must preserve an internally consistent
active generation and allow idempotent recovery without network resolution.
Recovery must reject intervening root or manifest edits, damaged generation
snapshots, and malformed records. Repeated recovery and cancellation after
activation must preserve the committed generation. Vendoring must retain an
equivalent resolution snapshot without making the root lock machine-specific.
