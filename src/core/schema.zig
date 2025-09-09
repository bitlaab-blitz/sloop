//! # Bucket Storage Schema
//! - Provides an entry point for all record structures.

const std = @import("std");

const quill = @import("quill");
const Dt = quill.Types;

pub const Model = struct {
    uuid: Dt.CastInto(.Blob, Dt.Slice),
    name: Dt.CastInto(.Text, Dt.Slice),
    data: Dt.CastInto(.Blob, Dt.Slice),
    owned_by: Dt.CastInto(.Text, []const Dt.Slice),
    prov: ?Dt.Bool,
    cat: Dt.Int
};

pub const View = struct {
    uuid: Dt.Slice,
    name: Dt.Slice,
    data: Dt.Slice,
    owned_by: Dt.Any([]const Dt.Slice),
    prov: ?Dt.Bool,
    cat: Dt.Int
};
