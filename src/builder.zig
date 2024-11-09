const ServiceProvider = @import("service_provider.zig").ServiceProvider;

const std = @import("std");
const utilities = @import("utilities.zig");

pub fn Builder(comptime T: type) type {
    return struct {
        const Self = @This();

        buildFn: *const fn (sp: *ServiceProvider) anyerror!T,

        pub fn build(self: *Self, sp: *ServiceProvider) !T {
            return try self.buildFn(sp);
        }

        pub fn fromFn(f: *const fn (sp: *ServiceProvider) anyerror!T) Self {
            return .{
                .buildFn = f,
            };
        }

        pub fn fromFnWithNoError(comptime f: fn (sp: *ServiceProvider) T) Self {
            const S = struct {
                pub fn wrapper(sp: *ServiceProvider) !T {
                    return f(sp);
                }
            };

            return .{ .buildFn = S.wrapper };
        }
    };
}
