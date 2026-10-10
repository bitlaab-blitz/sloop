//! # Simple Bucket Storage

const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const quill = @import("quill");
const Dt = quill.Types;
const Uuid = quill.Uuid;
const Quill = quill.Quill;
const Qb = quill.QueryBuilder;
const Builtins = quill.Builtins;
const DateTime = quill.DateTime;
const BlobStream = Quill.BlobStream;

const schema = @import("./schema.zig");

const DbOption = quill.Native.sqlite3.Option;


const Str = []const u8;
const StrZ = [:0]const u8;

const Error = error { AccessDenied, MissingOwnership, NotFound, MissingEntity };

/// # Identifies a Pre-parable Statement for a Container
const Stmt = enum {
    find_info, find_data, insert, remove, update_owner, update_access
};

/// # Lazily Prepared Statements of an Object Container
/// **Remarks:** Compiled once per container and reused across operations
/// (quill's `CRUD` recycles the statement automatically on every operation).
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
storage: Quill,
caches: std.StringHashMap(StmtCache),

const Self = @This();

/// # Initializes Sloop with Default Configuration
/// - `path` - Bucket storage file path (e.g., `bucket.db`), or **null** for
///   an in-memory storage
/// - `mode` - Underlying storage engine threading mode. Use `.SingleThreaded`
///   when instances are confined to a single thread (skips per-call mutexes)
/// - `cache` - Underlying storage engine cache size in MB
///
/// **Remarks:** Run `checkIntegrity()` separately (e.g., on first open or
/// periodically) as it is an O(database size) operation.
pub fn init(
    io: Io,
    heap: Allocator,
    path: ?StrZ,
    mode: DbOption,
    comptime cache: u16
) !Self {
    try Quill.init(mode);

    var db = try Quill.open(heap, path, .All);

    try Builtins.Pragma.optimize(&db);
    try Builtins.Pragma.setJournal(&db, .WAL);
    try Builtins.Pragma.setSynchronous(&db, .NORMAL);
    try Builtins.Pragma.setCache(&db, -(@as(i32, cache) * 1024));

    return .{
        .io = io,
        .heap = heap,
        .storage = db,
        .caches = std.StringHashMap(StmtCache).init(heap)
    };
}

/// # Checks Internal Consistency of the Storage
/// **Remarks:** Cost is O(database size), avoid on every open. Returns
/// `FailedIntegrityChecks` when the database file is corrupted
pub fn checkIntegrity(self: *Self) !void {
    try Builtins.Pragma.checkIntegrity(&self.storage);
}

/// # Destroys the Sloop Instance
pub fn deinit(self: *Self) void {
    var it = self.caches.iterator();
    while (it.next()) |entry| {
        inline for (@typeInfo(StmtCache).@"struct".field_names) |f_name| {
            if (@field(entry.value_ptr.*, f_name)) |*prepared| {
                prepared.destroy();
            }
        }
    }

    self.caches.deinit();
    self.storage.close();
    Quill.deinit();
}

/// # Returns the Prepared Statement Interface for the Given Operation
/// **Remarks:** Statements are compiled once per container and kept alive for
/// reuse — quill's `CRUD` recycles the statement automatically on every
/// operation, removing the per-call recompilation cost. Intended for internal
/// use only: returned statements must never be `destroy()`ed by callers and
/// must not span across operations (each operation completes its own stepping).
fn stmt(self: *Self, comptime kind: Stmt, comptime c_name: Str) !*Quill.CRUD {
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

    slot.* = try self.storage.prepare(sql);
    return &slot.*.?;
}

/// # Creates Indexes on Object Containers
pub fn setIndex(self: *Self) !void {
    var containers = self.bucket();
    const items = try containers.list();
    defer containers.freeList(items);

    for (items) |item| {
        const fmt_str = "CREATE UNIQUE INDEX IF NOT EXISTS idx_uuid ON {s}(\"uuid\");";
        const sql = try fmt.allocPrintSentinel(self.heap, fmt_str, .{item}, 0);
        defer self.heap.free(sql);

        var result = try self.storage.exec(sql);
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
        var result = try self.parent.storage.exec(sql);
        result.destroy();
    }

    /// # Removes the Object Container
    /// - `name` - Name of the object container (e.g., `user_img`)
    pub fn remove(self: *Bucket, comptime name: Str) !void {
        try Builtins.Container.delete(&self.parent.storage, name, .Retain);
    }

    /// # Retrieves Object Container Names
    /// **WARNING:** Return value must be freed by calling `freeList()`.
    pub fn list(self: *Bucket) ![]const Str {
        const heap = self.parent.heap;

        var tables: ArrayList(Str) = .empty;
        errdefer tables.deinit(heap);

        const sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';";

        var result = try self.parent.storage.exec(sql);
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
        const sql = comptime blk: {
            var sql = Qb.Record.find(schema.ViewScan, schema.Filter, name);
            break :blk sql.statement();
        };

        var crud = try self.parent.storage.prepare(sql);
        errdefer crud.destroy();

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

        /// # Closes the Cursor
        pub fn close(self: *Cursor) void {
            self.crud.destroy();
        }
    };
};

pub const Object = struct {
    parent: *Self,

    /// # Access Levels Granted by the ACL
    const Access = enum { none, read, write };

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

        const crud = try self.parent.stmt(.insert, c_name);
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
    ///
    /// **WARNING:** Return value must be freed by the caller.
    pub fn get(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        access: ?Str
    ) !Str {
        const crud = try self.parent.stmt(.find_data, c_name);

        const filter = schema.Filter {.uuid = uuid};
        var result = crud.readOne(schema.ViewData, filter) catch |err| {
            crud.reset() catch {};
            return err;
        };

        const rec = result orelse return Error.NotFound;

        if (clearance(rec, access, false) == .none) {
            crud.free(result);
            crud.reset() catch {};
            return Error.AccessDenied;
        }

        // Transfers the heap-owned blob, avoiding a redundant copy
        const out = rec.data;
        result.?.data = "";

        crud.free(result);
        crud.reset() catch {};
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
        comptime erase: bool
    ) !void {
        const heap = self.parent.heap;

        var session = try self.authorize(c_name, uuid, owner, true);
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

        const crud = try self.parent.stmt(
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
    }

    /// # Adds Owner to an Object
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `owner` - Existing owner entity string
    /// - `entity` - New owner entity string
    pub fn addOwner(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        owner: Str,
        entity: Str,
    ) !void {
        return self.mutateList(
            schema.ModelOwner, "owner", c_name, uuid, owner, entity, false
        );
    }

    /// # Removes Owner from an Object
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `owner` - Existing owner entity string
    /// - `entity` - Existing owner entity string
    pub fn removeOwner(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        owner: Str,
        entity: Str,
    ) !void {
        return self.mutateList(
            schema.ModelOwner, "owner", c_name, uuid, owner, entity, true
        );
    }

    /// # Adds Access to an Object
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `owner` - Existing owner entity string
    /// - `entity` - New access entity string
    pub fn addAccess(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        owner: Str,
        entity: Str,
    ) !void {
        return self.mutateList(
            schema.ModelAccess, "access", c_name, uuid, owner, entity, false
        );
    }

    /// # Removes Access from an Object
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `owner` - Existing owner entity string
    /// - `entity` - Existing access entity string
    pub fn removeAccess(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        owner: Str,
        entity: Str,
    ) !void {
        return self.mutateList(
            schema.ModelAccess, "access", c_name, uuid, owner, entity, true
        );
    }

    /// # Removes the Object from the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `access` - Either an entity or **null** for public object
    pub fn remove(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        access: ?Str
    ) !void {
        var session = try self.authorize(c_name, uuid, access, true);
        defer session.free();

        const crud = try self.parent.stmt(.remove, c_name);
        const filter = schema.Filter {.uuid = uuid};

        crud.remove(filter, null) catch |err| {
            crud.reset() catch {};
            return err;
        };
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

            /// # Releases the Record Memory and Recycles the Statement
            /// **WARNING:** Must be called exactly once
            pub fn free(self: *@This()) void {
                self.crud.free(self.rec);
                self.crud.reset() catch {};
            }
        };
    }

    const Info = Fetch(schema.ViewInfo);

    /// # Retrieves the Object Information from the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    /// - `access` - Either an entity or **null** for public object
    ///
    /// **Remarks:** Only owners and public objects are permitted
    ///
    /// **WARNING:** Return value must be freed by calling `Info.free()`.
    pub fn info(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        access: ?Str
    ) !Info {
        return self.authorize(c_name, uuid, access, true);
    }

    /// # Fetches the ACL-Validated Object Record (Single Query)
    /// **Remarks:** Intended for internal use only
    fn authorize(
        self: *Object,
        comptime c_name: Str,
        uuid: Str,
        access: ?Str,
        owner_only: bool
    ) !Info {
        var session = try self.fetch(c_name, uuid);
        errdefer session.free();

        if (clearance(session.rec, access, owner_only) == .none) {
            return Error.AccessDenied;
        }

        return session;
    }

    /// # Fetches the ACL-Validated Object Record (Single Query)
    /// **Remarks:** Intended for internal use only. The shared statement is
    /// recycled right after the fetch — holding the returned session must not
    /// keep the underlying statement busy for other operations
    fn fetch(self: *Object, comptime c_name: Str, uuid: Str) !Fetch(schema.ViewInfo) {
        const crud = try self.parent.stmt(.find_info, c_name);

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

        const crud = try self.parent.stmt(.insert, c_name);
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
        access: ?Str
    ) !BlobStream {
        var session = try self.fetch(c_name, uuid);
        defer session.free();

        const level = clearance(session.rec, access, false);
        if (level == .none) return Error.AccessDenied;

        // Rejects stale rowids (e.g., after a concurrent remove and re-insert)
        if (session.rec.rowid != rid) return Error.NotFound;

        return BlobStream.open(
            &self.parent.storage, c_name, "data", rid,
            if (level == .write) .ReadWrite else .Read
        );
    }

    /// # Closes Object Streaming
    pub fn closeStream(blob: *BlobStream) void { blob.close(); }

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
    /// fragment read from the current cursor position
    pub fn incRead(stream: *BlobStream, part: []u8) !?Str {
        if (stream.size() < part.len) return error.FragmentTooBig;
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
    return try init(testing.io, testing.allocator, null, .SingleThreaded, 8);
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

    try containers.remove("bucket_b");

    const remaining = try containers.list();
    defer containers.freeList(remaining);
    try testing.expectEqual(@as(usize, 1), remaining.len);
    try testing.expectEqualStrings("bucket_a", remaining[0]);
}

test "object put, get and remove with ACL" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("docs");

    var obj = s.object();

    const uuid = try obj.put("docs", "doc.txt", "Hello, Sloop!", &.{"alice"}, &.{"bob"});

    // Owner and listed access can read
    const owned = try obj.get("docs", &uuid, "alice");
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("Hello, Sloop!", owned);

    const shared = try obj.get("docs", &uuid, "bob");
    defer testing.allocator.free(shared);
    try testing.expectEqualStrings("Hello, Sloop!", shared);

    // Unknown entities and public access are denied
    try testing.expectError(Error.AccessDenied, obj.get("docs", &uuid, "eve"));
    try testing.expectError(Error.AccessDenied, obj.get("docs", &uuid, null));

    // Unknown uuid is not found
    const ghost = try Uuid.toUrn(&(try Uuid.new(testing.io)));
    try testing.expectError(Error.NotFound, obj.get("docs", &ghost, "alice"));

    // Info reflects the stored record
    var info = try obj.info("docs", &uuid, "alice");
    defer info.free();

    try testing.expectEqualStrings("doc.txt", info.value().name);
    try testing.expectEqual(@as(i64, "Hello, Sloop!".len), info.value().size);
    try testing.expectEqual(@as(usize, 1), info.value().owner.len);

    // Only the owner removes
    try testing.expectError(Error.AccessDenied, obj.remove("docs", &uuid, "bob"));
    try obj.remove("docs", &uuid, "alice");
    try testing.expectError(Error.NotFound, obj.get("docs", &uuid, "alice"));
}

test "public object access" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("docs");
    var obj = s.object();

    const uuid = try obj.put("docs", "pub.txt", "open data", &.{}, &.{});

    const data = try obj.get("docs", &uuid, null);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("open data", data);

    // Public objects cannot be administered nor entity-accessed
    try testing.expectError(Error.AccessDenied, obj.addOwner("docs", &uuid, "eve", "mallory"));
    try testing.expectError(Error.AccessDenied, obj.get("docs", &uuid, "eve"));
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

        const blob = try obj.get("reused", &uuid, "bob");
        defer testing.allocator.free(blob);
        try testing.expectEqualStrings(payload, blob);

        var info = try obj.info("reused", &uuid, "alice");
        defer info.free();
        try testing.expectEqualStrings(name, info.value().name);

        try obj.addAccess("reused", &uuid, "alice", "carol");
        try obj.removeAccess("reused", &uuid, "alice", "carol");

        try obj.remove("reused", &uuid, "alice");
    }

    // Interleaved lookups on two live records through the shared statements
    const first = try obj.put("reused", "one.txt", "one", &.{}, &.{});
    const second = try obj.put("reused", "two.txt", "two", &.{}, &.{});

    const data_two = try obj.get("reused", &second, null);
    defer testing.allocator.free(data_two);
    try testing.expectEqualStrings("two", data_two);

    const data_one = try obj.get("reused", &first, null);
    defer testing.allocator.free(data_one);
    try testing.expectEqualStrings("one", data_one);

    const again = try obj.get("reused", &second, null);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings("two", again);

    try obj.remove("reused", &first, null);
    try obj.remove("reused", &second, null);
}

test "owner and access management" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("docs");
    var obj = s.object();

    const uuid = try obj.put("docs", "doc.txt", "payload", &.{"alice"}, &.{});

    // Non-owners cannot manage owners nor access
    try testing.expectError(Error.AccessDenied, obj.addOwner("docs", &uuid, "eve", "mallory"));
    try testing.expectError(Error.AccessDenied, obj.addAccess("docs", &uuid, "eve", "bob"));

    try obj.addOwner("docs", &uuid, "alice", "carol");
    try obj.addOwner("docs", &uuid, "alice", "carol"); // Duplicate is a no-op

    var info = try obj.info("docs", &uuid, "alice");
    defer info.free();
    try testing.expectEqual(@as(usize, 2), info.value().owner.len);

    try obj.addAccess("docs", &uuid, "alice", "bob");
    const shared = try obj.get("docs", &uuid, "bob");
    defer testing.allocator.free(shared);
    try testing.expectEqualStrings("payload", shared);

    try obj.removeAccess("docs", &uuid, "alice", "bob");
    try testing.expectError(Error.AccessDenied, obj.get("docs", &uuid, "bob"));

    // Removing an unknown entity fails
    try testing.expectError(Error.MissingEntity, obj.removeOwner("docs", &uuid, "alice", "eve"));

    try obj.removeOwner("docs", &uuid, "alice", "carol");

    // Refuses to remove the last owner, keeping the object manageable
    try testing.expectError(Error.MissingOwnership, obj.removeOwner("docs", &uuid, "alice", "alice"));
}

test "provision and stream I/O bounds" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("media");
    var obj = s.object();

    const uuid = try obj.provision("media", "clip.bin", 16, &.{"alice"}, &.{"bob"});

    var info = try obj.info("media", &uuid, "alice");
    defer info.free();

    const rid = info.value().rowid;
    try testing.expectEqual(@as(i64, 16), info.value().size);

    // Stale or foreign rowid is rejected
    try testing.expectError(Error.NotFound, obj.openStream("media", rid + 1, &uuid, "alice"));

    // Owners stream read-write
    var writer = try obj.openStream("media", rid, &uuid, "alice");
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

    // Access-listed entities stream read-only
    var viewer = try obj.openStream("media", rid, &uuid, "bob");
    defer Object.closeStream(&viewer);

    try testing.expectError(error.UnknownError, Object.incWrite(&viewer, "XX", 0));

    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("hell", (try Object.incRead(&viewer, &buffer)).?);
    try testing.expectEqualStrings("o wo", (try Object.incRead(&viewer, &buffer)).?);
    try testing.expectEqualStrings("rld", (try Object.incRead(&viewer, &buffer)).?);
    try testing.expectEqualStrings("\x00\x00\x00\x00", (try Object.incRead(&viewer, &buffer)).?);
    try testing.expect((try Object.incRead(&viewer, &buffer)) == null);

    // Read buffer bigger than the object is rejected
    const big_read: [17]u8 = @splat('A');
    try testing.expectError(error.FragmentTooBig, Object.incRead(&viewer, &big_read));
}

test "stream write requires ownership" {
    var s = try testSloop();
    defer s.deinit();

    var containers = s.bucket();
    try containers.create("media");
    var obj = s.object();

    const uuid = try obj.provision("media", "clip.bin", 16, &.{"alice"}, &.{"bob"});

    var info = try obj.info("media", &uuid, "alice");
    defer info.free();

    const rid = info.value().rowid;

    // Access-listed entity gets a read-only stream
    var viewer = try obj.openStream("media", rid, &uuid, "bob");
    defer Object.closeStream(&viewer);

    try testing.expectError(error.UnknownError, Object.incWrite(&viewer, "XX", 0));

    // Public objects stream read-only for everyone
    const pub_uuid = try obj.provision("media", "open.bin", 16, &.{}, &.{});

    var pub_info = try obj.info("media", &pub_uuid, null);
    defer pub_info.free();

    var public = try obj.openStream("media", pub_info.value().rowid, &pub_uuid, null);
    defer Object.closeStream(&public);

    try testing.expectError(error.UnknownError, Object.incWrite(&public, "XX", 0));

    const data = try obj.get("media", &pub_uuid, null);
    defer testing.allocator.free(data);
    try testing.expectEqual(@as(usize, 16), data.len);
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

    var cursor = try containers.scan("docs");
    defer cursor.close();

    var names: [3][]const u8 = undefined;
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
    try testing.expectEqualStrings("a.txt", names[0]);
    try testing.expectEqualStrings("b.txt", names[1]);
    try testing.expectEqualStrings("c.bin", names[2]);

    for (names) |item| testing.allocator.free(item);

    // Early loop exit with an explicit close (no leaked rows or cursor)
    var partial = try containers.scan("docs");
    const first = (try partial.next()).?;
    first.free();
    partial.close();

    // Empty containers yield no rows
    try containers.create("empty_docs");

    var vacant = try containers.scan("empty_docs");
    defer vacant.close();

    try testing.expect((try vacant.next()) == null);
}
