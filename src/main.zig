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

    var sloop = try Sloop.init(heap, "bucket.db", 16);
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
    const uuid = try obj.put("test_img2", "simple.txt", "hello, world!", &.{"john", "doe"});
    std.debug.print("{any}\n", .{uuid});
}

