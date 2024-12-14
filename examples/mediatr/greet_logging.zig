const std = @import("std");

const greet_reqeuest = @import("greet_command.zig");
const Writer = @import("abstract_writer.zig").Writer;

const mediatr = @import("mediatr.zig");

pub const LoggingBehavior = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn handle(self: *Self, request: *greet_reqeuest.Request, next: mediatr.NextDelegate(greet_reqeuest.Output)) !greet_reqeuest.Output {
        const scope = std.log.scoped(.LoggingBehavior);

        var request_as_str = std.ArrayList(u8).init(self.allocator);
        defer request_as_str.deinit();

        const writer = request_as_str.writer();
        try std.json.stringify(request, .{ .whitespace = .minified }, writer);

        scope.info("call with request: {s} \n", .{request_as_str.items});

        var timer = try std.time.Timer.start();

        const result = next.handle();

        scope.info("operation take: {d:.3}ms\n", .{@as(f64, @floatFromInt(timer.lap())) / std.time.ns_per_ms});

        return result;
    }
};
