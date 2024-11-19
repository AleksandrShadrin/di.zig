const assert = @import("std").testing.expectEqual;

const std = @import("std");
const container = @import("container.zig");
const dependency = @import("dependency.zig");
const service_provider = @import("service_provider.zig");
const builder = @import("builder.zig");

const Generic = @import("generics.zig").Generic;

// Example dependency types
pub const Logger = struct {
    sp: *service_provider.ServiceProvider,
    array: *std.ArrayList(u8),

    pub fn init(
        sp: *service_provider.ServiceProvider,
        array: *Generic(std.ArrayList, .{u8}),
    ) !Logger {
        // Initialize the Logger
        try array.generic_payload.appendNTimes(22, 1_00);

        return Logger{
            .sp = sp,
            .array = array.generic_payload,
        };
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
    const allocator = std.heap.page_allocator;

    var cont = container.Container.init(allocator);

    defer cont.deinit();

    // Register Logger as a singleton
    try cont.registerTransient(Logger);
    try cont.registerTransient(std.ArrayList);
    // try cont.registerSingleton(std.ArrayHashMap);

    // Register Database as a non-singleton
    try cont.registerTransient(Database);

    var sp = try cont.createServiceProvider();

    // Resolve Logger multiple times; the same instance should be returned
    while (true) {
        const logger1 = try sp.resolve(Logger);
        const logger2 = try sp.resolve(Logger);

        try sp.unresolve(logger1);
        try sp.unresolve(logger2);
    }

    const generic_container = try sp.resolve(Generic(std.ArrayList, .{u8}));

    var array: *std.ArrayList(u8) = generic_container.generic_payload;
    try array.append(22);
    try array.append(44);
    std.debug.print("{any}\n", .{array.items});

    try sp.unresolve(generic_container);

    // Resolve Database multiple times; different instances should be returned
    const db1 = try sp.resolve(Database);
    const db2 = try sp.resolve(Database);

    _ = db1;
    _ = db2;
}

pub fn name() void {}

pub fn Gen(f: *const fn () void, s: type, ff: fn () void) type {
    _ = s;
    _ = f;
    _ = ff;
    return struct {
        const Self = @This();

        name: []const u8,

        pub fn init() Self {
            return Self{};
        }
    };
}

test "check for mem leaks" {
    const allocator = std.testing.allocator;

    var cont = container.Container.init(allocator);
    defer cont.deinit();

    // Register Logger as a singleton
    try cont.registerSingleton(Logger);
    // Register Database as a non-singleton
    try cont.registerSingleton(Database);

    try cont.registerTransient(std.ArrayList);

    var sp = try service_provider.ServiceProvider.init(allocator, &cont);
    defer sp.deinit();

    // Resolve Logger multiple times; the same instance should be returned
    const logger1 = try sp.resolve(Logger);
    defer sp.unresolve(logger1) catch {};

    // Resolve Database multiple times; different instances should be returned
    const db1 = try sp.resolve(Database);
    defer sp.unresolve(db1) catch {};

    const generic_container = try sp.resolve(Generic(std.ArrayList).GenericContainer(.{u8}));

    var array: *std.ArrayList(u8) = generic_container.generic_payload;
    try array.append(22);
    try array.append(44);

    defer sp.unresolve(generic_container) catch {};
}
