const std = @import("std");
const di = @import("di");

const Database = struct {
    logger: *Logger,

    pub fn init(logger: *Logger) !Database {
        return Database{
            .logger = logger,
        };
    }

    pub fn save(self: *Database) !void {
        self.logger.log("Start processing...");
        // logic
        self.logger.log("End processing...");
    }

    pub fn deinit(self: *Database) !void {
        _ = self;
        std.debug.print("unresolving database\n", .{});
    }
};

const Logger = struct {
    max_length: u32 = 1_000,

    pub fn init() Logger {
        return Logger{};
    }

    pub fn log(message: []const u8) !void {
        std.debug.print(message, .{});
    }

    pub fn deinit(self: *Logger) !void {
        _ = self;
        std.debug.print("unresolving logger\n", .{});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    const allocator = gpa.allocator();

    var container = di.Container.init(allocator);
    defer container.deinit();

    try container.registerTransient(Database);
    try container.registerTransient(Logger);

    var sp = try container.createServiceProvider();
    defer {
        std.debug.print("after unresolving\n", .{});
        sp.deinit();
    }

    const db = try sp.resolve(Database);
    try sp.unresolve(db);
}
