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

Replaces the existing record if the key already exists.

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

Inserts the record only if the key already exists.

```zig
try redox.set("foo", "bar", .IfExists);
```

Inserts the record only if the key does not exist.

```zig
try redox.set("foo2", "bar2", .IfNotExists);
```

## Insert a New Record with Ttl

Same as `redox.set()`, with an additional time-to-live (TTL) value in seconds. The record is automatically deleted after this period.

```zig
try redox.setWith("foo", "bar", .Default, 30);
```

## Extract a Record by the Given Key

```zig
const rec = try redox.get("foo");
defer rec.free();
std.debug.print("Value: {s}\n", .{rec.value()});
```

## Delete a Record by the Given Key

```zig
try redox.remove("foo2");
```

## Scan Partially Matched Keys

```zig
const keys = try redox.scan(heap, "foo:*", 10);
defer Redox.Sync.free(heap, keys);

for (keys) |key| { std.debug.print("key: {s}\n", .{key}); }
```

## Show Human-Readable Error Message

Shows the most recent error that occurred on the HiRedis instance.

```zig
std.debug.print("Redis error: {s}\n", .{redox.errMsg()});
```

**Remarks:** Currently, only the string data structure is supported, and only the synchronous interface is implemented.