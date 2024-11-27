const std = @import("std");
const di = @import("di");

const Container = di.Container;

// Example Services
const Logger = struct {
    pub fn init() Logger {
        return Logger{};
    }

    pub fn log(self: *Logger, message: []const u8) void {
        _ = self;
        std.log.info("{s}", .{message});
    }
};

const Database = struct {
    logger: *Logger,

    pub fn init(logger: *Logger) Database {
        return Database{
            .logger = logger,
        };
    }

    pub fn persist(self: *Database) void {
        self.logger.log("Log some job");
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Register services
    try container.registerSingleton(Logger);
    try container.registerTransient(Database);

    // Create provider
    var provider = try container.createServiceProvider();
    defer provider.deinit();

    // Resolve services
    var db = try provider.resolve(Database);

    // Use services
    db.persist();
}
