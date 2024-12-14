const std = @import("std");

const greet_reqeuest = @import("greet_command.zig");
const Writer = @import("abstract_writer.zig").Writer;

pub const GreetHandler = struct {
    const Self = @This();

    writer: *Writer,

    pub fn init(writer: *Writer) Self {
        return Self{
            .writer = writer,
        };
    }

    pub fn handle(self: *Self, request: *greet_reqeuest.Request) !greet_reqeuest.Output {
        try self.writer.writeAll(
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>
        );
        try self.writer.writeAll(
            \\</title></head>
            \\<body>
            \\<h1>Greetings
        );
        try self.writer.writeAll(request.name);
        try self.writer.writeAll(
            \\</h1>
            \\<p>
            \\</body>
            \\</html>
            \\
        );
    }
};
