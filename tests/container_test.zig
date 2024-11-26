const std = @import("std");
const di = @import("di"); // Adjust the path as necessary

const Container = di.Container;
const LifeCycle = di.LifeCycle;
const ContainerError = di.ContainerError;

// Mock Services Definitions
const AllocatorService = struct {
    pub fn init(allocator: std.mem.Allocator) AllocatorService {
        _ = allocator;
        return AllocatorService{};
    }
};

const LoggerService = struct {
    pub fn init() LoggerService {
        return LoggerService{};
    }

    pub fn log(self: *LoggerService, message: []const u8) void {
        // Mock log function
        _ = self;
        _ = message;
    }
};

const DatabaseService = struct {
    allocator: std.mem.Allocator,
    logger: *LoggerService,

    pub fn init(allocator: std.mem.Allocator, logger: *LoggerService) DatabaseService {
        return DatabaseService{
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn query(self: *DatabaseService, sql: []const u8) void {
        // Mock query function
        self.logger.log(sql);
    }
};

// Test Cases

test "Dependency Injection Container - Register and Retrieve Dependencies" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Register AllocatorService as a singleton
    try container.registerSingleton(AllocatorService);

    // Register LoggerService as transient
    try container.registerTransient(LoggerService);

    // Register DatabaseService with a factory function as scoped
    try container.registerScoped(DatabaseService);

    // Verify AllocatorService registration
    var allocatorInfo = container.getDependencyInfo(AllocatorService);
    try std.testing.expect(allocatorInfo != null);
    try std.testing.expectEqualStrings(allocatorInfo.?.getName(), @typeName(AllocatorService));
    try std.testing.expect(allocatorInfo.?.life_cycle == LifeCycle.singleton);

    // Verify LoggerService registration
    var loggerInfo = container.getDependencyInfo(LoggerService);
    try std.testing.expect(loggerInfo != null);
    try std.testing.expectEqualStrings(loggerInfo.?.getName(), @typeName(LoggerService));
    try std.testing.expect(loggerInfo.?.life_cycle == LifeCycle.transient);

    // Verify DatabaseService registration
    var dbInfo = container.getDependencyInfo(DatabaseService);
    try std.testing.expect(dbInfo != null);
    try std.testing.expectEqualStrings(dbInfo.?.getName(), @typeName(DatabaseService));
    try std.testing.expect(dbInfo.?.life_cycle == LifeCycle.scoped);
}

test "Dependency Injection Container - Validate circular dependencies" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Attempt to create a cyclic dependency
    const mock = struct {
        const LoggerServiceWithCycle = struct {
            db: *DatabaseServiceWithCycle,

            pub fn init(db: *DatabaseServiceWithCycle) !LoggerServiceWithCycle {
                return LoggerServiceWithCycle{
                    .db = db,
                };
            }
        };

        const DatabaseServiceWithCycle = struct {
            logger: *LoggerServiceWithCycle,

            pub fn init(logger: *LoggerServiceWithCycle) !DatabaseServiceWithCycle {
                return DatabaseServiceWithCycle{
                    .logger = logger,
                };
            }
        };
    };

    // Register the faulty LoggerServiceWithCycle and DatabaseServiceWithCycle
    try container.registerTransient(mock.LoggerServiceWithCycle);
    try container.registerTransient(mock.DatabaseServiceWithCycle);

    // Attempt to validate dependencies should fail due to cyclic dependency
    const err = container.createServiceProvider() catch |err| err;
    try std.testing.expectError(ContainerError.CircularDependency, err);
}

test "Dependency Injection Container - Validate self circular dependencies" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Attempt to create a cyclic dependency
    const mock = struct {
        const LoggerServiceWithCycle = struct {
            pub fn init(this: *@This()) !LoggerServiceWithCycle {
                _ = this;
                return LoggerServiceWithCycle{};
            }
        };
    };

    // Register the faulty LoggerServiceWithCycle and DatabaseServiceWithCycle
    try container.registerTransient(mock.LoggerServiceWithCycle);

    // Attempt to validate dependencies should fail due to cyclic dependency
    const err = container.createServiceProvider() catch |err| err;
    try std.testing.expectError(ContainerError.CircularDependency, err);
}

test "Dependency Injection Container - Lifecycle Consistency" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Register services with different lifecycles
    try container.registerSingleton(AllocatorService);
    try container.registerScoped(LoggerService);
    try container.registerTransient(DatabaseService);

    // Define a singleton service that depends on a transient service
    const SingletonService = struct {
        db: *DatabaseService,

        pub fn init(db: *DatabaseService) !@This() {
            return @This(){
                .db = db,
            };
        }
    };

    // Register SingletonService with a factory
    try container.registerSingleton(SingletonService);

    // Attempt to validate lifecycle consistency should fail
    const err = container.createServiceProvider() catch |err| err;
    try std.testing.expectError(ContainerError.LifeCycleError, err);
}

test "Dependency Injection Container - Missing Dependency" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Attempt to retrieve an unregistered service
    const dep_info = container.getDependencyInfo(DatabaseService);
    try std.testing.expect(dep_info == null);
}
