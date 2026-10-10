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
