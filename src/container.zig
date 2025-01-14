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

    dependencies: std.StringHashMap(*IDependencyInfo),
    factories: std.StringHashMap(std.ArrayList(*IDependencyInfo)),

    allocator: std.mem.Allocator,

    mutex: Mutex = Mutex{},

    pub fn init(allocator: std.mem.Allocator) Container {
        return Container{
            .dependencies = std.StringHashMap(*IDependencyInfo).init(allocator),
            .factories = std.StringHashMap(std.ArrayList(*IDependencyInfo)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Container) void {
        var dep_iter = self.dependencies.valueIterator();
        while (dep_iter.next()) |dep_info| {
            dep_info.*.destroy(self.allocator);
            self.allocator.destroy(dep_info.*);
        }

        var factory_iter = self.factories.valueIterator();
        while (factory_iter.next()) |factories| {
            for (factories.items) |factory_info| {
                factory_info.destroy(self.allocator);
                self.allocator.destroy(factory_info);
            }

            factories.deinit();
        }

        self.dependencies.deinit();
        self.factories.deinit();
    }

    // Internal function to register a dependency with a specified lifecycle
    fn register(self: *Self, comptime dep: anytype, life_cycle: LifeCycle) !void {
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
        const ReturnType = utilities.getReturnType(Factory);

        var dep_info = try self.allocator.create(DependencyInfo(*ReturnType));
        errdefer self.allocator.destroy(dep_info);

        const builder = try utilities.getBuilder(ReturnType, Factory);
        dep_info.* = DependencyInfo(*ReturnType).initWithBuilder(builder, lifecycle);

        try self.addFactory(dep_info.getInterface());
    }

    fn addDependency(self: *Self, di: IDependencyInfo) !void {
        const get_result = try self.dependencies.getOrPut(di.getName());

        const ptr = try self.allocator.create(IDependencyInfo);
        ptr.* = di;

        errdefer self.allocator.destroy(ptr);

        if (get_result.found_existing) {
            get_result.value_ptr.*.destroy(self.allocator);
            self.allocator.destroy(get_result.value_ptr.*);
        }

        get_result.value_ptr.* = ptr;
    }

    fn addFactory(self: *Self, di: IDependencyInfo) !void {
        const get_result = try self.factories.getOrPut(di.getName());

        const ptr = try self.allocator.create(IDependencyInfo);
        ptr.* = di;

        errdefer self.allocator.destroy(ptr);

        if (get_result.found_existing) {
            return try get_result.value_ptr.append(ptr);
        }

        var factories = std.ArrayList(*IDependencyInfo).init(self.allocator);
        errdefer factories.deinit();

        try factories.append(ptr);
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
        factories: []*IDependencyInfo,
    };

    pub fn getDependencyWithFactories(self: *Self, comptime T: type) !DependencyWithFactories {
        return .{
            .dependency = if (generics.isGeneric(T)) try getOrAddGeneric(self, T) else self.dependencies.get(@typeName(T)),
            .factories = self.getFactories(T),
        };
    }

    pub fn getDependencyInfo(self: *Self, comptime T: type) ?*IDependencyInfo {
        const typeName = @typeName(T);
        return self.getDependencyInfoByName(typeName);
    }

    fn getDependencyInfoByName(self: *Self, typeName: []const u8) ?*IDependencyInfo {
        const dep_ptr = self.dependencies.get(typeName);

        if (dep_ptr != null)
            return dep_ptr;

        const factories = self.factories.get(typeName) orelse return null;
        return factories.items[factories.items.len - 1];
    }

    fn getFactoriesByName(self: *Self, name: []const u8) []*IDependencyInfo {
        const factories = self.factories.getPtr(name) orelse return &.{};

        return factories.items;
    }

    fn getFactories(self: *Self, comptime T: type) []*IDependencyInfo {
        return self.getFactoriesByName(@typeName(T));
    }

    pub fn getGenericWrapper(self: *Self, comptime T: type) ?*IDependencyInfo {
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

        var visited = std.AutoHashMap(*IDependencyInfo, void).init(self.allocator);
        defer visited.deinit();

        while (iter.next()) |di| {
            defer visited.clearRetainingCapacity();
            try visited.put(di.*, undefined);

            for (di.*.getDependencies()) |dep| {
                try dep.verify_behavior(self, di.*.life_cycle, &visited);
            }
        }
    }
};

// internal methods
pub fn getOrAddGeneric(self: *Container, comptime T: type) !*IDependencyInfo {
    self.mutex.lock();
    defer self.mutex.unlock();

    return try nonBlockingGetOrAddGeneric(self, T);
}

pub fn nonBlockingGetOrAddGeneric(self: *Container, comptime T: type) !*IDependencyInfo {
    const inner_type: type = generics.getGenericType(T);

    // Retrieve the dependency interface for the generic type from the container.
    const generic_di_interface = self.getGenericWrapper(T);

    // Check if the inner type and the generic type are already registered.
    const concrete_di_interface = self.getDependencyInfo(inner_type);
    const container_di_interface = self.getDependencyInfo(T);

    if (generic_di_interface == null and
        concrete_di_interface == null)
        return ContainerError.ServiceNotFound;

    if (container_di_interface != null and
        concrete_di_interface != null)
        return container_di_interface.?;

    const life_cycle = if (concrete_di_interface != null) concrete_di_interface.?.life_cycle else generic_di_interface.?.life_cycle;

    // If the generic type itself is not registered, register it based on its lifecycle.
    var registered = false;
    if (container_di_interface == null) {
        try self.register(T, life_cycle);
        registered = true;
    }

    // If the inner type is not registered, register it based on its lifecycle.
    if (concrete_di_interface == null) {
        try self.register(inner_type, life_cycle);
        registered = true;
    }

    const dep_info = self.getDependencyInfo(T).?;
    errdefer {
        _ = self.dependencies.remove(dep_info.getName());

        dep_info.destroy(self.allocator);
        self.allocator.destroy(dep_info);
    }

    if (registered) {
        var visited = std.AutoHashMap(*IDependencyInfo, void).init(self.allocator);
        defer visited.deinit();

        try visited.put(dep_info, undefined);

        for (dep_info.getDependencies()) |dep| {
            try dep.verify_behavior(self, dep_info.life_cycle, &visited);
        }
    }

    return dep_info;
}
