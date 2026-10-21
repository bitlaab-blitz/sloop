//! # Simple Bucket Storage

const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const quill = @import("quill");
const Uuid = quill.Uuid;
const Quill = quill.Quill;
const Qb = quill.QueryBuilder;
const Builtins = quill.Builtins;
const DateTime = quill.DateTime;
const BlobStream = Quill.BlobStream;

const schema = @import("./schema.zig");


const Str = []const u8;
const StrZ = [:0]const u8;

const Error = error {
    AccessDenied, MissingOwnership, NotFound, MissingEntity, PoolClosed
};

/// # Identifies a Pre-parable Statement for a Container
const Stmt = enum {
    find_info, find_data, insert, remove, update_owner, update_access
};

/// # Lazily Prepared Statements of an Object Container
/// **Remarks:** Compiled once per connection and container, and reused
/// across operations (quill's `CRUD` recycles the statement automatically
/// on every operation)
const StmtCache = struct {
    find_info: ?Quill.CRUD = null,
    find_data: ?Quill.CRUD = null,
    insert: ?Quill.CRUD = null,
    remove: ?Quill.CRUD = null,
    update_owner: ?Quill.CRUD = null,
    update_access: ?Quill.CRUD = null,
};

io: Io,
heap: Allocator,
shared: *Shared,

const Self = @This();

/// # Synchronization State of the Connection Pool
/// **Remarks:** Heap-allocated so pooled connections can hold a stable
/// pointer back to the pool regardless of where the `Self` handle lives
const Shared = struct {
    mutex: Io.Mutex = Io.Mutex.init,
    signal: Io.Condition = Io.Condition.init,
    pool: []Conn = &.{},
    free_list: []usize = &.{},
    top: usize = 0,
    closing: bool = false,

    /// # Takes an Exclusive Connection Out of the Pool
    /// **Remarks:** Parks the caller while every connection is checked out.
    /// A connection must never be acquired twice within one operation —
    /// nesting deadlocks the pool once every connection is out.
    /// Returns `PoolClosed` once `close()` has run, unwinding the caller so
    /// a shutdown signal never strands a parked worker
    fn acquire(self: *Shared, io: Io) Error!*Conn {
        self.mutex.lockUncancelable(io);

        while (self.top == 0 and !self.closing) {
            self.signal.waitUncancelable(io, &self.mutex);
        }

        if (self.closing) {
            self.mutex.unlock(io);
            return Error.PoolClosed;
        }

        self.top -= 1;
        const conn = &self.pool[self.free_list[self.top]];
        self.mutex.unlock(io);
        return conn;
    }

    /// # Returns a Connection Back to the Pool
    fn release(self: *Shared, io: Io, conn: *Conn) void {
        self.mutex.lockUncancelable(io);

        self.free_list[self.top] = conn.idx;
        self.top += 1;
        self.signal.signal(io);

        self.mutex.unlock(io);
    }

    /// # Stops the Pool: Every Future Acquisition Fails with `PoolClosed`
    /// **Remarks:** Broadcasts so every parked acquirer wakes and unwinds —
    /// connections already checked out keep working until they are released
    fn close(self: *Shared, io: Io) void {
        self.mutex.lockUncancelable(io);

        self.closing = true;
        self.signal.broadcast(io);

        self.mutex.unlock(io);
    }
};

/// # Explicit Transaction on a Pooled Connection
/// **Remarks:** Serializes multi-statement operations (e.g., an ACL read
/// followed by its update) so concurrent pool connections cannot interleave
/// them — `BEGIN IMMEDIATE` takes the write lock up front while WAL snapshot
/// isolation keeps every read of one operation on a single consistent view.
/// `busy_timeout` applies while acquiring the write lock
const Txn = struct {
    db: *Quill,

    /// # Read-Only Snapshot Transaction (Deferred)
    /// **Remarks:** WAL readers coexist with concurrent writers — use when
    /// the operation only reads and needs a consistent multi-query view
    fn read(db: *Quill) !Txn {
        var result = try db.exec("BEGIN DEFERRED;");
        result.destroy();
        return .{.db = db};
    }

    /// # Write Transaction (Immediate)
    /// **Remarks:** Takes the write lock up front so the read-modify-write
    /// sequence cannot be interleaved by another pooled connection
    fn write(db: *Quill) !Txn {
        var result = try db.exec("BEGIN IMMEDIATE;");
        result.destroy();
        return .{.db = db};
    }

    fn commit(self: *Txn) !void {
        var result = try self.db.exec("COMMIT;");
        result.destroy();
    }

    fn rollback(self: *Txn) void {
        var result = self.db.exec("ROLLBACK;") catch return;
        result.destroy();
    }
};

/// # Pooled Storage Connection with its Own Statement Cache
/// **Remarks:** The connection is exclusively owned between checkout and
/// release, so its statement cache is used without any synchronization.
/// Since sloop operations never suspend, an operation always runs to
/// completion on the connection it checked out — even when the underlying
/// scheduler migrates the request between worker threads
const Conn = struct {
    db: Quill,
    heap: Allocator,
    shared: *Shared,
    io: Io,
    idx: usize,
    caches: std.StringHashMap(StmtCache),

    /// # Returns the Connection Back to its Pool
    fn release(self: *Conn) void {
        self.shared.release(self.io, self);
    }

    /// # Returns the Prepared Statement Interface for the Given Operation
    /// **Remarks:** Statements are compiled once per connection and container
    /// and kept alive for reuse — quill's `CRUD` recycles the statement
    /// automatically on every operation, removing the per-call recompilation
    /// cost. The cache is only touched while the connection is checked out,
    /// so no synchronization is needed here
    fn stmt(self: *Conn, comptime kind: Stmt, comptime c_name: Str) !*Quill.CRUD {
        const sql = comptime switch (kind) {
            .find_info => blk: {
                var sql = Qb.Record.find(schema.ViewInfo, schema.Filter, c_name);
                sql.when(&.{sql.filter("uuid", .@"=", null)});
                break :blk sql.statement();
            },
            .find_data => blk: {
                var sql = Qb.Record.find(schema.ViewData, schema.Filter, c_name);
                sql.when(&.{sql.filter("uuid", .@"=", null)});
                break :blk sql.statement();
            },
            .insert => blk: {
                var sql = Qb.Record.create(schema.Model, c_name, .Default);
                break :blk sql.statement();
            },
            .remove => blk: {
                var sql = Qb.Record.remove(schema.Filter, c_name, .Exact);
                sql.when(&.{sql.filter("uuid", .@"=", null)});
                break :blk sql.statement();
            },
            .update_owner => blk: {
                var sql = Qb.Record.update(
                    schema.ModelOwner, schema.Filter, c_name, .Exact
                );

                sql.when(&.{sql.filter("uuid", .@"=", null)});
                break :blk sql.statement();
            },
            .update_access => blk: {
                var sql = Qb.Record.update(
                    schema.ModelAccess, schema.Filter, c_name, .Exact
                );

                sql.when(&.{sql.filter("uuid", .@"=", null)});
                break :blk sql.statement();
            }
        };

        const gop = try self.caches.getOrPut(c_name);
        if (!gop.found_existing) gop.value_ptr.* = .{};

        const slot = &@field(gop.value_ptr.*, @tagName(kind));
        if (slot.*) |*prepared| return prepared;

        slot.* = try self.db.prepare(sql);
        return &slot.*.?;
    }
};

/// # Initializes Sloop with Default Configuration
/// - `path` - Bucket storage file path (e.g., `bucket.db`), or **null** for
///   an in-memory storage
/// - `cache` - Underlying storage engine cache size in MB, **per connection**
/// - `workers` - Connection pool size; **null** means one connection per
///   available CPU core, otherwise the given count. Match the executor
///   worker count so every concurrent request gets its own connection
///   without waiting
///
/// **Remarks:** Run `checkIntegrity()` separately (e.g., on first open or
/// periodically) as it is an O(database size) operation. In-memory storage
/// (`path = null`) cannot be shared between connections, so the pool
/// collapses to a single connection
///
/// **WARNING:** Only one `Sloop` instance may live per process — `Quill.init`
/// configures the storage engine mode globally and a second `deinit()` would
/// tear it down under the remaining instance
pub fn init(
    io: Io,
    heap: Allocator,
    path: ?StrZ,
    comptime cache: u16,
    workers: ?u16
) !Self {
    // - The storage engine mode is fixed at `.Serialized` and configured once
    //   per process: the pool hands each connection to whichever worker is
    //   free, so a cursor or stream may complete its lifecycle on a different
    //   worker thread than it started on — serialized mode is the only
    //   configuration that makes such sequential cross-thread use safe
    // - NOTE: this is a process-global configuration, not a per-instance one
    try Quill.init(.Serialized);
    errdefer Quill.deinit();

    const cpu_threads: u16 = @intCast(try std.Thread.getCpuCount());
    const threads = workers orelse cpu_threads;
    if (threads == 0) @panic("Need at Least One or More Connections!");

    // In-memory storage cannot be shared between connections — the pool
    // collapses to a single connection so every thread sees the same tables
    const count: usize = if (path == null) 1 else threads;

    const shared = try heap.create(Shared);
    errdefer heap.destroy(shared);

    const pool = try heap.alloc(Conn, count);
    errdefer heap.free(pool);

    var opened: usize = 0;
    errdefer for (pool[0..opened]) |*conn| {
        conn.caches.deinit();
        conn.db.close();
    };

    for (pool, 0..) |*conn, idx| {
        conn.* = .{
            .db = undefined,
            .heap = heap,
            .shared = shared,
            .io = io,
            .idx = idx,
            .caches = std.StringHashMap(StmtCache).init(heap)
        };

        conn.db = try Quill.open(heap, path, .All);
        opened += 1;

        try Builtins.Pragma.optimize(&conn.db);
        try Builtins.Pragma.setJournal(&conn.db, .WAL);
        try Builtins.Pragma.setSynchronous(&conn.db, .NORMAL);
        try Builtins.Pragma.setCache(&conn.db, -(@as(i32, cache) * 1024));

        // Cross-connection writers collide in WAL mode; retry instead of
        // failing the request
        var timeout = try conn.db.exec("PRAGMA busy_timeout = 5000;");
        defer timeout.destroy();
    }

    const free_list = try heap.alloc(usize, count);
    errdefer heap.free(free_list);

    for (0..count) |idx| free_list[idx] = count - 1 - idx; // LIFO reuse

    shared.* = .{
        .pool = pool, .free_list = free_list, .top = count
    };

    return .{.io = io, .heap = heap, .shared = shared};
}

/// # Checks Internal Consistency of the Storage
/// **Remarks:** Cost is O(database size), avoid on every open. Returns
/// `FailedIntegrityChecks` when the database file is corrupted
pub fn checkIntegrity(self: *Self) !void {
    const conn = try self.acquire();
    defer conn.release();

    try Builtins.Pragma.checkIntegrity(&conn.db);
}

/// # Takes an Exclusive Storage Connection Out of the Pool
/// **Remarks:** The connection must be returned via `release()` before the
/// operation ends — long-lived handles (cursors, streams) hold the checkout
/// until they are closed. Returns `PoolClosed` after `shutdown()`
fn acquire(self: *Self) Error!*Conn {
    return self.shared.acquire(self.io);
}

/// # Stops the Connection Pool (Shutdown Aid)
/// **Remarks:** Wakes every worker parked in `acquire()` with `PoolClosed`,
/// letting their tasks unwind so the executor workers can reach the exit
/// handshake. In-flight operations finish normally on their own connection.
/// Call once the shutdown signal has landed; `deinit()` calls it too, but
/// by then the executor must already be quiesced
pub fn shutdown(self: *Self) void {
    self.shared.close(self.io);
}

/// # Destroys the Sloop Instance
/// **Remarks:** Every connection must be back in the pool when this runs —
/// closing a connection that an in-flight operation still holds is a
/// use-after-free
pub fn deinit(self: *Self) void {
    self.shutdown();

    const shared = self.shared;

    for (shared.pool) |*conn| {
        var it = conn.caches.iterator();
        while (it.next()) |entry| {
            inline for (@typeInfo(StmtCache).@"struct".field_names) |f_name| {
                if (@field(entry.value_ptr.*, f_name)) |*prepared| {
                    prepared.destroy();
                }
            }
        }

        conn.caches.deinit();
        conn.db.close();
    }

    self.heap.free(shared.free_list);
    self.heap.free(shared.pool);
    self.heap.destroy(shared);
    Quill.deinit();
}

/// # Creates Indexes on Object Containers
/// **Remarks:** SQLite index names are database-global, so each container
/// gets its own uniquely named index — a shared name would make
/// `IF NOT EXISTS` silently skip every container after the first
/// # Doubles Double-Quotes of a SQL Identifier for Quoting
/// **Remarks:** Returns the escaped text **without** surrounding quotes —
/// call sites embed it inside their own quote pairs. Container names are
/// normally comptime literals, but indexes are built from names read out of
/// `sqlite_master` — quoting plus escaping keeps any foreign table name from
/// breaking out of the statement
fn escapeSqlIdent(self: *Self, name: Str) ![]u8 {
    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(self.heap);

    try out.ensureTotalCapacity(self.heap, name.len * 2);

    for (name) |c| {
        out.appendAssumeCapacity(c);
        if (c == '"') out.appendAssumeCapacity('"');
    }

    return out.toOwnedSlice(self.heap);
}

pub fn setIndex(self: *Self) !void {
    const conn = try self.acquire();
    defer conn.release();

    var containers = self.bucket();
    const items = try containers.listWith(conn);
    defer containers.freeList(items);

    for (items) |item| {
        const ident = try self.escapeSqlIdent(item);
        defer self.heap.free(ident);

        const fmt_str =
            "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_uuid_{s}\" ON \"{s}\"(\"uuid\");";

        const sql = try fmt.allocPrintSentinel(self.heap, fmt_str, .{ ident, ident }, 0);
        defer self.heap.free(sql);

        var result = try conn.db.exec(sql);
        defer result.destroy();

        std.debug.assert(result.count() == 0);
    }
}

/// # Return Bucket Interface
pub fn bucket(self: *Self) Bucket { return .{.parent = self}; }

/// # Returns Object Interface
pub fn object(self: *Self) Object { return .{.parent = self}; }

const Bucket = struct {
    parent: *Self,

    /// # Creates a New Object Container
    /// - `name` - Name of the object container (e.g., `user_img`)
    pub fn create(self: *Bucket, comptime name: Str) !void {
        const sql = comptime Qb.Container.create(schema.Model, name, .RowId);

        const conn = try self.parent.acquire();
        defer conn.release();

        var result = try conn.db.exec(sql);
        result.destroy();
    }

    /// # Removes the Object Container
    /// - `name` - Name of the object container (e.g., `user_img`)
    pub fn remove(self: *Bucket, comptime name: Str) !void {
        const conn = try self.parent.acquire();
        defer conn.release();

        try Builtins.Container.delete(&conn.db, name, .Retain);
    }

    /// # Retrieves Object Container Names
    /// **WARNING:** Return value must be freed by calling `freeList()`.
    pub fn list(self: *Bucket) ![]const Str {
        const conn = try self.parent.acquire();
        defer conn.release();

        return self.listWith(conn);
    }

    /// # Retrieves Object Container Names on an Already Checked Out
    /// Connection
    /// **Remarks:** Intended for internal use only
    fn listWith(self: *Bucket, conn: *Conn) ![]const Str {
        const heap = self.parent.heap;

        var tables: ArrayList(Str) = .empty;
        errdefer tables.deinit(heap);

        const sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';";

        var result = try conn.db.exec(sql);
        defer result.destroy();

        try tables.ensureTotalCapacity(heap, result.count());

        while (result.next()) |col| {
            const data = col[0].data;
            const item = try heap.alloc(u8, data.len);
            @memcpy(item, data);
            tables.appendAssumeCapacity(item);
        }

        return try tables.toOwnedSlice(heap);
    }

    /// # Frees the Object Container Names
    pub fn freeList(self: *Bucket, items: []const Str) void {
        for (items) |item| self.parent.heap.free(item);
        self.parent.heap.free(items);
    }

    /// # Scans Object Records of the Container (Progressive Retrieval)
    /// - `name` - Name of the object container (e.g., `user_img`)
    ///
    /// **Remarks:** Returns a cursor over every record of the container,
    /// ordered by implicit `rowid`. Retrieved rows exclude the `data` blob
    /// and JSON fields for cheap iteration. Intended usage:
    /// ```
    /// var cursor = try bucket.scan("user_img");
    /// defer cursor.close();
    ///
    /// while (try cursor.next()) |row| {
    ///     defer row.free();
    ///     // row.value().uuid, name, size, cat ...
    /// }
    /// ```
    ///
    /// **WARNING:** Each row must be freed via `Row.free()`, and the cursor
    /// closed via `Cursor.close()` — including on early loop exits.
    pub fn scan(self: *Bucket, comptime name: Str) !Cursor {
        const conn = try self.parent.acquire();
        errdefer conn.release();

        const sql = comptime blk: {
            var sql = Qb.Record.find(schema.ViewScan, schema.Filter, name);
            break :blk sql.statement();
        };

        var crud = try conn.db.prepare(sql);
        errdefer crud.destroy();

        // The connection stays checked out until the cursor is closed
        return .{.crud = crud};
    }

    /// # Row of a Scan Result
    /// **WARNING:** Must be freed via `free()` before the cursor is closed.
    pub const Row = struct {
        rec: schema.ViewScan,
        crud: Quill.CRUD,

        /// # Returns a Copy of the Retrieved Record
        pub fn value(self: *const Row) schema.ViewScan {
            return self.rec;
        }

        /// # Frees Up Heap Allocated Memories of the Row
        /// **Remarks:** Takes the row by value so it can be called on the
        /// `const` payload capture of a `while` loop
        pub fn free(row: Row) void {
            var self = row;
            self.crud.free(self.rec);
        }
    };

    /// # Progressive Cursor over the Object Container
    /// **Remarks:** Yields rows via progressive `readOne()` — quill recycles
    /// the statement only when it is not mid-execution, so iteration advances
    /// instead of rewinding
    ///
    /// **WARNING:** Must be closed via `close()`, even on early loop exits
    pub const Cursor = struct {
        crud: Quill.CRUD,

        /// # Retrieves the Next Object Record
        /// - Returns **null** when no row remains
        ///
        /// **WARNING:** Retrieved row must be freed via `Row.free()`
        pub fn next(self: *Cursor) !?Row {
            const rec = try self.crud.readOne(schema.ViewScan, null);
            return if (rec) |r| .{.rec = r, .crud = self.crud} else null;
        }

        /// # Closes the Cursor and Returns its Connection to the Pool
        pub fn close(self: *Cursor) void {
            const conn: *Conn = @fieldParentPtr("db", self.crud.db);
            self.crud.destroy();
            conn.release();
        }
    };
};

pub const Object = struct {
    parent: *Self,

    /// # Access Levels Granted by the ACL
    const Access = enum { none, read, write };

    /// # Clearance Scope Override for ACL-Checked Operations
    /// - `default` - Keeps the built-in clearance policy of the operation
    /// - `owner` - Restricts clearance to owners only
    /// - `access` - Extends clearance to access-list entities
    /// - `bypass` - Skips the clearance check entirely (**WARNING:** grants
    ///   full owner-level clearance to any caller)
    pub const Override = enum {
        default,
        owner,
        access,
        bypass,

        /// # Resolves the Override Against the Built-In Clearance Policy
        /// **Remarks:** Intended for internal use only
        fn ownerOnly(self: Override, default: bool) bool {
            return switch (self) {
                .default => default,
                .owner => true,
                .access => false,
                .bypass => unreachable // Callers must skip clearance first
            };
        }
    };

    /// # Puts a New Object into the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `name` - Name of the object (e.g., `profile_img.jpg`)
    /// - `data` - Octet data of the given object
    /// - `owner` - One or more entity, (e.g., `&.{}`) for public uploads
    /// - `access` - One or more entity, (e.g., `&.{}`) for public access
    pub fn put(
        self: *Object,
        comptime c_name: Str,
        name: Str,
        data: Str,
        owner: []const Str,
        access: []const Str
    ) ![36]u8 {
        const uuid = try Uuid.toUrn(&(try Uuid.new(self.parent.io)));

        const rec = schema.Model {
            .uuid = .{.text = &uuid},
            .name = .{.text = name},
            .data = .{.blob = data},
            .owner = .{.text = owner},
            .access = .{.text = access},
            .size = @intCast(data.len),
            .cat = DateTime.timestamp(self.parent.io)
        };

        const conn = try self.parent.acquire();
        defer conn.release();

        const crud = try conn.stmt(.insert, c_name);
        crud.exec(rec, null, null) catch |err| {
            crud.reset() catch {};
            return err;
        };
        return uuid;
    }

    /// # Retrieves the Object Data from the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `access` - Either an entity or **null** for public object
    /// - `override` - Clearance override (see `Override`)
    ///
    /// **WARNING:** Return value must be freed by the caller.
    pub fn get(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        access: ?Str,
        override: Override
    ) !Str {
        const conn = try self.parent.acquire();
        defer conn.release();

        var txn = try Txn.read(&conn.db);
        errdefer txn.rollback();

        // The ACL is checked on the lean info view first — the blob is only
        // pulled for cleared reads, so denied reads never pay the transfer
        var session = try authorize(
            conn, c_name, uuid, access, override, false
        );
        defer session.free();

        const crud = try conn.stmt(.find_data, c_name);
        const filter = schema.Filter {.uuid = uuid};

        var result = crud.readOne(schema.ViewData, filter) catch |err| {
            crud.reset() catch {};
            return err;
        };

        const rec = result orelse return Error.NotFound;

        // Transfers the heap-owned blob, avoiding a redundant copy
        const out = rec.data;
        result.?.data = "";

        crud.free(result);
        crud.reset() catch {};

        try txn.commit();
        return out;
    }

    /// # Shared ACL List Mutation (Owners and Access)
    /// **Remarks:** Intended for internal use only
    fn mutateList(
        self: *Object,
        comptime T: type,
        comptime field: Str,
        comptime c_name: Str,
        uuid: Str,
        owner: Str,
        entity: Str,
        comptime erase: bool,
        override: Override
    ) !void {
        const heap = self.parent.heap;

        const conn = try self.parent.acquire();
        defer conn.release();

        // The ACL snapshot and the list rewrite must commit atomically —
        // otherwise concurrent pool connections interleave read and write,
        // and the last writer clobbers the other's list entry
        var txn = try Txn.write(&conn.db);
        errdefer txn.rollback();

        var session = try authorize(
            conn, c_name, uuid, owner, override, true
        );
        defer session.free();

        var list: ArrayList(Str) = .empty;
        defer list.deinit(heap);

        var found: bool = false;
        for (@field(session.rec, field)) |v| {
            if (mem.eql(u8, v, entity)) {
                found = true;
                continue;
            }

            try list.append(heap, v);
        }

        if (erase) {
            if (!found) return Error.MissingEntity;

            // Refuses ownerless objects
            if (comptime mem.eql(u8, field, "owner")) {
                if (list.items.len == 0) return Error.MissingOwnership;
            }
        } else {
            if (found) return; // Already present — no update needed
            try list.append(heap, entity);
        }

        const filter = schema.Filter {.uuid = uuid};

        const crud = try conn.stmt(
            if (comptime mem.eql(u8, field, "owner"))
                Stmt.update_owner
            else
                Stmt.update_access,
            c_name
        );

        var rec: T = undefined;
        @field(rec, field) = .{.text = list.items};

        crud.exec(rec, filter, null) catch |err| {
            crud.reset() catch {};
            return err;
        };

        try txn.commit();
    }

    /// # Adds Owner to an Object
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `owner` - Existing owner entity string
    /// - `entity` - New owner entity string
    /// - `override` - Clearance override (see `Override`)
    pub fn addOwner(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        owner: Str,
        entity: Str,
        override: Override
    ) !void {
        return self.mutateList(
            schema.ModelOwner,
            "owner",
            c_name,
            uuid,
            owner,
            entity,
            false,
            override
        );
    }

    /// # Removes Owner from an Object
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `owner` - Existing owner entity string
    /// - `entity` - Existing owner entity string
    /// - `override` - Clearance override (see `Override`)
    pub fn removeOwner(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        owner: Str,
        entity: Str,
        override: Override
    ) !void {
        return self.mutateList(
            schema.ModelOwner,
            "owner",
            c_name,
            uuid,
            owner,
            entity,
            true,
            override
        );
    }

    /// # Adds Access to an Object
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `owner` - Existing owner entity string
    /// - `entity` - New access entity string
    /// - `override` - Clearance override (see `Override`)
    pub fn addAccess(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        owner: Str,
        entity: Str,
        override: Override
    ) !void {
        return self.mutateList(
            schema.ModelAccess,
            "access",
            c_name,
            uuid,
            owner,
            entity,
            false,
            override
        );
    }

    /// # Removes Access from an Object
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `owner` - Existing owner entity string
    /// - `entity` - Existing access entity string
    /// - `override` - Clearance override (see `Override`)
    pub fn removeAccess(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        owner: Str,
        entity: Str,
        override: Override
    ) !void {
        return self.mutateList(
            schema.ModelAccess,
            "access",
            c_name,
            uuid,
            owner,
            entity,
            true,
            override
        );
    }

    /// # Removes the Object from the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `access` - Either an entity or **null** for public object
    /// - `override` - Clearance override (see `Override`)
    pub fn remove(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        access: ?Str,
        override: Override
    ) !void {
        const conn = try self.parent.acquire();
        defer conn.release();

        var txn = try Txn.write(&conn.db);
        errdefer txn.rollback();

        var session = try authorize(
            conn, c_name, uuid, access, override, true
        );
        defer session.free();

        const crud = try conn.stmt(.remove, c_name);
        const filter = schema.Filter {.uuid = uuid};

        crud.remove(filter, null) catch |err| {
            crud.reset() catch {};
            return err;
        };

        try txn.commit();
    }

    /// # Generic Fetch Result (Single Query)
    /// **Remarks:** Intended for internal use only. The underlying statement
    /// belongs to the shared per-container cache — `free()` releases the
    /// record memory and recycles the statement, it must **not** be destroyed
    fn Fetch(comptime T: type) type {
        return struct {
            rec: T,
            crud: Quill.CRUD,

            /// # Returns a Copy of the Retrieved Record
            pub fn value(self: *const @This()) T {
                return self.rec;
            }

            /// # Releases the Record Memory
            /// **Remarks:** The statement was already recycled by `fetch()`
            /// before this handle was returned, so `free()` only releases the
            /// heap-owned record memory — it never touches the shared
            /// statement of a pooled connection
            /// **WARNING:** Must be called exactly once
            pub fn free(self: *@This()) void {
                self.crud.free(self.rec);
            }
        };
    }

    const Info = Fetch(schema.ViewInfo);

    /// # Retrieves the Object Information from the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `access` - Either an entity or **null** for public object
    /// - `override` - Clearance override (see `Override`)
    ///
    /// **Remarks:** Only owners and public objects are permitted
    ///
    /// **WARNING:** Return value must be freed by calling `Info.free()`.
    pub fn info(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        access: ?Str,
        override: Override
    ) !Info {
        const conn = try self.parent.acquire();
        defer conn.release();

        return authorize(conn, c_name, uuid, access, override, true);
    }

    /// # Fetches the ACL-Validated Object Record (Single Query)
    /// **Remarks:** Intended for internal use only
    fn authorize(
        conn: *Conn,
        comptime c_name: Str,
        uuid: Str,
        access: ?Str,
        override: Override,
        owner_default: bool
    ) !Info {
        var session = try fetch(conn, c_name, uuid);
        errdefer session.free();

        if (override != .bypass) {
            const level = clearance(
                session.rec, access, override.ownerOnly(owner_default)
            );
            if (level == .none) return Error.AccessDenied;
        }

        return session;
    }

    /// # Fetches the ACL-Validated Object Record (Single Query)
    /// **Remarks:** Intended for internal use only. The statement is
    /// recycled right after the fetch — the returned session only carries
    /// heap-owned record memory, so holding it never keeps the underlying
    /// statement busy for other operations
    fn fetch(
        conn: *Conn,
        comptime c_name: Str,
        uuid: Str
    ) !Fetch(schema.ViewInfo) {
        const crud = try conn.stmt(.find_info, c_name);

        const filter = schema.Filter {.uuid = uuid};
        const result = crud.readOne(schema.ViewInfo, filter) catch |err| {
            crud.reset() catch {};
            return err;
        };

        const rec = result orelse {
            crud.reset() catch {};
            return Error.NotFound;
        };

        // Recycles the shared statement immediately — the record data is
        // heap-owned, so it stays valid after the reset
        crud.reset() catch {};
        return .{.rec = rec, .crud = crud.*};
    }

    /// # Evaluates the Access Level for the Given Record
    /// **Remarks:** Intended for internal use only
    fn clearance(
        rec: anytype,
        access: ?Str,
        owner_only: bool
    ) Access {
        if (access) |v| {
            for (rec.owner) |name| {
                if (mem.eql(u8, v, name)) return .write;
            }

            // Owners implicitly hold read access
            if (!owner_only) {
                for (rec.access) |name| {
                    if (mem.eql(u8, v, name)) return .read;
                }
            }
        } else if (rec.owner.len == 0 and rec.access.len == 0) {
            return .read; // Public object
        }

        return .none;
    }

    /// # Provisions a New Object for Incremental I/O
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `name` - Name of the object (e.g., `profile_img.jpg`)
    /// - `size` - Provisional data size of the given object
    /// - `owner` - One or more entity, (e.g., `&.{}`) for public uploads
    /// - `access` - One or more entity, (e.g., `&.{}`) for public access
    pub fn provision(
        self: *Object,
        comptime c_name: Str,
        name: Str,
        size: u32,
        owner: []const Str,
        access: []const Str,
    ) ![36]u8 {
        const uuid = try Uuid.toUrn(&(try Uuid.new(self.parent.io)));

        const rec = schema.ModelProvision {
            .uuid = .{.text = &uuid},
            .name = .{.text = name},
            .data = .{.blob_len = @intCast(size)},
            .owner = .{.text = owner},
            .access = .{.text = access},
            .size = @intCast(size),
            .cat = DateTime.timestamp(self.parent.io)
        };

        const conn = try self.parent.acquire();
        defer conn.release();

        const crud = try conn.stmt(.insert, c_name);
        crud.exec(rec, null, null) catch |err| {
            crud.reset() catch {};
            return err;
        };
        return uuid;
    }

    /// # Opens Object Streaming
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `rid` - RowId of the object (must match the `uuid` record)
    /// - `uuid` - UUID of the object
    /// - `access` - Either an entity or **null** for public object
    /// - `override` - Clearance override (see `Override`)
    ///
    /// **Remarks:** Streams open as **Read-Write** only for owners, otherwise
    /// **Read-Only** (access entities and public objects included). The `rid`
    /// is validated against the `uuid` record, rejecting stale rowids (e.g.,
    /// after a concurrent remove and re-insert) and narrowing the ACL check to
    /// stream open race window.
    ///
    /// **WARNING:** Return value must be freed by calling `closeStream()`
    pub fn openStream(
        self: *Object,
        comptime c_name: StrZ,
        rid: i64,
        uuid: Str,
        access: ?Str,
        override: Override
    ) !BlobStream {
        const conn = try self.parent.acquire();
        errdefer conn.release();

        var session = try fetch(conn, c_name, uuid);
        defer session.free();

        // Bypassed streams open as read-write — full owner-level clearance
        var level: Access = .write;
        if (override != .bypass) {
            level = clearance(session.rec, access, override.ownerOnly(false));
            if (level == .none) return Error.AccessDenied;
        }

        // Rejects stale rowids (e.g., after a concurrent remove and re-insert)
        if (session.rec.rowid != rid) return Error.NotFound;

        // No transaction here: an open blob handle holds an implicit write
        // transaction until it is closed, so a write lock taken now would
        // block every other writer for the whole stream lifetime. A row
        // removed between the check and the open simply fails the blob open
        // on the vanished rowid — it cannot open a foreign record silently
        // unless that rowid is deleted *and* reused within this window
        return BlobStream.open(
            &conn.db, c_name, "data", rid,
            if (level == .write) .ReadWrite else .Read
        );
    }

    /// # Closes Object Streaming and Returns the Connection to the Pool
    pub fn closeStream(blob: *BlobStream) void {
        const conn: *Conn = @fieldParentPtr("db", blob.db);
        blob.close();
        conn.release();
    }

    /// # Writes Incremental Data to the Object
    /// - `part` - Data fragment for incremental write
    /// - `pos` - Offset position from where the part will be written
    pub fn incWrite(stream: *BlobStream, part: Str, pos: usize) !void {
        if (part.len == 0) return; // Nothing to write
        if (stream.size() < part.len) return error.FragmentTooBig;
        if (pos > stream.size() - part.len) return error.InvalidOffset;

        try stream.write(part, pos);
    }

    /// # Reads Incremental Data from the Object
    /// - `part` - Buffer that the data fragment is read into
    ///
    /// **Remarks:** Returns **null** at the end of the stream, otherwise the
    /// fragment read from the current cursor position — a buffer larger than
    /// the remaining data yields a partial read instead of an error
    pub fn incRead(stream: *BlobStream, part: []u8) !?Str {
        return try stream.read(part);
    }
};

pub const StreamObject = struct {
    // TODO
    // - make a schema for parted data upload such as VideoFrame
    // - where rowID could be primary key and uuid as optional identifier
    // - uuid should be same for multiple part with the cat timestamp
    // - so we can aggregate the same fragment data in serial
    // - also should have a cont: bool field so worker can know for sure
    // - that the upload has completed

    // - A worker or schedular could randomly peak a uuid and check cont
    // - when cont is false means file has been fully uploaded
    // - in such case worker will first gather the total size by data len
    // - then, will create a provisional object by that size
    // - will get each data fragment stream it to dest then remove the row

    // - also we can make a job queue with uuid, priority, and status
    // - use this uuid to upload multiple parts and then worker can query
    // - this way no random uuid search will be needed
    // - FYI, this worst cases, what could go wrong!
};

//##############################################################################
//# TESTS ---------------------------------------------------------------------#
//##############################################################################

const testing = std.testing;

fn testSloop() !Self {
    return try init(testing.io, testing.allocator, null, 8, null);
}

test "bucket lifecycle" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();

    const empty = try containers.list();
    defer containers.freeList(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    try containers.create("bucket_a");
    try containers.create("bucket_b");

    const created = try containers.list();
    defer containers.freeList(created);
    try testing.expectEqual(@as(usize, 2), created.len);

    try s.setIndex(); // Indexes every existing container

    // Each container must own its uniquely named index — SQLite index names
    // are database-global, so a shared name would skip every container
    // after the first
    {
        const conn = try s.acquire();
        defer conn.release();

        var result = try conn.db.exec(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_uuid_%' ORDER BY name;"
        );
        defer result.destroy();

        try testing.expectEqual(@as(usize, 2), result.count());
        try testing.expectEqualStrings("idx_uuid_bucket_a", result.next().?[0].data);
        try testing.expectEqualStrings("idx_uuid_bucket_b", result.next().?[0].data);
    }

    try containers.remove("bucket_b");

    const remaining = try containers.list();
    defer containers.freeList(remaining);
    try testing.expectEqual(@as(usize, 1), remaining.len);
    try testing.expectEqualStrings("bucket_a", remaining[0]);
}

test "pooled connections serve concurrent operations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const heap = testing.allocator;

    // File-backed storage so the pool keeps multiple connections — in-memory
    // storage collapses to a single connection and cannot exercise this.
    // `testing.tmpDir()` creates its directory under `.zig-cache/tmp/<sub_path>`
    const dir_path = try std.fmt.allocPrintSentinel(
        heap, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0
    );
    defer heap.free(dir_path);

    // File-backed storage so the pool keeps multiple connections — in-memory
    // storage collapses to a single connection and cannot exercise this
    const path = try std.fmt.allocPrintSentinel(heap, "{s}/pool.db", .{dir_path}, 0);
    defer heap.free(path);

    var s = try init(testing.io, heap, path, 4, 4);
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("parallel");

    var failures = std.atomic.Value(u32).init(0);

    const Runner = struct {
        parent: *Self,
        id: usize,
        fail: *std.atomic.Value(u32),

        fn run(self: @This()) void {
            self.work() catch {
                _ = self.fail.fetchAdd(1, .release);
            };
        }

        fn work(self: @This()) !void {
            var obj = self.parent.object();

            var i: usize = 0;
            while (i < 16) : (i += 1) {
                var name_buf: [24]u8 = undefined;
                const name = try std.fmt.bufPrint(
                    &name_buf, "w{d}_{d}.txt", .{self.id, i}
                );

                const payload = try std.fmt.allocPrint(
                    heap, "payload-{d}-{d}", .{self.id, i}
                );
                defer heap.free(payload);

                const uuid = try obj.put("parallel", name, payload, &.{}, &.{});

                const blob = try obj.get("parallel", &uuid, null, .default);
                defer heap.free(blob);
                try testing.expectEqualStrings(payload, blob);

                try obj.remove("parallel", &uuid, null, .default);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, idx| {
        thread.* = try std.Thread.spawn(.{}, Runner.run, .{
            Runner {.parent = &s, .id = idx, .fail = &failures}
        });
    }

    for (&threads) |*thread| thread.join();

    try testing.expectEqual(@as(u32, 0), failures.load(.acquire));
}

test "object put, get and remove with ACL" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("docs");

    var obj = s.object();

    const uuid = try obj.put("docs", "doc.txt", "Hello, Sloop!", &.{"alice"}, &.{"bob"});

    // Owner and listed access can read
    const owned = try obj.get("docs", &uuid, "alice", .default);
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("Hello, Sloop!", owned);

    const shared = try obj.get("docs", &uuid, "bob", .default);
    defer testing.allocator.free(shared);
    try testing.expectEqualStrings("Hello, Sloop!", shared);

    // Unknown entities and public access are denied
    try testing.expectError(
        Error.AccessDenied, obj.get("docs", &uuid, "eve", .default)
    );
    try testing.expectError(
        Error.AccessDenied, obj.get("docs", &uuid, null, .default)
    );

    // Unknown uuid is not found
    const ghost = try Uuid.toUrn(&(try Uuid.new(testing.io)));
    try testing.expectError(
        Error.NotFound, obj.get("docs", &ghost, "alice", .default)
    );

    // Info reflects the stored record
    var info = try obj.info("docs", &uuid, "alice", .default);
    defer info.free();

    try testing.expectEqualStrings("doc.txt", info.value().name);
    try testing.expectEqual(@as(i64, "Hello, Sloop!".len), info.value().size);
    try testing.expectEqual(@as(usize, 1), info.value().owner.len);

    // Only the owner removes
    try testing.expectError(
        Error.AccessDenied, obj.remove("docs", &uuid, "bob", .default)
    );
    try obj.remove("docs", &uuid, "alice", .default);
    try testing.expectError(
        Error.NotFound, obj.get("docs", &uuid, "alice", .default)
    );
}

test "public object access" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("docs");
    var obj = s.object();

    const uuid = try obj.put("docs", "pub.txt", "open data", &.{}, &.{});

    const data = try obj.get("docs", &uuid, null, .default);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("open data", data);

    // Public objects cannot be administered nor entity-accessed
    try testing.expectError(
        Error.AccessDenied,
        obj.addOwner("docs", &uuid, "eve", "mallory", .default)
    );
    try testing.expectError(
        Error.AccessDenied, obj.get("docs", &uuid, "eve", .default)
    );
}

test "repeated operations reuse prepared statements" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("reused");
    var obj = s.object();

    // Every cached statement kind is exercised repeatedly — stale bindings
    // or unrecycled execution state would surface here as wrong results
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        const name = try std.fmt.allocPrint(
            testing.allocator, "doc_{d}.txt", .{index}
        );
        defer testing.allocator.free(name);

        const payload = try std.fmt.allocPrint(
            testing.allocator, "payload-{d}", .{index}
        );
        defer testing.allocator.free(payload);

        const uuid = try obj.put("reused", name, payload, &.{"alice"}, &.{"bob"});

        const blob = try obj.get("reused", &uuid, "bob", .default);
        defer testing.allocator.free(blob);
        try testing.expectEqualStrings(payload, blob);

        var info = try obj.info("reused", &uuid, "alice", .default);
        defer info.free();
        try testing.expectEqualStrings(name, info.value().name);

        try obj.addAccess("reused", &uuid, "alice", "carol", .default);
        try obj.removeAccess("reused", &uuid, "alice", "carol", .default);

        try obj.remove("reused", &uuid, "alice", .default);
    }

    // Interleaved lookups on two live records through the shared statements
    const first = try obj.put("reused", "one.txt", "one", &.{}, &.{});
    const second = try obj.put("reused", "two.txt", "two", &.{}, &.{});

    const data_two = try obj.get("reused", &second, null, .default);
    defer testing.allocator.free(data_two);
    try testing.expectEqualStrings("two", data_two);

    const data_one = try obj.get("reused", &first, null, .default);
    defer testing.allocator.free(data_one);
    try testing.expectEqualStrings("one", data_one);

    const again = try obj.get("reused", &second, null, .default);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings("two", again);

    try obj.remove("reused", &first, null, .default);
    try obj.remove("reused", &second, null, .default);
}

test "owner and access management" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("docs");
    var obj = s.object();

    const uuid = try obj.put("docs", "doc.txt", "payload", &.{"alice"}, &.{});

    // Non-owners cannot manage owners nor access
    try testing.expectError(
        Error.AccessDenied,
        obj.addOwner("docs", &uuid, "eve", "mallory", .default)
    );
    try testing.expectError(
        Error.AccessDenied,
        obj.addAccess("docs", &uuid, "eve", "bob", .default)
    );

    try obj.addOwner("docs", &uuid, "alice", "carol", .default);

    // Duplicate is a no-op
    try obj.addOwner("docs", &uuid, "alice", "carol", .default);

    var info = try obj.info("docs", &uuid, "alice", .default);
    defer info.free();
    try testing.expectEqual(@as(usize, 2), info.value().owner.len);

    try obj.addAccess("docs", &uuid, "alice", "bob", .default);
    const shared = try obj.get("docs", &uuid, "bob", .default);
    defer testing.allocator.free(shared);
    try testing.expectEqualStrings("payload", shared);

    try obj.removeAccess("docs", &uuid, "alice", "bob", .default);
    try testing.expectError(
        Error.AccessDenied, obj.get("docs", &uuid, "bob", .default)
    );

    // Removing an unknown entity fails
    try testing.expectError(
        Error.MissingEntity,
        obj.removeOwner("docs", &uuid, "alice", "eve", .default)
    );

    try obj.removeOwner("docs", &uuid, "alice", "carol", .default);

    // Refuses to remove the last owner, keeping the object manageable
    try testing.expectError(
        Error.MissingOwnership,
        obj.removeOwner("docs", &uuid, "alice", "alice", .default)
    );
}

test "provision and stream I/O bounds" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("media");
    var obj = s.object();

    const uuid = try obj.provision(
        "media", "clip.bin", 16, &.{"alice"}, &.{"bob"}
    );

    var info = try obj.info("media", &uuid, "alice", .default);
    defer info.free();

    const rid = info.value().rowid;
    try testing.expectEqual(@as(i64, 16), info.value().size);

    // Stale or foreign rowid is rejected
    try testing.expectError(
        Error.NotFound,
        obj.openStream("media", rid + 1, &uuid, "alice", .default)
    );

    // Owners stream read-write — the stream holds the pool's only
    // connection (in-memory), so it is closed before any other operation
    {
        var writer = try obj.openStream("media", rid, &uuid, "alice", .default);
        defer Object.closeStream(&writer);

        try Object.incWrite(&writer, "hello", 0);
        try Object.incWrite(&writer, "world", 5);

        // Bounds: fragment bigger than the object
        const big: [17]u8 = @splat('A');
        try testing.expectError(error.FragmentTooBig, Object.incWrite(&writer, &big, 0));

        // Bounds: offset beyond the writable range (underflow regression)
        try testing.expectError(error.InvalidOffset, Object.incWrite(&writer, "AB", 20));
        try testing.expectError(error.InvalidOffset, Object.incWrite(&writer, "AB", 15));

        // Empty fragment is a no-op, even at the end of the object
        try Object.incWrite(&writer, "", 16);
    }

    // Access-listed entities stream read-only
    {
        var viewer = try obj.openStream("media", rid, &uuid, "bob", .default);
        defer Object.closeStream(&viewer);

        try testing.expectError(
            error.Locked, Object.incWrite(&viewer, "XX", 0)
        );

        var buffer: [4]u8 = undefined;
        try testing.expectEqualStrings(
            "hell", (try Object.incRead(&viewer, &buffer)).?
        );
        try testing.expectEqualStrings(
            "owor", (try Object.incRead(&viewer, &buffer)).?
        );
        try testing.expectEqualStrings(
            "ld\x00\x00", (try Object.incRead(&viewer, &buffer)).?
        );

        // Buffer larger than the remaining data yields a partial read
        var big_read: [17]u8 = @splat('A');
        const tail = (try Object.incRead(&viewer, &big_read)).?;
        try testing.expectEqualStrings("\x00\x00\x00\x00", tail);

        try testing.expect((try Object.incRead(&viewer, &buffer)) == null);
        try testing.expect((try Object.incRead(&viewer, &big_read)) == null);
    }
}

test "stream write requires ownership" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("media");
    var obj = s.object();

    const uuid = try obj.provision(
        "media", "clip.bin", 16, &.{"alice"}, &.{"bob"}
    );

    var info = try obj.info("media", &uuid, "alice", .default);
    defer info.free();

    const rid = info.value().rowid;

    // Access-listed entity gets a read-only stream — the stream holds the
    // pool's only connection (in-memory), so it is closed before the next
    // provision
    {
        var viewer = try obj.openStream("media", rid, &uuid, "bob", .default);
        defer Object.closeStream(&viewer);

        try testing.expectError(
            error.Locked, Object.incWrite(&viewer, "XX", 0)
        );
    }

    // Public objects stream read-only for everyone
    const pub_uuid = try obj.provision("media", "open.bin", 16, &.{}, &.{});

    var pub_info = try obj.info("media", &pub_uuid, null, .default);
    defer pub_info.free();

    {
        var public = try obj.openStream(
            "media", pub_info.value().rowid, &pub_uuid, null, .default
        );
        defer Object.closeStream(&public);

        try testing.expectError(
            error.Locked, Object.incWrite(&public, "XX", 0)
        );
    }

    const data = try obj.get("media", &pub_uuid, null, .default);
    defer testing.allocator.free(data);
    try testing.expectEqual(@as(usize, 16), data.len);
}

test "clearance override" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("docs");
    var obj = s.object();

    const uuid = try obj.put(
        "docs", "doc.txt", "payload", &.{"alice"}, &.{"bob"}
    );

    // `owner` tightens clearance — listed access is denied
    try testing.expectError(
        Error.AccessDenied, obj.get("docs", &uuid, "bob", .owner)
    );
    try testing.expectError(
        Error.AccessDenied, obj.openStream("docs", 0, &uuid, "bob", .owner)
    );

    // `access` relaxes clearance — listed access gains owner-only operations
    try obj.addOwner("docs", &uuid, "bob", "carol", .access);

    // `default` keeps the built-in policy of the operation
    try testing.expectError(
        Error.AccessDenied,
        obj.addAccess("docs", &uuid, "eve", "mallory", .default)
    );

    // `bypass` skips the clearance check entirely
    var info = try obj.info("docs", &uuid, "eve", .bypass);
    defer info.free();
    try testing.expectEqualStrings("doc.txt", info.value().name);

    {
        var stranger = try obj.openStream(
            "docs", info.value().rowid, &uuid, "eve", .bypass
        );
        defer Object.closeStream(&stranger);
    }

    try obj.remove("docs", &uuid, "eve", .bypass);
    try testing.expectError(
        Error.NotFound, obj.get("docs", &uuid, "alice", .bypass)
    );
}

test "scan iterates container records progressively" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("docs");
    var obj = s.object();

    _ = try obj.put("docs", "a.txt", "one", &.{}, &.{});
    _ = try obj.put("docs", "b.txt", "two", &.{}, &.{});
    _ = try obj.provision("docs", "c.bin", 64, &.{}, &.{});

    var names: [3][]const u8 = undefined;

    // The cursor holds the pool's only connection (in-memory), so it is
    // closed before any other operation needs a connection
    {
        var cursor = try containers.scan("docs");
        defer cursor.close();

        var count: usize = 0;

        while (try cursor.next()) |row| {
            defer row.free();

            try testing.expect(count < names.len);
            names[count] = try testing.allocator.dupe(u8, row.value().name);
            try testing.expect(row.value().uuid.len == 36);
            try testing.expect(row.value().size > 0);
            try testing.expect(row.value().rowid > 0);
            count += 1;
        }

        try testing.expectEqual(@as(usize, 3), count);
    }

    try testing.expectEqualStrings("a.txt", names[0]);
    try testing.expectEqualStrings("b.txt", names[1]);
    try testing.expectEqualStrings("c.bin", names[2]);

    for (names) |item| testing.allocator.free(item);

    // Early loop exit with an explicit close (no leaked rows or cursor)
    {
        var partial = try containers.scan("docs");
        const first = (try partial.next()).?;
        first.free();
        partial.close();
    }

    // Empty containers yield no rows
    try containers.create("empty_docs");

    var vacant = try containers.scan("empty_docs");
    defer vacant.close();

    try testing.expect((try vacant.next()) == null);
}
