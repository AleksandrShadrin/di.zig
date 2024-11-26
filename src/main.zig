const assert = @import("std").testing.expectEqual;

const std = @import("std");
const container = @import("container.zig");
const dependency = @import("dependency.zig");
const service_provider = @import("service_provider.zig");
const builder = @import("builder.zig");

const Generic = @import("generics.zig").Generic;

const er = error{c};
// Example dependency types
pub const Logger = struct {
    sp: *service_provider.ServiceProvider,

    pub fn init(
        sp: *service_provider.ServiceProvider,
        array: *Generic(std.ArrayList, .{u8}),
    ) !Logger {
        _ = array;

        return Logger{
            .sp = sp,
        };
    }

    pub fn do(self: *Logger) !void {
        var scope = self.sp.initScope();
        defer scope.deinit();

        var array: *std.ArrayList(u8) = (try scope.resolve(Generic(std.ArrayList, .{u8}))).generic_payload;
        try array.appendNTimes(22, 10000_000);
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
    try cont.registerSingleton(std.ArrayList);
    // try cont.registerSingleton(std.ArrayHashMap);

    // Register Database as a non-singleton
    try cont.registerTransient(Database);

    var sp = try cont.createServiceProvider();

    var scope = sp.initScope();
    defer scope.deinit();

    // Resolve Logger multiple times; the same instance should be returned
    while (true) {
        const logger1 = try scope.resolve(Logger);

        try scope.sp.unresolve(logger1);
    }

    const generic_container = try scope.resolve(Generic(std.ArrayList, .{u8}));

    var array: *std.ArrayList(u8) = generic_container.generic_payload;
    try array.append(22);
    try array.append(44);

    // Resolve Database multiple times; different instances should be returned
    const db1 = try scope.resolve(Database);
    const db2 = try scope.resolve(Database);

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
    try cont.registerTransient(Logger);
    // Register Database as a non-singleton
    try cont.registerTransient(Database);

    try cont.registerScoped(std.ArrayList);

    var sp = service_provider.ServiceProvider.init(allocator, &cont);
    defer sp.deinit();

    var scope = sp.initScope();

    // Resolve Logger multiple times; the same instance should be returned
    const logger1 = try scope.resolve(Logger);
    sp.unresolve(logger1) catch {};

    const logger2 = try scope.resolve(Logger);
    sp.unresolve(logger2) catch {};

    // Resolve Database multiple times; different instances should be returned
    const db1 = try scope.resolve(Database);
    sp.unresolve(db1) catch {};

    const generic_container = try scope.resolve(Generic(std.ArrayList, .{u8}));

    var array: *std.ArrayList(u8) = generic_container.generic_payload;
    try array.append(22);
    try array.append(44);

    scope.deinit();
}
