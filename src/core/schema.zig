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
    owner: Dt.CastInto(.Text, []const Dt.Slice),
    access: Dt.CastInto(.Text, []const Dt.Slice),
    size: Dt.Int,
    cat: Dt.Int
};

pub const ModelProvision = struct {
    uuid: Dt.CastInto(.Text, Dt.Slice),
    name: Dt.CastInto(.Text, Dt.Slice),
    data: Dt.CastInto(.BlobLen, Dt.Int),
    owner: Dt.CastInto(.Text, []const Dt.Slice),
    access: Dt.CastInto(.Text, []const Dt.Slice),
    size: Dt.Int,
    cat: Dt.Int
};

pub const ModelOwner = struct {
    owner: Dt.CastInto(.Text, []const Dt.Slice)
};

pub const ModelAccess = struct {
    access: Dt.CastInto(.Text, []const Dt.Slice)
};

pub const ViewData = struct { data: Dt.Slice };

pub const ViewInfo = struct {
    rowid: Dt.Int,
    name: Dt.Slice,
    owner: Dt.Any([]const Dt.Slice),
    access: Dt.Any([]const Dt.Slice),
    size: Dt.Int,
    cat: Dt.Int
};