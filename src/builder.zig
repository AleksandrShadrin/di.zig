const ServiceProvider = @import("service_provider.zig").ServiceProvider;

const std = @import("std");
const utilities = @import("utilities.zig");

pub fn Builder(comptime T: type) type {
    return struct {
        const Self = @This();

        buildFn: *const fn (sp: *anyopaque) anyerror!T,

        pub fn build(self: *Self, sp: *anyopaque) !T {
            return try self.buildFn(sp);
        }

        pub fn fromFn(f: *const fn (sp: *anyopaque) anyerror!T) Self {
            return .{
                .buildFn = f,
            };
        }

        pub fn fromFnWithNoError(comptime f: fn (sp: *anyopaque) T) Self {
            const S = struct {
                pub fn wrapper(sp: *anyopaque) !T {
                    return f(sp);
                }
            };

            return .{ .buildFn = S.wrapper };
        }
    };
}
