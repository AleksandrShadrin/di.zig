const std = @import("std");
const utilities = @import("utilities.zig");

const Builder = @import("builder.zig").Builder;

const ServiceProvider = @import("service_provider.zig").ServiceProvider;

const DependencyInfo = @import("dependency.zig").DependencyInfo;
const IDependencyInfo = @import("dependency.zig").IDependencyInfo;
const LifeCycle = @import("dependency.zig").LifeCycle;

const GenericFnWrapper = @import("generics.zig").GenericFnWrapper;

// Define possible errors related to the container
const ContainerError = error{
    ServiceNotFound, // Error when a required service is not found
    TransitiveDependency, // Error when a transitive dependency cycle is detected
    LifeCycleError, // Error when there is a lifecycle mismatch
};

// Container struct manages dependency registrations and resolutions
pub const Container = struct {
    // Hash map storing dependencies indexed by their names
    dependencies: std.StringHashMap(IDependencyInfo),
    // Allocator for memory management
    allocator: std.mem.Allocator,

    const Self = @This();

    // Initialize a new Container with the given allocator
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .dependencies = std.StringHashMap(IDependencyInfo).init(allocator),
            .allocator = allocator,
        };
    }

    // Deinitialize the Container, cleaning up all dependencies
    pub fn deinit(self: *Self) void {
        var iter = self.dependencies.valueIterator();
        while (iter.next()) |ptr| {
            // Call the destroy function for each dependency
            ptr.destroy_fn(ptr.ptr, self.allocator);
        }
        self.dependencies.deinit();
    }

    // Register a singleton dependency
    pub fn registerSingleton(self: *Self, comptime dep: anytype) !void {
        try self.register(dep, .singleton);
    }

    // Register a scoped dependency
    pub fn registerScoped(self: *Self, comptime dep: anytype) !void {
        try self.register(dep, .scoped);
    }

    // Register a transient dependency
    pub fn registerTransient(self: *Self, comptime dep: anytype) !void {
        try self.register(dep, .transient);
    }

    // Register a singleton dependency with a factory function
    pub fn registerSingletonWithFactory(self: *Self, comptime factory: anytype) !void {
        try self.registerWithFactory(factory, .singleton);
    }

    // Register a scoped dependency with a factory function
    pub fn registerScopedWithFactory(self: *Self, comptime factory: anytype) !void {
        try self.registerWithFactory(factory, .scoped);
    }

    // Register a transient dependency with a factory function
    pub fn registerTransientWithFactory(self: *Self, comptime factory: anytype) !void {
        try self.registerWithFactory(factory, .transient);
    }

    // Internal function to register a dependency with a specified lifecycle
    fn register(self: *Self, comptime dep: anytype, life_cycle: LifeCycle) !void {
        switch (@typeInfo(@TypeOf(dep))) {
            .Type => {
                // If the dependency is a type, create a DependencyInfo instance
                const dep_info_ptr = try self.allocator.create(DependencyInfo(*dep));
                dep_info_ptr.* = try DependencyInfo(*dep).init(life_cycle, false);

                // Add the dependency to the hash map
                try self.dependencies.put(dep_info_ptr.name, dep_info_ptr.getInterface());
            },
            .Fn => {
                // If the dependency is a factory function, wrap it and create DependencyInfo
                const dep_info_ptr = try self.allocator.create(DependencyInfo(*GenericFnWrapper(dep)));
                dep_info_ptr.* = try DependencyInfo(*GenericFnWrapper(dep)).init(life_cycle, true);
                dep_info_ptr.*.name = utilities.genericName(dep);

                // Add the dependency to the hash map
                try self.dependencies.put(dep_info_ptr.name, dep_info_ptr.getInterface());
            },
            else => @compileError("dependency unsupported"),
        }
    }

    // Internal function to register a dependency using a factory function with a specified lifecycle
    fn registerWithFactory(self: *Self, comptime factory: anytype, life_cycle: LifeCycle) !void {
        // Determine the return type of the factory function
        const T = utilities.getReturnType(factory);
        const dep_info_ptr = try self.allocator.create(DependencyInfo(*T));

        // Obtain a builder for the dependency
        const builder = try utilities.getBuilder(T, factory);
        dep_info_ptr.* = DependencyInfo(*T).initWithBuilder(builder, life_cycle);

        // Add the dependency to the hash map
        try self.dependencies.put(dep_info_ptr.name, dep_info_ptr.getInterface());
    }

    // Create a ServiceProvider instance after validating dependencies
    pub fn createServiceProvider(self: *Self) !ServiceProvider {
        try validateDependencies(self);
        return ServiceProvider.init(self.allocator, self);
    }

    // Create a ServiceProvider instance with a custom allocator after validating dependencies
    pub fn createServiceProviderWithCustomAllocator(
        self: *Self,
        allocator: std.mem.Allocator,
    ) !ServiceProvider {
        try validateDependencies(self);
        return ServiceProvider.init(allocator, self);
    }

    // Validate all registered dependencies for lifecycle consistency and transitive dependencies
    fn validateDependencies(self: *Self) !void {
        var iter = self.dependencies.valueIterator();

        while (iter.next()) |di| {
            for (di.getDependencies()) |dep| {
                // Initialize a "hash set" to track visited dependencies during transitive checks
                var visited = std.StringHashMap(bool).init(self.allocator);
                defer visited.deinit();

                // Check lifecycle consistency
                try self.checkDependenciesLifeCycles(di);
                // Check for transitive dependency cycles
                try self.checkTransitiveDependencies(di, dep.name, &visited);

                // Verify the dependency information is valid
                di.verify();
            }
        }
    }

    // Helper function to validate if a dependency exists or is allowed as a special case
    fn checkDependencyValid(check: ?IDependencyInfo, dep_name: []const u8) !void {
        if (check == null) {
            // Allow std.mem.Allocator and ServiceProvider as special dependencies
            const is_allocator = std.mem.eql(u8, dep_name, @typeName(std.mem.Allocator));
            const is_sp = std.mem.eql(u8, dep_name, @typeName(ServiceProvider));

            if (is_allocator) {
                return;
            }

            if (is_sp) {
                return;
            }

            // If not a special case and dependency is missing, return an error
            return ContainerError.ServiceNotFound;
        }
    }

    // Check that the lifecycles of dependencies are compatible
    fn checkDependenciesLifeCycles(
        self: *Self,
        check: *IDependencyInfo,
    ) !void {
        const deps = check.getDependencies();

        for (deps) |dep| {
            const dep_info = self.dependencies.get(dep.name);

            // Validate that the dependency exists or is allowed
            try checkDependencyValid(dep_info, dep.name);

            if (dep_info == null) {
                return;
            }

            const life_cycle = self.dependencies.get(dep.name).?.life_cycle;

            // Ensure lifecycle consistency based on the current dependency's lifecycle
            switch (check.life_cycle) {
                .singleton => {
                    if (life_cycle != .singleton) {
                        std.log.warn(
                            "{s} is singleton and has dependency {s} with less lifecycle.",
                            .{ check.getName(), dep.name },
                        );
                        return ContainerError.LifeCycleError;
                    }
                },
                .scoped => {
                    if (life_cycle == .transient) {
                        std.log.warn(
                            "{s} is scoped and has dependency {s} with less lifecycle.",
                            .{ check.getName(), dep.name },
                        );
                        return ContainerError.LifeCycleError;
                    }
                },
                else => {},
            }
        }
    }

    // Check for transitive dependency cycles using a visited set to prevent infinite recursion
    fn checkTransitiveDependencies(
        self: *Self,
        check: *IDependencyInfo,
        dependency_name: []const u8,
        visited: *std.StringHashMap(bool),
    ) !void {
        // If already visited, skip to prevent infinite recursion
        if (visited.contains(dependency_name)) {
            return;
        }

        // Mark the current dependency as visited
        try visited.put(dependency_name, true);

        // Retrieve the dependency information
        var dep_info = self.dependencies.get(dependency_name);

        // Validate that the dependency exists or is allowed
        try checkDependencyValid(dep_info, dependency_name);

        if (dep_info == null) {
            return;
        }

        const deps = dep_info.?.getDependencies();
        for (deps) |dep| {
            // If the dependency directly depends on the initial check, report a transitive dependency error
            if (std.mem.eql(u8, dep.name, check.getName())) {
                return ContainerError.TransitiveDependency;
            }

            // Recursively check transitive dependencies
            try self.checkTransitiveDependencies(check, dep.name, visited);
        }
    }
};
