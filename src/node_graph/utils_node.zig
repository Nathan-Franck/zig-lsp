const std = @import("std");
const utils = @import("../utils.zig");

/// Provides an interface a system can send to a function, where the function, when retrieving the containing
/// value will signal to the external system that the value has been retrieved.
/// For the NodeGraph, this Queryable can be used to retrieve values within a branch of the node's logic,
/// so that if the node has chosen a different branch, the value doesn't have to be considered when marking
/// the node as dirty.
pub const queryable = struct {
    pub fn isValue(candidate: type) bool {
        return switch (@typeInfo(candidate)) {
            .@"struct" => @hasDecl(candidate, "QueryableSource"),
            else => false,
        };
    }
    pub fn getSourceOrNull(candidate: type) ?type {
        return if (isValue(candidate))
            @field(candidate, "QueryableSource")
        else
            null;
    }

    pub fn Value(T: type) type {
        return struct {
            pub const QueryableSource = T;

            /// WARNING: If you access this value directy, it will not signal that it has been observed
            _raw: T,

            queried: *bool,
            previous: ?T,

            pub fn get(self: @This()) T {
                self.queried.* = true;
                return self._raw;
            }

            pub fn initQueryable(
                value: T,
                previous_value: ?T,
                is_field_dirty: *bool,
                queried: *bool,
            ) @This() {
                if (!queried.*)
                    is_field_dirty.* = false;
                if (is_field_dirty.*)
                    queried.* = false;
                return @This(){ ._raw = value, .previous = previous_value, .queried = queried };
            }
        };
    }
};
