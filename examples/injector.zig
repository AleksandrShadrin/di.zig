const std = @import("std");
const di = @import("di");

pub fn MakeInjectable(f: anytype) type {
    const ti = @typeInfo(@TypeOf(f)).Fn;
    comptime var return_type = @typeInfo(@TypeOf(f)).Fn.return_type.?;

    if (@typeInfo(return_type) == .ErrorUnion)
        return_type = @typeInfo(return_type).ErrorUnion.payload;

    const Self: ?type = if (ti.params.len == 0) null else ti.params[0].type;

    return struct {
        fn call(sp: *di.ServiceProvider) !return_type {
            var call_tuple: std.meta.ArgsTuple(@TypeOf(f)) = undefined;

            inline for (call_tuple, 0..) |arg, i| {
                const arg_type = @TypeOf(arg);

                if (@typeInfo(arg_type) != .Pointer)
                    @compileError(@typeName(arg_type) ++ " should be pointer");

                call_tuple[i] = try sp.resolve(@typeInfo(arg_type).Pointer.child);
                errdefer sp.unresolve(call_tuple[i]);
            }

            if (@typeInfo(return_type) == .ErrorUnion) {
                return try @call(.auto, f, call_tuple);
            } else {
                return @call(.auto, f, call_tuple);
            }
        }

        fn callWithSelf(self: Self.?, sp: *di.ServiceProvider) !return_type {
            var call_tuple: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
            call_tuple[0] = self;

            inline for (1..call_tuple.len) |i| {
                const arg_type = @TypeOf(call_tuple[i]);

                if (@typeInfo(arg_type) != .Pointer)
                    @compileError(@typeName(arg_type) ++ " should be pointer");

                call_tuple[i] = try sp.resolve(@typeInfo(arg_type).Pointer.child);
                errdefer sp.unresolve(call_tuple[i]);
            }

            if (@typeInfo(return_type) == .ErrorUnion) {
                return try @call(.auto, f, call_tuple);
            } else {
                return @call(.auto, f, call_tuple);
            }
        }
    };
}

const Database = struct {
    logger: *Logger,

    pub fn init(logger: *Logger) Database {
        return Database{
            .logger = logger,
        };
    }
};

const Logger = struct {
    pub fn init() Logger {
        return Logger{};
    }
};

const SomeStruct = struct {
    pub fn haveDependencies(self: *SomeStruct, logger: *Logger, database: *Database) !void {
        _ = self;
        _ = logger;
        _ = database;

        std.debug.print("called here with self\n", .{});
    }
};

pub fn haveDependencies(database: *Database) !void {
    _ = database;
    std.debug.print("called here\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer std.debug.print("{any}\n", .{gpa.deinit()});

    const allocator = gpa.allocator();

    var container = di.Container.init(allocator);
    defer container.deinit();

    try container.registerTransient(Database);
    try container.registerTransient(Logger);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    comptime var injector = MakeInjectable(SomeStruct.haveDependencies);
    var someStruct = SomeStruct{};

    try injector.callWithSelf(&someStruct, &sp);

    injector = MakeInjectable(haveDependencies);
    try injector.call(&sp);
}
