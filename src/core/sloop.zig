//! # Simple Bucket Storage

const std = @import("std");
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


const Str = []const u8;
const StrZ = [:0]const u8;

heap: Allocator,
storage: Quill,

const Self = @This();

/// # Initializes Sloop with Default Configuration
/// - `path` - Bucket storage file path (e.g., `bucket.db`)
/// - `cache` - Underlying storage engine cache size in MB
pub fn init(heap: Allocator, path: StrZ, comptime cache: u16) !Self {
    try Quill.init(.Serialized);

    var db = try Quill.open(heap, path, .All);

    try Builtins.Pragma.optimize(&db);
    try Builtins.Pragma.checkIntegrity(&db);
    try Builtins.Pragma.setJournal(&db, .WAL);
    try Builtins.Pragma.setSynchronous(&db, .NORMAL);
    try Builtins.Pragma.setCache(&db, -(@as(i32, cache) * 1024));

    return .{.heap = heap, .storage = db};
}

/// # Destroys the Sloop Instance
pub fn deinit(self: *Self) void {
    self.storage.close();
    Quill.deinit();
}

/// # Creates Indexes on Object Containers
pub fn setIndex(self: *Self) !void {
    var containers = self.bucket();
    const items = try containers.list();
    defer containers.freeList(items);

    for (items) |item| {
        const fmt_str = "CREATE UNIQUE INDEX IF NOT EXISTS idx_uuid ON {s}(\"uuid\");";
        const sql = try fmt.allocPrint(self.heap, fmt_str, .{item});
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
        var tables = ArrayList(Str).init(self.parent.heap);
        errdefer tables.deinit();

        const sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';";

        var result = try self.parent.storage.exec(sql);
        defer result.destroy();

        while (true) {
            if (result.next()) |col| {
                const data = col[0].data;
                const item = try self.parent.heap.alloc(u8, data.len);
                mem.copyForwards(u8, item, data);
                try tables.append(item);
                continue;
            }

            break;
        }

        return try tables.toOwnedSlice();
    }

    /// # Frees the Object Container Names
    pub fn freeList(self: *Bucket, items: []const Str) void {
        for (items) |item| self.parent.heap.free(item);
        self.parent.heap.free(items);
    }
};

pub const Object = struct {
    parent: *Self,

    /// # Puts a New Object into the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `name` - Name of the object (e.g., `profile_img.jpg`)
    /// - `data` - Octet data of the given object
    /// - `owner` - Empty (e.g., `&.{}`) for public object
    pub fn put(
        self: *Object,
        comptime c_name: Str,
        name: Str,
        data: Str,
        owner: []const Str
    ) ![36]u8 {
        const sql = comptime blk: {
            var sql = Qb.Record.create(schema.Model, c_name, .Default);
            break :blk sql.statement();
        };

        const uuid = try Uuid.toUrn(&Uuid.new());

        const rec = schema.Model {
            .uuid = .{.text = &uuid},
            .name = .{.text = name},
            .data = .{.blob = data},
            .owned_by = .{.text = owner},
            .size = @intCast(data.len),
            .cat = DateTime.timestamp()
        };

        var crud = try self.parent.storage.prepare(sql);
        defer crud.destroy();

        try crud.exec(rec, null, null);
        return uuid;
    }

    /// # Retrieves the Object Data from the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    ///
    /// **WARNING:** Return value must be freed by the caller.
    pub fn get(self: *Object, comptime c_name: Str, uuid: Str) !?Str {
        const sql = comptime blk: {
            var sql = Qb.Record.find(schema.ViewData, schema.Filter, c_name);
            sql.when(&.{sql.filter("uuid", .@"=", null)});
            break :blk sql.statement();
        };

        const filter = schema.Filter {.uuid = uuid};

        var crud = try self.parent.storage.prepare(sql);
        defer crud.destroy();

        const result = try crud.readOne(schema.ViewData, filter);
        defer crud.free(result);

        if (result) |rec| {
            const out = try self.parent.heap.alloc(u8, rec.data.len);
            mem.copyForwards(u8, out, rec.data);
            return out;
        }

        return null;
    }

    /// # Removes the Object from the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    pub fn remove(self: *Object, comptime c_name: Str, uuid: Str) !void {
        const sql = comptime blk: {
            var sql = Qb.Record.remove(schema.Filter, c_name, .Exact);
            sql.when(&.{sql.filter("uuid", .@"=", null)});
            break :blk sql.statement();
        };

        const filter = schema.Filter {.uuid = uuid};

        var crud = try self.parent.storage.prepare(sql);
        defer crud.destroy();

        try crud.remove(filter, null);
    }

    const Info = struct {
        data: schema.ViewInfo,
        crud: Quill.CRUD,

        pub fn value(self: *const Info) schema.ViewInfo {
            return self.data;
        }

        pub fn free(self: *Info) void {
            return self.crud.free(self.data);
        }
    };

    /// # Retrieves the Object Information from the Bucket
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `uuid` - UUID of the object
    ///
    /// **WARNING:** Return value must be freed by calling `Info.free()`.
    pub fn info(self: *Object, comptime c_name: Str, uuid: Str) !?Info {
        const sql = comptime blk: {
            var sql = Qb.Record.find(schema.ViewInfo, schema.Filter, c_name);
            sql.when(&.{sql.filter("uuid", .@"=", null)});
            break :blk sql.statement();
        };

        const filter = schema.Filter {.uuid = uuid};

        var crud = try self.parent.storage.prepare(sql);
        defer crud.destroy();

        const result = try crud.readOne(schema.ViewInfo, filter);

        if (result) |rec| { return .{.data = rec, .crud = crud }; }

        crud.free(result);
        return null;
    }

    /// # Provisions a New Object for Incremental I/O
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `name` - Name of the object (e.g., `profile_img.jpg`)
    /// - `size` - Provisional data size of the given object
    /// - `owner` - Empty (e.g., `&.{}`) for public object
    pub fn provision(
        self: *Object,
        comptime c_name: Str,
        name: Str,
        size: u32,
        owner: []const Str,
    ) ![36]u8 {
        const sql = comptime blk: {
            var sql = Qb.Record.create(schema.Model, c_name, .Default);
            break :blk sql.statement();
        };

        const uuid = try Uuid.toUrn(&Uuid.new());

        const rec = schema.ModelProvision {
            .uuid = .{.text = &uuid},
            .name = .{.text = name},
            .data = .{.blob_len = @intCast(size)},
            .owned_by = .{.text = owner},
            .size = @intCast(size),
            .cat = DateTime.timestamp()
        };

        var crud = try self.parent.storage.prepare(sql);
        defer crud.destroy();

        try crud.exec(rec, null, null);
        return uuid;
    }

    /// # Opens Object Streaming
    /// - `c_name` - Name of the object container (e.g., `user_img`)
    /// - `rid` - RowId of the object
    ///
    /// **WARNING:** Return value must be freed by calling `closeStream()`
    pub fn openStream(self: *Object, c_name: StrZ, rid: i64) !BlobStream {
        return try BlobStream.open(
            &self.parent.storage, c_name, "data", rid, .ReadWrite
        );
    }

    /// # Closes Object Streaming
    pub fn closeStream(blob: *BlobStream) void { blob.close(); }

    /// # Writes Incremental Data to the Object
    /// - `part` - Data fragment for incremental write
    /// - `pos` - Offset position from where the part will be written
    pub fn incWrite(stream: *BlobStream, part: Str, pos: usize) !void {
        if (stream.size() < part.len) return error.FragmentTooBig;
        if ((stream.size() - pos) < part.len) return error.InvalidOffset;

        try stream.write(part, pos);
    }

    /// # Reads Incremental Data from the Object
    /// - `part` - Data fragment for incremental read
    /// - `pos` - Offset position from where the part will be written
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
