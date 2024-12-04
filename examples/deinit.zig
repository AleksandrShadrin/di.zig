const std = @import("std");
const di = @import("di");

const Database = struct {
    logger: *Logger,

    pub fn init(sp: *di.ServiceProvider) !Database {
        // resolving inside, so Logger not tracked by sp
        const logger = try sp.resolve(Logger);
        return Database{
            .logger = logger,
        };
    }

    pub fn save(self: *Database) !void {
        self.logger.log("Start processing...");
        // logic
        self.logger.log("End processing...");
    }

    pub fn deinit(self: *Database, sp: *di.ServiceProvider) !void {
        // manually deleting in case of Logger has transient lifecycle, else it will return error
        std.debug.print("unresolving database\n", .{});
        sp.unresolve(self.logger) catch |err| {
            if (err == di.ServiceProviderError.UnresolveLifeCycleShouldBeTransient) {
                std.debug.print("Logger was singleton or scoped\n", .{});
                return;
            }

            return err;
        };
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
