const std = @import("std");

const Sloop = @import("sloop").Sloop;


pub fn main(init: std.process.Init) !void {
    var gpa_mem = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

    // Connection pool — `workers = null` opens one connection per available
    // CPU core (pass a count to match the executor's worker count instead);
    // `cache` is the per-connection storage engine cache size in MB.
    // In-memory storage (`null` path) collapses the pool to a single connection
    var sloop = try Sloop.init(init.io, heap, "bucket.db", 32, null);
    try sloop.setIndex();
    defer sloop.deinit();

    // Full consistency check of the storage file (O(database size)) —
    // typically run once on startup or from a periodic maintenance job
    try sloop.checkIntegrity();

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

    // Public object
    const uuid2 = try obj.provision("test_img1", "prov.txt", 1024, &.{}, &.{});
    std.debug.print("{s}\n", .{uuid2});

    // Gets object info from the bucket

    // Private object — only owners are permitted
    var info = try obj.info("test_img1", &uuid, "john");
    defer info.free();

    std.debug.print("Info: {s} | {d} bytes\n", .
        {info.value().name, info.value().size});

    // Public object — readable without an entity
    var info2 = try obj.info("test_img1", &uuid2, null);
    defer info2.free();

    std.debug.print("Info: {s} | {d} bytes\n", .
        {info2.value().name, info2.value().size});

    // Incrementally writes into the provisional object (owner stream —
    // owners hold read-write streams) and reads it back out. Streams hold
    // their pooled connection until closed, so scope them before mutating
    // the record again
    {
        const rid = info.value().rowid;
        var blob_writer = try obj.openStream("test_img1", rid, &uuid, "john");
        defer Sloop.Object.closeStream(&blob_writer);

        try Sloop.Object.incWrite(&blob_writer, "hello", 2);

        // Incrementally reads out of the provisional object (access stream —
        // access entities hold read-only streams)
        var blob_reader = try obj.openStream("test_img1", rid, &uuid, "jane");
        defer Sloop.Object.closeStream(&blob_reader);

        var buffer: [128]u8 = undefined;
        while (try Sloop.Object.incRead(&blob_reader, &buffer)) |data| {
            std.debug.print("Chunk: {s}\n", .{data});
        }
    }

    // Reads back the incrementally written region through the whole-object
    // interface, proving the streamed bytes were committed
    const written = try obj.get("test_img1", &uuid, "john");
    defer sloop.heap.free(written);
    std.debug.print("Streamed: {s}\n", .{written[2..7]});

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

    // Access is denied for entities outside the owner and access lists
    if (obj.get("test_img1", &uuid, "mallory")) |_| {
        std.debug.print("ERROR: stranger read a private object!\n", .{});
    } else |err| {
        std.debug.print("Denied for mallory: {s}\n", .{@errorName(err)});
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
