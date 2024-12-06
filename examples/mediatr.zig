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

    pub fn addHandler(container: *di.Container, HandlerType: type) !void {
        const handler_fn = @typeInfo(@TypeOf(HandlerType.handle)).Fn;
        comptime var return_type = handler_fn.return_type.?;

        if (@typeInfo(return_type) == .ErrorUnion)
            return_type = @typeInfo(return_type).ErrorUnion.payload;

        if (handler_fn.params.len != 2 or
            handler_fn.params[0].type.? != *HandlerType)
            @compileError(@typeName(HandlerType) ++ " should have handle with signature fn (*Self, ReqeustType)");

        const Request = handler_fn.params[1].type.?;

        try container.registerScoped(HandlerType);

        const create_handler = struct {
            pub fn create_handler(sp: *di.ServiceProvider) !Handler(Request, return_type) {
                const h = try sp.resolve(HandlerType);
                return Handler(Request, return_type){
                    .ctx = h,
                    .handle_fn = call_handler,
                    .deinit_fn = deinit_handler,
                };
            }

            pub fn call_handler(ctx: *anyopaque, request: Request) !return_type {
                const h: *HandlerType = @ptrCast(@alignCast(ctx));
                if (@typeInfo(return_type) == .ErrorUnion) {
                    return try h.handle(request);
                } else {
                    return h.handle(request);
                }
            }

            pub fn deinit_handler(handler: *Handler(Request, return_type), sp: *di.ServiceProvider) !void {
                const h: *HandlerType = @ptrCast(@alignCast(handler.ctx));
                try sp.unresolve(h);
            }
        }.create_handler;

        try container.registerScopedWithFactory(create_handler);
    }

    pub fn send(self: Self, request: anytype, output: type) !output {
        const handler = try self.sp.resolve(Handler(@TypeOf(request), output));
        return try handler.handle(request);
    }
};

pub fn Handler(TIn: type, TOut: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,

        handle_fn: *const fn (*anyopaque, TIn) anyerror!TOut,
        deinit_fn: *const fn (*Self, *di.ServiceProvider) anyerror!void,

        pub fn deinit(self: *Self, sp: *di.ServiceProvider) void {
            self.deinit_fn(self, sp) catch {};
        }

        pub fn handle(self: Self, request: TIn) !TOut {
            return try self.handle_fn(self.ctx, request);
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
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

        const Output = void;

        writer: *Writer,

        pub fn init(writer: *Writer) Self {
            return Self{
                .writer = writer,
            };
        }

        pub fn handle(self: *Self, request: Request) !Output {
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

    try container.registerSingletonWithFactory(get_writer);
    try container.registerScoped(Mediatr);

    try Mediatr.addHandler(&container, GreetHandler);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    var scope = try sp.initScope();
    defer scope.deinit();

    var mediatr = try scope.resolve(Mediatr);

    try mediatr.send(
        GreetHandler.Request{ .name = "Aleksandr" },
        GreetHandler.Output,
    );
}
