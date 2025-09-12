const std = @import("std");
const crypto = std.crypto;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const Sloop = @import("sloop").Sloop;


pub fn main() !void {
    var gpa_mem = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

    // Write your code here..

    var sloop = try Sloop.init(heap, "bucket.db", 32);
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

    // Incrementally writes into the provisional object
    const rid = info.value().rowid;
    var blob_writer = try obj.openStream("test_img1", rid, &uuid, "jane");
    defer Sloop.Object.closeStream(&blob_writer);

    try Sloop.Object.incWrite(&blob_writer, "hello", 2);

    // Incrementally reads out of the provisional object
    var blob_reader = try obj.openStream("test_img1", rid, &uuid, "john");
    defer Sloop.Object.closeStream(&blob_reader);

    var buffer: [128]u8 = undefined;
    while(try Sloop.Object.incRead(&blob_reader, &buffer)) |data| {
        std.debug.print("Chunk: {s}\n", .{data});
    }
}
