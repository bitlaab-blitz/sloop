# How to use

First, import Sloop on your Zig source file.

```zig
const Sloop = @import("sloop").Sloop;
```

## Initial Setup

Let's initialize an Sloop instance.

```zig
var gpa_mem = std.heap.DebugAllocator(.{}).init;
defer std.debug.assert(gpa_mem.deinit() == .ok);
const heap = gpa_mem.allocator();

var sloop = try Sloop.init(heap, "bucket.db", 32);
try sloop.setIndex();
defer sloop.deinit();
```

## Bucket Operations

```zig
var bucket = sloop.bucket();

try bucket.create("test_img1");
try bucket.create("test_img2");
try bucket.create("test_img3");

try bucket.remove("test_img3");

const items = try bucket.list();
defer bucket.freeList(items);

for (items) |item| { std.debug.print("{s}\n", .{item}); }
```

## Object Operations

```zig
var obj = sloop.object();

// Puts object in the bucket

// Private object
const uuid = try obj.put("test_img2", "pub.txt", "Private, world!",
    &.{"john", "doe"}, &.{}
);
std.debug.print("{s}\n", .{uuid});

// Public object
const uuid2 = try obj.put("test_img2", "priv.txt", "Public, world!",
    &.{}, &.{}
);
std.debug.print("{s}\n", .{uuid2});


// Adds an entity to the access list
try obj.addAccess("test_img2", &uuid, "john", "jake");
try obj.addAccess("test_img2", &uuid, "john", "soul");

// Gets object data from the bucket
const out = try obj.get("test_img2", &uuid, "jake");
defer heap.free(out);
std.debug.print("{s}\n", .{out});

// Removes an entity to the access list
try obj.removeAccess("test_img2", &uuid, "john", "soul");

// Adds an entity to the owner list
try obj.addOwner("test_img2", &uuid, "john", "foo");
try obj.addOwner("test_img2", &uuid, "foo", "bar");
try obj.addOwner("test_img2", &uuid, "foo", "baz");

// Removes an entity to the owner list
try obj.removeOwner("test_img2", &uuid, "foo", "bar");
try obj.removeOwner("test_img2", &uuid, "baz", "baz");


// Gets object info from the bucket

// Private Object
var info = try obj.info("test_img2", &uuid, "john");
defer info.free();

std.debug.print("{s}\n", .{info.value().name});

// Public Object
var info2 = try obj.info("test_img2", &uuid2, null);
defer info2.free();

std.debug.print("{s}\n", .{info2.value().name});


// Removes object from the bucket

// Private object
try obj.remove("test_img2", &uuid, "john");

// Public object
try obj.remove("test_img2", &uuid2, null);
```

**NOTE:**

- Adding or removing owner or access entity is not allows for public object.
- An object is deemed public when owner and access list is empty
- Only owner is allowed to get object info for private object
- An owner can remove itself from the list

## Provisional Object Operation

```zig
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
```

**NOTE:**

- You can also perform incremental I/O on a non-provisioned object
- Owner and access control operation works same as non-provisioned object