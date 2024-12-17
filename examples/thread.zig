const std = @import("std");
const di = @import("di");

const Counter = struct {
    count: usize = 0,
    mutex: std.Thread.Mutex = std.Thread.Mutex{},

    pub fn init() Counter {
        return .{};
    }

    pub fn inc(self: *Counter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.count += 1;
    }
};

const Logger = struct {
    mutex: std.Thread.Mutex = std.Thread.Mutex{},

    pub fn init() Logger {
        return Logger{};
    }

    pub fn log(self: *Logger, message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try std.io.getStdOut().writeAll(message);
    }
};

const Database = struct {
    logger: *Logger,
    counter: *Counter,

    pub fn init(logger: *Logger, counter: *Counter) !Database {
        return Database{
            .logger = logger,
            .counter = counter,
        };
    }

    pub fn save(self: *Database) !void {
        try self.logger.log("Start processing...\n");

        self.counter.inc();

        try self.logger.log("End processing...\n");
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer std.debug.print("{any}\n", .{gpa.deinit()});

    const allocator = gpa.allocator();

    var container = di.Container.init(allocator);
    defer container.deinit();

    try container.registerTransient(Database);
    try container.registerSingleton(Logger);
    try container.registerSingleton(Counter);

    var sp = try container.createServiceProvider();

    defer sp.deinit();

    var timer = try std.time.Timer.start();
    var threads: [8]std.Thread = undefined;

    for (0..8) |i| {
        threads[i] = try std.Thread.spawn(.{}, threadFn, .{&sp});
    }

    for (threads) |thread| {
        thread.join();
    }

    std.debug.print("operation take: {d:.3}ms\n", .{@as(f64, @floatFromInt(timer.lap())) / std.time.ns_per_ms});
    std.debug.print("counter : {d}\n", .{(try sp.resolve(Counter)).count});
}

fn threadFn(sp: *di.ServiceProvider) !void {
    var arena = std.heap.ArenaAllocator.init(sp.allocator);
    defer arena.deinit();

    var scope = try sp.initScopeWithAllocator(arena.allocator());
    defer scope.deinit();

    for (0..1_000) |_| {
        const db = try scope.resolve(Database);
        try db.save();

        try scope.sp.unresolve(db);
    }
}
