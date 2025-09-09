//! # Simple Bucket Storage

const std = @import("std");
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
        const sql = comptime Qb.Container.create(schema.Model, name, .Uuid);
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

const Object = struct {
    parent: *Self,

    /// - `c_name` - Name of the object container (e.g., `user_img`)
    pub fn put(
        self: *Object,
        comptime c_name: Str,
        name: Str,
        data: Str,
        owner: []const Str
    ) ![16]u8 {
        const sql = comptime blk: {
            var sql = Qb.Record.create(schema.Model, c_name, .Default);
            break :blk sql.statement();
        };

        const uuid = Uuid.new();

        const rec = schema.Model {
            .uuid = .{.blob = &uuid},
            .name = .{.text = name},
            .data = .{.blob = data},
            .owned_by = .{.text = owner},
            .prov = null,
            .cat = DateTime.timestamp()
        };

        var crud = try self.parent.storage.prepare(sql);
        defer crud.destroy();

        try crud.exec(rec, null, null);
        return uuid;
    }

    // /// - `c_name` - Name of the object container (e.g., `user_img`)
    // pub fn get(c_name: Str, uuid: Str) void {

    // }

    // /// - `c_name` - Name of the object container (e.g., `user_img`)
    // pub fn remove(c_name: Str, uuid: Str) void {

    // }

    // /// - `c_name` - Name of the object container (e.g., `user_img`)
    // pub fn info(c_name: Str, uuid: Str) void {
        
    // }

    // /// - `c_name` - Name of the object container (e.g., `user_img`)
    // pub fn provision(
    //     size: usize,
    //     c_name: Str,
    //     name: Str,
    //     data: Str,
    //     owner: []const Str,
    // ) void {

    // }

    // /// - `c_name` - Name of the object container (e.g., `user_img`)
    // pub fn putPart(c_name: Str, uuid: Str) void {

    // }

    // /// - `c_name` - Name of the object container (e.g., `user_img`)
    // pub fn getPart(c_name: Str, uuid: Str) void {

    // }
};

pub const Stream = struct {
    // TODO

};

