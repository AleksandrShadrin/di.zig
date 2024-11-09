const std = @import("std");
const utilities = @import("utilities.zig");

const Builder = @import("builder.zig").Builder;

const ServiceProvider = @import("service_provider.zig").ServiceProvider;

const DependencyInfo = @import("dependency.zig").DependencyInfo;
const IDependencyInfo = @import("dependency.zig").IDependencyInfo;
const LifeCycle = @import("dependency.zig").LifeCycle;

const ContainerError = error{ ServiceNotFound, TransitiveDependency, LifeCycleError };

pub const Container = struct {
    dependencies: std.StringHashMap(IDependencyInfo),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .dependencies = std.StringHashMap(IDependencyInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.dependencies.valueIterator();
        while (iter.next()) |ptr| {
            ptr.destroy_fn(ptr.ptr, self.allocator);
        }
        self.dependencies.deinit();
    }

    pub fn registerSingleton(self: *Self, comptime dep: type) !void {
        try self.register(dep, .singleton);
    }

    pub fn registerScoped(self: *Self, comptime dep: type) !void {
        try self.register(dep, .scoped);
    }

    pub fn registerTransient(self: *Self, comptime dep: type) !void {
        try self.register(dep, .transient);
    }

    pub fn registerSingletonWithFactory(self: *Self, comptime factory: anytype) !void {
        try self.registerWithFactory(factory, .singleton);
    }

    pub fn registerScopedWithFactory(self: *Self, comptime factory: anytype) !void {
        try self.registerWithFactory(factory, .scoped);
    }

    pub fn registerTransientWithFactory(self: *Self, comptime factory: anytype) !void {
        try self.registerWithFactory(factory, .transient);
    }

    fn register(self: *Self, comptime dep: type, life_cycle: LifeCycle) !void {
        const dep_info_ptr = try self
            .allocator
            .create(DependencyInfo(dep));

        dep_info_ptr.* = try DependencyInfo(dep).init(life_cycle);

        try self.dependencies.put(dep_info_ptr.name, dep_info_ptr.getInterface());
    }

    fn registerWithFactory(self: *Self, comptime factory: anytype, life_cycle: LifeCycle) !void {
        const T = utilities.getReturnType(factory);
        const dep_info_ptr = try self
            .allocator
            .create(DependencyInfo(T));

        const builder = try utilities.getBuilder(T, factory);
        dep_info_ptr.* = DependencyInfo(T).initWithBuilder(builder, life_cycle);

        try self.dependencies.put(dep_info_ptr.name, dep_info_ptr.getInterface());
    }

    pub fn createServiceProvider(self: *Self) !ServiceProvider {
        try validateDependencies(self);

        return ServiceProvider.init(self.allocator, self);
    }

    pub fn createServiceProviderWithCustomAllocator(
        self: *Self,
        allocator: std.mem.Allocator,
    ) !ServiceProvider {
        try validateDependencies(self);

        return ServiceProvider.init(allocator, self);
    }

    fn validateDependencies(self: *Self) !void {
        var iter = self.dependencies.valueIterator();

        while (iter.next()) |di| {
            for (di.getDependencies()) |dep| {
                try self.checkDependenciesLifeCycles(di);
                try self.checkTransitiveDependencies(di, dep.name);
            }
        }
    }

    fn checkDependencyValid(check: ?IDependencyInfo, dep_name: []const u8) !void {
        if (check == null) {
            const is_allocator = std.mem.eql(u8, dep_name, @typeName(std.mem.Allocator));
            const is_sp = std.mem.eql(u8, dep_name, @typeName(ServiceProvider));

            if (is_allocator) {
                return;
            }

            if (is_sp) {
                return;
            }

            return ContainerError.ServiceNotFound;
        }
    }

    fn checkDependenciesLifeCycles(
        self: *Self,
        check: *IDependencyInfo,
    ) !void {
        const deps = check.getDependencies();

        for (deps) |dep| {
            const dep_info = self.dependencies.get(dep.name);

            try checkDependencyValid(dep_info, dep.name);

            if (dep_info == null) {
                return;
            }

            const life_cycle = self.dependencies.get(dep.name).?.life_cycle;

            switch (check.life_cycle) {
                .singleton => {
                    if (life_cycle != .singleton) {
                        std.log.warn(
                            "{s} is singleton and has dependency {s} with less lifycycle. ",
                            .{ check.getName(), dep.name },
                        );
                        return ContainerError.LifeCycleError;
                    }
                },
                .scoped => {
                    if (life_cycle == .transient) {
                        std.log.warn(
                            "{s} is scoped and has dependency {s} with less lifycycle. ",
                            .{ check.getName(), dep.name },
                        );
                        return ContainerError.LifeCycleError;
                    }
                },
                else => {},
            }
        }
    }

    fn checkTransitiveDependencies(
        self: *Self,
        check: *IDependencyInfo,
        dependency_name: []const u8,
    ) !void {
        var dep_info = self.dependencies.get(dependency_name);

        try checkDependencyValid(dep_info, dependency_name);

        if (dep_info == null) {
            return;
        }

        const deps = dep_info.?.getDependencies();
        for (deps) |dep| {
            if (std.mem.eql(u8, dep.name, check.getName())) {
                return ContainerError.TransitiveDependency;
            }

            try self.checkTransitiveDependencies(check, dep.name);
        }
    }
};
