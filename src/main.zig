const std = @import("std");
const crypto = std.crypto;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const Sloop = @import("sloop").Sloop;


pub fn main(init: std.process.Init) !void {
    var gpa_mem = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

    // Write your code here..

    // Single-threaded demo process — skips per-call SQLite mutexes
    var sloop = try Sloop.init(init.io, heap, "bucket.db", .SingleThreaded, 32);
    try sloop.setIndex();
    defer sloop.deinit();

    var bucket = sloop.bucket();

    try bucket.create("test_img1");
    try bucket.create("test_img2");
    try bucket.create("test_img3");

    try bucket.remove("test_img3");

    const items = try bucket.list();
    defer bucket.freeList(items);

    for (items) |item| { std.debug.print("{s}\n", .{item}); }

    var obj = sloop.object();

    // Puts a complete (public) object into the bucket and reads it back
    const put_uuid = try obj.put(
        "test_img1", "put.txt", "Hello, Sloop!", &.{}, &.{}
    );
    const blob = try obj.get("test_img1", &put_uuid, null);
    defer sloop.heap.free(blob);
    std.debug.print("{s}\n", .{blob});

    try obj.remove("test_img1", &put_uuid, null);

    // Creates a provisional object in the bucket

    // Private object
    const uuid = try obj.provision("test_img1", "prov.txt", 1024,
        &.{"john"}, &.{"jane"}
    );
    std.debug.print("{s}\n", .{uuid});

    // public object
    const uuid2 = try obj.provision("test_img1", "prov.txt", 1024, &.{}, &.{});
    std.debug.print("{s}\n", .{uuid2});

    // Gets object info from the bucket
    var info = try obj.info("test_img1", &uuid, "john");
    defer info.free();

    // Incrementally writes into the provisional object (owner stream)
    const rid = info.value().rowid;
    var blob_writer = try obj.openStream("test_img1", rid, &uuid, "john");
    defer Sloop.Object.closeStream(&blob_writer);

    try Sloop.Object.incWrite(&blob_writer, "hello", 2);

    // Incrementally reads out of the provisional object (access stream)
    var blob_reader = try obj.openStream("test_img1", rid, &uuid, "jane");
    defer Sloop.Object.closeStream(&blob_reader);

    var buffer: [128]u8 = undefined;
    while(try Sloop.Object.incRead(&blob_reader, &buffer)) |data| {
        std.debug.print("Chunk: {s}\n", .{data});
    }

    // Manages owners and access on the provisional object
    try obj.addOwner("test_img1", &uuid, "john", "doe");
    try obj.addAccess("test_img1", &uuid, "john", "sam");

    try obj.removeAccess("test_img1", &uuid, "john", "sam");
    try obj.removeOwner("test_img1", &uuid, "john", "doe");

    // Refuses to remove the last owner
    if (obj.removeOwner("test_img1", &uuid, "john", "john")) |_| {
        std.debug.print("ERROR: last owner was removed!\n", .{});
    } else |err| {
        std.debug.print("Refused: {s}\n", .{@errorName(err)});
    }

    // Scans the object container (progressive row cursor)
    var cursor = try bucket.scan("test_img1");
    defer cursor.close();

    while (try cursor.next()) |row| {
        defer row.free();
        const scan_info = row.value();
        std.debug.print("Scan: {s} | {s} | {d} bytes\n", .
            {scan_info.uuid, scan_info.name, scan_info.size});
    }
}
