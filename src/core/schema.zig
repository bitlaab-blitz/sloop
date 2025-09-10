//! # Bucket Storage Schema
//! - Provides an entry point for all record structures.

const std = @import("std");

const quill = @import("quill");
const Dt = quill.Types;

pub const Filter = struct { uuid: Dt.Slice };

pub const Model = struct {
    uuid: Dt.CastInto(.Text, Dt.Slice),
    name: Dt.CastInto(.Text, Dt.Slice),
    data: Dt.CastInto(.Blob, Dt.Slice),
    owned_by: Dt.CastInto(.Text, []const Dt.Slice),
    size: Dt.Int,
    cat: Dt.Int
};

pub const ModelProvision = struct {
    uuid: Dt.CastInto(.Text, Dt.Slice),
    name: Dt.CastInto(.Text, Dt.Slice),
    data: Dt.CastInto(.BlobLen, Dt.Int),
    owned_by: Dt.CastInto(.Text, []const Dt.Slice),
    size: Dt.Int,
    cat: Dt.Int
};

pub const ViewData = struct { data: Dt.Slice };

pub const ViewInfo = struct {
    rowid: Dt.Int,
    name: Dt.Slice,
    owned_by: Dt.Any([]const Dt.Slice),
    size: Dt.Int,
    cat: Dt.Int
};