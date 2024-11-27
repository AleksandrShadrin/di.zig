const std = @import("std");
const di = @import("di");

const Container = di.Container;
const LifeCycle = di.LifeCycle;
const ContainerError = di.ContainerError;

// Mock Services Definitions
const AllocatorService = struct {
    pub fn init(allocator: std.mem.Allocator) AllocatorService {
        _ = allocator;
        return AllocatorService{};
    }

    pub fn builder() AllocatorService {
        return AllocatorService{};
    }

    pub fn builder_with_sp(sp: *di.ServiceProvider) AllocatorService {
        _ = sp;
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

test "Dependency Injection Container - Should register services with custom builder fn" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Register AllocatorService as a singleton with no args builder
    try container.registerSingletonWithFactory(AllocatorService.builder);

    // Verify AllocatorService registration
    var allocatorInfo = container.getDependencyInfo(AllocatorService);
    try std.testing.expect(allocatorInfo != null);
    try std.testing.expectEqualStrings(allocatorInfo.?.getName(), @typeName(AllocatorService));
    try std.testing.expect(allocatorInfo.?.life_cycle == LifeCycle.singleton);

    try container.registerSingletonWithFactory(AllocatorService.builder_with_sp);

    // Verify AllocatorService registration with *ServiceProvider arg
    var loggerInfo = container.getDependencyInfo(AllocatorService);
    try std.testing.expect(loggerInfo != null);
    try std.testing.expectEqualStrings(loggerInfo.?.getName(), @typeName(AllocatorService));
    try std.testing.expect(loggerInfo.?.life_cycle == LifeCycle.singleton);
}

// Test Cases
test "Dependency Injection Container - Register and retrieve dependencies" {
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

test "Dependency Injection Container - Validate direct circular dependencies" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Attempt to create a cyclic dependency
    const direct_cycle = @import("assets/direct_cycle.zig");

    // Register the faulty LoggerServiceWithCycle and DatabaseServiceWithCycle
    try container.registerTransient(direct_cycle.A);
    try container.registerTransient(direct_cycle.B);

    // Attempt to validate dependencies should fail due to cyclic dependency
    const err = container.createServiceProvider() catch |err| err;
    try std.testing.expectError(ContainerError.CircularDependency, err);
}

test "Dependency Injection Container - Validate indirect circular dependencies" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Attempt to create a cyclic dependency
    const direct_cycle = @import("assets/indirect_cycle.zig");

    // Register the faulty LoggerServiceWithCycle and DatabaseServiceWithCycle
    try container.registerTransient(direct_cycle.A);
    try container.registerTransient(direct_cycle.B);
    try container.registerTransient(direct_cycle.C);

    // Attempt to validate dependencies should fail due to cyclic dependency
    const err = container.createServiceProvider() catch |err| err;
    try std.testing.expectError(ContainerError.CircularDependency, err);
}

test "Dependency Injection Container - Validate self circular dependencies" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Attempt to create a cyclic dependency
    const self_cycle = @import("assets/self_cycle.zig");

    // Register the faulty LoggerServiceWithCycle and DatabaseServiceWithCycle
    try container.registerTransient(self_cycle.A);

    // Attempt to validate dependencies should fail due to cyclic dependency
    const err = container.createServiceProvider() catch |err| err;
    try std.testing.expectError(ContainerError.CircularDependency, err);
}

test "Dependency Injection Container - Lifecycle consistency" {
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

test "Dependency Injection Container - Missing dependency" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Attempt to retrieve an unregistered service
    const dep_info = container.getDependencyInfo(DatabaseService);
    try std.testing.expect(dep_info == null);
}
