const std = @import("std");
const utilities = @import("utilities.zig");

const Builder = @import("builder.zig").Builder;
const ServiceProvider = @import("service_provider.zig").ServiceProvider;
const DependencyInfo = @import("dependency.zig").DependencyInfo;
const IDependencyInfo = @import("dependency.zig").IDependencyInfo;
const LifeCycle = @import("dependency.zig").LifeCycle;

const generics = @import("generics.zig");
const GenericWrapper = generics.GenericFnWrapper;

const Mutex = std.Thread.Mutex;

// Define possible errors related to the container
pub const ContainerError = error{
    ServiceNotFound, // Error when a required service is not found
    CircularDependency, // Error when a transitive dependency cycle is detected
    LifeCycleError, // Error when there is a lifecycle mismatch
};

// Container struct manages dependency registrations and resolutions
pub const Container = struct {
    const Self = @This();

    dependencies: std.StringHashMap(IDependencyInfo),
    factories: std.StringHashMap(std.ArrayList(IDependencyInfo)),

    allocator: std.mem.Allocator,

    mutex: Mutex = Mutex{},

    pub fn init(allocator: std.mem.Allocator) Container {
        return Container{
            .dependencies = std.StringHashMap(IDependencyInfo).init(allocator),
            .factories = std.StringHashMap(std.ArrayList(IDependencyInfo)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Container) void {
        var dep_iter = self.dependencies.valueIterator();
        while (dep_iter.next()) |dep_info| {
            dep_info.destroy(self.allocator);
        }

        var factory_iter = self.factories.valueIterator();
        while (factory_iter.next()) |factories| {
            for (factories.items) |factory_info| {
                factory_info.destroy(self.allocator);
            }

            factories.deinit();
        }

        self.dependencies.deinit();
        self.factories.deinit();
    }

    // Internal function to register a dependency with a specified lifecycle
    fn register(self: *Self, comptime dep: anytype, life_cycle: LifeCycle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (@typeInfo(@TypeOf(dep))) {
            .Type => {
                // If the dependency is a type, create a DependencyInfo instance
                const dep_info_ptr = try self.allocator.create(DependencyInfo(*dep));
                errdefer self.allocator.destroy(dep_info_ptr);
                dep_info_ptr.* = try DependencyInfo(*dep).init(life_cycle, false);

                // Add the dependency to the hash map
                try self.addDependency(dep_info_ptr.getInterface());
            },
            .Fn => {
                // If the dependency is a factory function, wrap it and create DependencyInfo
                const dep_info_ptr = try self.allocator.create(DependencyInfo(*GenericWrapper(dep)));
                errdefer self.allocator.destroy(dep_info_ptr);

                dep_info_ptr.* = try DependencyInfo(*GenericWrapper(dep)).init(life_cycle, true);
                dep_info_ptr.*.name = utilities.genericName(dep);

                // Add the dependency to the hash map
                try self.addDependency(dep_info_ptr.getInterface());
            },
            else => @compileError("dependency unsupported"),
        }
    }

    // Generic registration with factory function
    pub fn registerWithFactory(self: *Container, Factory: anytype, lifecycle: LifeCycle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ReturnType = utilities.getReturnType(Factory);

        var dep_info = try self.allocator.create(DependencyInfo(*ReturnType));
        errdefer self.allocator.destroy(dep_info);

        const builder = try utilities.getBuilder(ReturnType, Factory);
        dep_info.* = DependencyInfo(*ReturnType).initWithBuilder(builder, lifecycle);

        try self.addFactory(dep_info.getInterface());
    }

    fn addDependency(self: *Self, di: IDependencyInfo) !void {
        const get_result = try self.dependencies.getOrPut(di.getName());

        if (get_result.found_existing)
            get_result.value_ptr.destroy(self.allocator);

        get_result.value_ptr.* = di;
    }

    fn addFactory(self: *Self, di: IDependencyInfo) !void {
        const get_result = try self.factories.getOrPut(di.getName());

        if (get_result.found_existing)
            return try get_result.value_ptr.append(di);

        var factories = std.ArrayList(IDependencyInfo).init(self.allocator);
        errdefer factories.deinit();

        try factories.append(di);
        get_result.value_ptr.* = factories;
    }

    pub fn registerSingleton(self: *Self, comptime Dep: anytype) !void {
        try self.register(Dep, .singleton);
    }

    pub fn registerScoped(self: *Self, comptime Dep: anytype) !void {
        try self.register(Dep, .scoped);
    }

    pub fn registerTransient(self: *Self, comptime Dep: anytype) !void {
        try self.register(Dep, .transient);
    }

    pub fn registerSingletonWithFactory(self: *Self, Factory: anytype) !void {
        try self.registerWithFactory(Factory, .singleton);
    }

    pub fn registerScopedWithFactory(self: *Self, Factory: anytype) !void {
        try self.registerWithFactory(Factory, .scoped);
    }

    pub fn registerTransientWithFactory(self: *Self, Factory: anytype) !void {
        try self.registerWithFactory(Factory, .transient);
    }

    const DependencyWithFactories = struct {
        dependency: ?*IDependencyInfo,
        factories: []const IDependencyInfo,
    };

    pub fn getDependencyWithFactories(self: *Self, comptime T: type) DependencyWithFactories {
        return .{
            .dependency = self.getDependencyInfo(T),
            .factories = self.getFactories(T),
        };
    }

    // New Feature: Retrieve IDependencyInfo by type T
    pub fn getDependencyInfo(self: *Self, comptime T: type) ?*IDependencyInfo {
        const typeName = @typeName(T);
        return self.getDependencyInfoByName(typeName);
    }

    fn getDependencyInfoByName(self: *Self, typeName: []const u8) ?*IDependencyInfo {
        const dep_ptr = self.dependencies.getPtr(typeName);

        if (dep_ptr != null)
            return dep_ptr;

        const factories = self.factories.getPtr(typeName) orelse return null;
        return &factories.items[factories.items.len - 1];
    }

    fn getFactories(self: *Self, comptime T: type) []const IDependencyInfo {
        const typeName = @typeName(T);
        const factories = self.factories.getPtr(typeName) orelse return &.{};

        return factories.items;
    }

    pub fn getGenericWrapper(self: *Self, comptime T: type) ?IDependencyInfo {
        if (!generics.isGeneric(T))
            @compileError(@typeName(T) ++ " not a generic");

        return self.dependencies.get(generics.getName(T));
    }

    // Create a ServiceProvider instance after validating dependencies
    pub fn createServiceProvider(self: *Self) !ServiceProvider {
        try self.validateDependencies();
        return ServiceProvider.init(self.allocator, self);
    }

    pub fn createServiceProviderWithCustomAllocator(self: *Container, allocator: std.mem.Allocator) !ServiceProvider {
        try self.validateDependencies();
        return ServiceProvider.init(allocator, self);
    }

    // Validate all registered dependencies for lifecycle consistency and transitive dependencies
    fn validateDependencies(self: *Container) !void {
        var iter = self.dependencies.valueIterator();

        while (iter.next()) |di| {
            for (di.getDependencies()) |dep| {
                var visited = std.StringHashMap(bool).init(self.allocator);
                defer visited.deinit();

                if (!dep.shouldSkip()) {
                    try self.checkTransitiveDependencies(di, dep.name, &visited);
                    try self.checkDependenciesLifeCycles(di);
                }
            }
        }
    }

    // Helper function to validate if a dependency exists or is allowed as a special case
    fn checkDependencyValid(check: ?*IDependencyInfo, dep_name: []const u8) !void {
        if (check == null) {
            const is_allocator = std.mem.eql(u8, dep_name, @typeName(std.mem.Allocator));
            const is_sp = std.mem.eql(u8, dep_name, @typeName(ServiceProvider));

            if (is_allocator or is_sp) return;
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
            const dep_info = self.getDependencyInfoByName(dep.name);

            // Validate that the dependency exists or is allowed
            if (!dep.shouldSkip()) try checkDependencyValid(dep_info, dep.name);

            if (dep_info == null) {
                return;
            }

            const life_cycle = dep_info.?.life_cycle;

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
        var dep_info = self.getDependencyInfoByName(dependency_name);

        // Validate that the dependency exists or is allowed
        try checkDependencyValid(dep_info, dependency_name);

        if (dep_info == null) {
            return;
        }

        const deps = dep_info.?.getDependencies();
        for (deps) |dep| {
            // If the dependency directly depends on the initial check, report a transitive dependency error
            if (std.mem.eql(u8, dep.name, check.getName())) {
                return ContainerError.CircularDependency;
            }

            // Recursively check transitive dependencies
            if (!dep.shouldSkip()) try self.checkTransitiveDependencies(check, dep.name, visited);
        }
    }
};
