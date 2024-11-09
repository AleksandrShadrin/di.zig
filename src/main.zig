const assert = @import("std").testing.expectEqual;

const std = @import("std");
const container = @import("container.zig");
const dependency = @import("dependency.zig");
const service_provider = @import("service_provider.zig");
const builder = @import("builder.zig");

// Example dependency types
pub const Logger = struct {
    pub fn init(sp: *service_provider.ServiceProvider) !Logger {
        // Initialize the Logger
        _ = sp;
        return Logger{};
    }

    pub fn deinit(self: *Logger) void {
        _ = self;
        // Clean up Logger resources
    }
};

pub const Database = struct {
    logger: *Logger,

    pub fn init(sp: *Logger) !Database {
        // Initialize the Database
        return Database{
            .logger = sp,
        };
    }

    pub fn deinit(self: *Database) void {
        _ = self;
        // Clean up Database resources
    }
};

pub fn main() !void {
    var ha = std.heap.HeapAllocator.init();
    const allocator = ha.allocator();

    var cont = container.Container.init(allocator);

    defer cont.deinit();

    // Register Logger as a singleton
    try cont.registerTransient(Logger);

    // Register Database as a non-singleton
    try cont.registerTransient(Database);

    var sp = try cont.createServiceProvider();

    // // Resolve Logger multiple times; the same instance should be returned
    // const logger1 = try sp.resolve(Logger);
    // const logger2 = try sp.resolve(Logger);

    // try sp.unresolve(logger1);
    // try sp.unresolve(logger2);

    // std.debug.print("{any} {any}\n", .{ @intFromPtr(logger1), @intFromPtr(logger2) });
    // // Resolve Database multiple times; different instances should be returned
    // const db1 = try sp.resolve(Database);
    // const db2 = try sp.resolve(Database);

    // _ = db1;
    // _ = db2;

    var s = service_provider.ServiceProviderDependecyResolver(Logger);

    _ = try s.resolve_fn(&sp);

    const f = &service_provider.ServiceProviderDependecyResolver;

    _ = try f(Database).resolve_fn(&sp);
}

test "check for mem leaks" {
    const allocator = std.testing.allocator;

    var cont = container.Container.init(allocator);
    defer cont.deinit();

    // Register Logger as a singleton
    try cont.registerSingleton(Logger);
    // Register Database as a non-singleton
    try cont.registerSingleton(Database);

    var sp = try service_provider.ServiceProvider.init(allocator, &cont);
    defer sp.deinit();

    // Resolve Logger multiple times; the same instance should be returned
    const logger1 = try sp.resolve(Logger);
    defer sp.unresolve(logger1) catch {};

    // Resolve Database multiple times; different instances should be returned
    const db1 = try sp.resolve(Database);
    defer sp.unresolve(db1) catch {};
}
