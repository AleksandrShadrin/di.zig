pub const Writer = struct {
    write_fn: *const fn ([]const u8) anyerror!void,

    pub fn writeAll(self: @This(), data: []const u8) !void {
        try self.write_fn(data);
    }
};
