const std = @import("std");
const di = @import("di");

const Writer = struct {
    write_fn: *const fn ([]const u8) anyerror!void,

    pub fn writeAll(self: @This(), data: []const u8) !void {
        try self.write_fn(data);
    }
};

const Mediatr = struct {
    const Self = @This();

    sp: *di.ServiceProvider,

    pub fn init(sp: *di.ServiceProvider) Self {
        return Self{
            .sp = sp,
        };
    }

    pub fn addHandler(container: *di.Container, HandlerType: type, Request: type) !void {
        try container.registerScoped(HandlerType);

        const create_handler = struct {
            pub fn create_handler(sp: *di.ServiceProvider) !Handler(Request) {
                const h = try sp.resolve(HandlerType);
                return Handler(Request){
                    .ctx = h,
                    .handle_fn = call_handler,
                    .deinit_fn = deinit_handler,
                    .sp = sp,
                };
            }

            pub fn call_handler(ctx: *anyopaque, request: Request) !void {
                const h: *HandlerType = @ptrCast(@alignCast(ctx));
                try h.handle(request);
            }

            pub fn deinit_handler(handler: *Handler(Request)) !void {
                const h: *HandlerType = @ptrCast(@alignCast(handler.ctx));
                try handler.sp.unresolve(h);
            }
        }.create_handler;

        try container.registerScopedWithFactory(create_handler);
    }

    pub fn send(self: Self, request: anytype) !void {
        const handler = try self.sp.resolve(Handler(@TypeOf(request)));
        try handler.handle(request);
    }
};

pub fn Handler(Request: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,
        sp: *di.ServiceProvider,

        handle_fn: *const fn (*anyopaque, Request) anyerror!void,
        deinit_fn: *const fn (*Self) anyerror!void,

        pub fn deinit(self: *Self) void {
            self.deinit_fn(self) catch {};
        }

        pub fn handle(self: Self, request: Request) !void {
            try self.handle_fn(self.ctx, request);
        }
    };
}

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
    defer container.deinit();

    // Create controllers for different model types
    const GreetHandler = struct {
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
    try container.registerScoped(Mediatr);

    try Mediatr.addHandler(&container, GreetHandler, GreetHandler.Request);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    var scope = try sp.initScope();
    defer scope.deinit();

    var mediatr = try scope.resolve(Mediatr);

    try mediatr.send(GreetHandler.Request{
        .name = "Aleksandr",
    });
}
