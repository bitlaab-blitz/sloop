# Change Log

All notable changes to this project will be documented in this file.
This project adheres to the [Semantic Version](https://semver.org/) guideline.

## [Version] - yyyy-mm-dd

Here we write upgrading notes and make them as straightforward as possible.

### Added
- A short description for added item 1
- A short description for added item 2
- A short description for added item n

### Changed
- A short description for changed item 1
- A short description for changed item 2
- A short description for changed item n

### Fixed
- A short description for fixed item 1
- A short description for fixed item 2
- A short description for fixed item n


## [v1.5.0] - 2026-10-21

Correctness release — transactional ACL mutations, snapshot-consistent reads
and a clearance override API.

### Added
- `Override` clearance parameter on every ACL-checked operation (`get()`,
  `info()`, `remove()`, `openStream()`, `addOwner()`, `removeOwner()`,
  `addAccess()`, `removeAccess()`) — `.default` keeps the built-in policy,
  `.owner` tightens clearance to owners only, `.access` relaxes it to the
  access list, `.bypass` skips the check entirely

### Changed
- `get()` checks clearance on the lean info view first and only pulls the
  blob for cleared reads — denied reads no longer pay the data transfer
- `incRead()` yields a partial read when the buffer exceeds the remaining
  data instead of failing with `FragmentTooBig`; `null` still marks the end
  of the stream
- Documented the one-instance-per-process contract — the storage engine mode
  is configured globally on `init()` and torn down by `deinit()`

### Fixed
- ACL mutations are transactional — concurrent pooled connections can no
  longer interleave the owner/access snapshot with its rewrite, which
  silently dropped list entries (lost updates) and could defeat the
  last-owner guard
- `remove()` runs its ACL check and delete atomically
- `get()` reads run in a deferred snapshot transaction, keeping the ACL
  decision and the blob fetch on one consistent row state
- `setIndex()` quotes and escapes container names read from `sqlite_master`,
  so a foreign table name cannot break out of the index statement

## [v1.4.0] - 2026-10-20

Connection pooling release — concurrent request handling with per-connection
statement caches and a graceful shutdown path.

### Added
- Internal connection pool — `Sloop.init()` now opens one storage connection
  per worker; each operation checks out an exclusive connection and returns
  it to the pool on completion (LIFO reuse, parked acquirers wake on release)
- `Sloop.shutdown()` — stops the pool, waking every parked acquirer with
  `error.PoolClosed` so in-flight tasks can unwind during shutdown;
  connections already checked out keep working until released
- `error.PoolClosed` — returned by any operation that needs a connection
  after `shutdown()`
- In-memory storage (`null` path) collapses the pool to a single connection,
  since an in-memory database cannot be shared between connections
- Unit tests covering pooled concurrent `put`/`get`/`remove`, ACL edges,
  stream I/O bounds and progressive scan iteration

### Changed
- **BREAKING:** `Sloop.init()` no longer takes the storage engine threading
  mode — it is fixed to `.Serialized` internally, the only configuration safe
  for a cursor or stream that completes its lifecycle on a different worker
  thread than it started on. The signature is now
  `init(io, heap, path, cache, workers)` where `workers = null` opens one
  connection per available CPU core
- `cache` is now applied **per connection** instead of a single shared
  connection
- Every pooled connection sets `PRAGMA busy_timeout = 5000` so
  cross-connection writers in WAL mode retry instead of failing the request
- Prepared statements are compiled once per connection **and** container and
  reused across operations

### Notes
- Scan cursors and open streams hold their pooled connection until closed;
  mutating the same record while its stream is open fails with
  `error.ConnectionIsBusy` — close the stream first (see `docs/usage.md`)

## [v1.3.0] - 2026-10-10

Statement reuse, container scanning and hardening release with Internal code refactoring, better documentation, and Zig-0.17.0 version support.

### Added
- `Bucket.scan()` — progressive row cursor over an object container with a lean
  per-row view (`rowid`, `uuid`, `name`, `size`, `cat`); rows are freed via
  `Row.free()` and the cursor closed via `Cursor.close()`
- `Sloop.checkIntegrity()` — explicit, on-demand integrity check (replaces the
  unconditional check previously run on every `init()`)
- `zig build test` step with a unit test suite covering `put`/`get` roundtrips,
  ACL edges, stream bounds and statement reuse
- In-memory storage support — `Sloop.init()` accepts a `null` path

### Changed
- **BREAKING:** `Sloop.init()` now takes the storage engine threading mode
  (`.SingleThreaded` skips per-call mutexes for single-threaded processes) as
  an additional parameter
- Quill dependency updated to v1.2.0 — statements are compiled once per
  container and reused via the per-container statement cache, removing the
  per-operation recompilation cost
- ACL ownership mutation (`addOwner`/`removeOwner`) and access management are
  backed by a single shared implementation
- `get()` transfers the fetched allocation directly instead of copying it

### Fixed
- `Object.put()` was broken (missing `Io` arguments) and never compiled
- `Object.incWrite()` panicked on integer underflow when the write offset
  exceeded the object size; empty fragments are now a no-op
- `Object.get()` no longer panics when the record disappears between the ACL
  check and the read — it returns `NotFound`
- Adding an existing owner/access entity no longer duplicates the entry
- Removing the last owner of an object is refused (`MissingOwnership`)
- `openStream()` now validates the `rowid` against the `uuid` record,
  rejecting stale rowids after a concurrent remove and re-insert

## [v1.2.1] - 2026-04-01

Sentinel string BUG fix on `setIndex()` for **malloc** to work.

## [v1.2.0] - 2026-02-22

Updated Quill dependency to v1.1.0

## [v1.1.1] - 2025-09-15

Updated Quill dependency to v1.0.0

## [v1.1.0] - 2025-09-13

Minor code changes required for Zig v0.15.1 breaking changes.

## [v1.0.0] - 2025-09-12

Initial bare minimum implementation.
