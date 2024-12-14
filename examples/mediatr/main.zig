const std = @import("std");
const di = @import("di");

const Writer = @import("abstract_writer.zig").Writer;
const Mediatr = @import("mediatr.zig").Mediatr;

const GreetHandler = @import("greet_handler.zig").GreetHandler;
const GreetLogger = @import("greet_logging.zig").LoggingBehavior;

const greet_command = @import("greet_command.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer std.debug.print("{any}\n", .{gpa.deinit()});

    const allocator = gpa.allocator();

    var container = di.Container.init(allocator);
    defer container.deinit();

    // Create controllers for different model types
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
    try Mediatr.addBehavior(&container, GreetLogger);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    var scope = try sp.initScope();
    defer scope.deinit();

    var mediatr = try scope.resolve(Mediatr);
    var req = greet_command.Request{ .name = "Aleksandr" };

    try mediatr.send(
        &req,
        greet_command.Output,
    );
}
