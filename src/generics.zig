const std = @import("std");
const utilities = @import("utilities.zig");

pub fn GenericFnWrapper(comptime generic_fn: anytype) type {
    const f_ti = @typeInfo(@TypeOf(generic_fn));

    if (f_ti != .Fn or !f_ti.Fn.is_generic)
        @compileError(@typeName(@TypeOf(generic_fn)) ++ " should be generic fn");

    return struct {
        pub fn GenericContainer(comptime args: anytype) type {
            const inner_type: type = @call(.auto, generic_fn, args);

            return struct {
                const Self = @This();

                comptime generic_fn: @TypeOf(generic_fn) = generic_fn,
                generic_payload: *inner_type,

                pub fn init(payload: *inner_type) Self {
                    return Self{
                        .generic_payload = payload,
                    };
                }
            };
        }
    };
}

pub inline fn isGeneric(comptime T: anytype) bool {
    return @hasField(T, "generic_fn") and
        @hasField(T, "generic_payload");
}

pub inline fn getGenericType(comptime T: anytype) type {
    const f = std.meta.fields(T)[1];
    return utilities.deref(f.type);
}

pub fn getName(comptime T: type) []const u8 {
    const mock: T = undefined;
    return utilities.genericName(mock.generic_fn);
}

pub fn Generic(f: anytype, args: anytype) type {
    const inner_type: type = @call(.auto, f, args);

    return struct {
        const Self = @This();

        comptime generic_fn: @TypeOf(f) = f,
        generic_payload: *inner_type,

        pub fn init(payload: *inner_type) Self {
            return Self{
                .generic_payload = payload,
            };
        }
    };
}
