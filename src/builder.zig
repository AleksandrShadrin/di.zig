const ServiceProvider = @import("service_provider.zig").ServiceProvider;

const std = @import("std");
const utilities = @import("utilities.zig");

pub fn Builder(comptime T: type) type {
    return struct {
        const Self = @This();

        buildFn: *const fn (ctx: *anyopaque) anyerror!T,

        pub fn build(self: *Self, ctx: *anyopaque) !T {
            return try self.buildFn(ctx);
        }

        pub fn fromFn(f: *const fn (ctx: *anyopaque) anyerror!T) Self {
            return .{
                .buildFn = f,
            };
        }

        pub fn fromFnWithNoError(comptime f: fn (ctx: *anyopaque) T) Self {
            const S = struct {
                pub fn wrapper(ctx: *anyopaque) !T {
                    return f(ctx);
                }
            };

            return .{ .buildFn = S.wrapper };
        }
    };
}
