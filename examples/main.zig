const std = @import("std");
const di = @import("di");

const Writer = struct {
    write_fn: *const fn ([]const u8) anyerror!void,

    pub fn writeAll(self: @This(), data: []const u8) !void {
        try self.write_fn(data);
    }
};

const App = struct {
    const Self = @This();

    container: *di.Container,
    controller_actions: std.StringHashMap(*const fn (*di.Scope) anyerror!void),

    pub fn init(container: *di.Container, allocator: std.mem.Allocator) !Self {
        try container.registerScoped(Payload);

        return Self{
            .container = container,
            .controller_actions = std.StringHashMap(*const fn (*di.Scope) anyerror!void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.container.deinit();
        self.controller_actions.deinit();
    }

    pub fn addView(self: *Self, path: []const u8, view: type, request: type) !void {
        try self.container.registerScoped(view);

        const adapter = struct {
            pub fn adapt(scope: *di.Scope) !void {
                const v = try scope.resolve(view);
                const payload = try scope.resolve(Payload);

                const request_deserialized = try std.json.parseFromSlice(request, scope.allocator, payload.data.?, .{});
                defer request_deserialized.deinit();

                try v.handle(request_deserialized.value);
            }
        };

        try self.controller_actions.put(path, adapter.adapt);
    }

    pub fn run(self: *Self) !void {
        const route = "/";
        const greet_payload =
            \\{ "name" : "Aleksandr" }
        ;

        var sp = try self.container.createServiceProvider();
        defer sp.deinit();

        while (true) {
            const scope = try sp.initScope();
            defer scope.deinit();

            const payload = try scope.resolve(Payload);
            payload.data = greet_payload;

            const f = self.controller_actions.get(route) orelse return std.debug.print("No action registered", .{});
            try f(scope);

            break;
        }
    }
};

const Payload = struct {
    data: ?[]const u8,

    pub fn init() Payload {
        return Payload{
            .data = null,
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var container = di.Container.init(allocator);

    // Create controllers for different model types
    const GreetView = struct {
        const Self = @This();
        const Request = struct {
            name: []const u8,
        };

        writer: *Writer,

        pub fn init(writer: *Writer) Self {
            return Self{
                .writer = writer,
            };
        }

        pub fn handle(self: *Self, request: Request) !void {
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
            );
        }
    };

    const get_writer = struct {
        pub fn get_writer() Writer {
            return Writer{
                .write_fn = write_fn,
            };
        }

        fn write_fn(data: []const u8) !void {
            const writer = std.io.getStdOut();
            try writer.writeAll(data);
        }
    }.get_writer;

    try container.registerScopedWithFactory(get_writer);

    var app = try App.init(&container, allocator);

    try app.addView("/", GreetView, GreetView.Request);

    try app.run();
    defer app.deinit();
}
