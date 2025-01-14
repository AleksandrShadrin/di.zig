const std = @import("std");
const utilities = @import("utilities.zig");
const service_provider = @import("service_provider.zig");
const builder_module = @import("builder.zig");

const ServiceProvider = service_provider.ServiceProvider;

const Container = @import("container.zig").Container;
const container_mod = @import("container.zig");

const ContainerError = @import("container.zig").ContainerError;

// Import Builder from builder.zig
const Builder = builder_module.Builder;

const generics = @import("generics.zig");

// Define possible dependency errors
const DependencyError = error{
    DependencyShouldBeReference,
    NoInitFn,
};

// Enum representing the lifecycle of a dependency
pub const LifeCycle = enum {
    scoped,
    singleton,
    transient,
};

// Structure representing a single dependency
const Dependency = struct {
    name: []const u8,

    verify_behavior: *const fn (
        container: *Container,
        life_cycle: LifeCycle,
        visited: *std.AutoHashMap(*IDependencyInfo, void),
    ) anyerror!void = undefined,
};

pub fn SimpleVerifyBehavior(T: type) type {
    return struct {
        fn f(
            container: *Container,
            life_cycle: LifeCycle,
            visited: *std.AutoHashMap(*IDependencyInfo, void),
        ) !void {
            const dep_info = container.getDependencyInfo(T) orelse return ContainerError.ServiceNotFound;
            try verifyDependencyInfo(dep_info, container, life_cycle, visited);
        }
    };
}

pub fn GenericVerifyBehavior(T: type) type {
    return struct {
        fn f(
            container: *Container,
            life_cycle: LifeCycle,
            visited: *std.AutoHashMap(*IDependencyInfo, void),
        ) !void {
            const dep_info = try container_mod.nonBlockingGetOrAddGeneric(container, T);
            try verifyDependencyInfo(dep_info, container, life_cycle, visited);
        }
    };
}

pub fn ReservedVerifyBehavior(T: type) type {
    return struct {
        fn f(
            container: *Container,
            life_cycle: LifeCycle,
            visited: *std.AutoHashMap(*IDependencyInfo, void),
        ) !void {
            _ = life_cycle;
            _ = T;
            _ = visited;
            _ = container;
        }
    };
}

pub fn SliceVerifyBehavior(T: type) type {
    return struct {
        fn f(
            container: *Container,
            life_cycle: LifeCycle,
            visited: *std.AutoHashMap(*IDependencyInfo, void),
        ) !void {
            const child = @typeInfo(T).Pointer.child;
            const dep_with_factories = try container.getDependencyWithFactories(child);

            try verifyDependencyInfo(dep_with_factories.dependency, container, life_cycle, visited);
            std.log.warn(
                "failed to verify one of the factories {s}",
                .{dep_with_factories.factories[0].getName()},
            );

            for (dep_with_factories.factories) |factory| {
                try checkLifeCycle(life_cycle, factory.life_cycle);
            }
        }
    };
}

inline fn verifyDependencyInfo(
    dep_info: *IDependencyInfo,
    container: *Container,
    life_cycle: LifeCycle,
    visited: *std.AutoHashMap(*IDependencyInfo, void),
) !void {
    if (visited.contains(dep_info)) return ContainerError.CircularDependency;
    try visited.put(dep_info, undefined);

    errdefer {
        std.log.warn(
            "failed to verify one of the dependencies of {s}",
            .{dep_info.getName()},
        );
    }

    try checkLifeCycle(life_cycle, dep_info.life_cycle);

    for (dep_info.getDependencies()) |dep| {
        try dep.verify_behavior(container, life_cycle, visited);
    }
}

fn checkLifeCycle(parent: LifeCycle, current: LifeCycle) !void {
    switch (parent) {
        .singleton => {
            if (current != .singleton) {
                return ContainerError.LifeCycleError;
            }
        },
        .scoped => {
            if (current == .transient) {
                return ContainerError.LifeCycleError;
            }
        },
        else => {},
    }
}

// Interface for dependency information
pub const IDependencyInfo = struct {
    ptr: *anyopaque,

    vtable: struct {
        destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void, // destroy ptr object

        get_dependencies_fn: *const fn (ctx: *anyopaque) []const Dependency,
        get_name_fn: *const fn (ctx: *anyopaque) []const u8,
        call_deinit_fn: *const fn (ctx: *anyopaque, sp: *ServiceProvider) void,
        destroy_dependency_fn: *const fn (*anyopaque, std.mem.Allocator) void, // destroy ptr object
    },

    life_cycle: LifeCycle,

    /// Retrieves the list of dependencies
    pub fn getDependencies(self: *const IDependencyInfo) []const Dependency {
        return self.vtable.get_dependencies_fn(self.ptr);
    }

    /// Retrieves the name of the dependency
    pub fn getName(self: *const IDependencyInfo) []const u8 {
        return self.vtable.get_name_fn(self.ptr);
    }

    /// Deinitializes the dependency
    pub fn callDeinit(self: *const IDependencyInfo, ptr: *anyopaque, sp: *ServiceProvider) void {
        return self.vtable.call_deinit_fn(ptr, sp);
    }

    /// Deinitializes the dependency
    pub fn destroyDependency(self: *const IDependencyInfo, ptr: *anyopaque, allocator: std.mem.Allocator) void {
        return self.vtable.destroy_dependency_fn(ptr, allocator);
    }

    pub fn destroy(self: *const IDependencyInfo, allocator: std.mem.Allocator) void {
        self.vtable.destroy_fn(self.ptr, allocator);
    }
};

// Function to generate DependencyInfo for a given type `T`
pub fn DependencyInfo(comptime T: type) type {
    const DerefT = utilities.deref(T);

    const dep_count: usize = if (utilities.hasInit(DerefT)) utilities.getInitArgs(DerefT).len else 0;

    return struct {
        const Self = @This();

        name: []const u8 = @typeName(DerefT),
        dep_array: [dep_count]Dependency = undefined, // Initialized in `init`

        builder: ?Builder(DerefT) = null,
        with_comptime_builder: bool,

        life_cycle: LifeCycle,

        /// Initializes the DependencyInfo with a lifecycle
        pub fn init(life_cycle: LifeCycle, comptime is_generic: bool) !Self {
            var self = Self{
                .with_comptime_builder = true,
                .life_cycle = life_cycle,
                .dep_array = undefined, // Will be initialized below
            };

            if (!is_generic) {
                if (!utilities.hasInit(DerefT))
                    return DependencyError.NoInitFn;

                const dependencies = utilities.getInitArgs(DerefT);

                inline for (dependencies, 0..) |dep, i| {
                    const deref_dep = utilities.deref(dep);
                    const is_reserved = dep == std.mem.Allocator or dep == *ServiceProvider;

                    if (generics.isGeneric(deref_dep)) {
                        self.dep_array[i] = Dependency{
                            .name = generics.getName(deref_dep),
                            .verify_behavior = GenericVerifyBehavior(deref_dep).f,
                        };
                    } else {
                        self.dep_array[i] = Dependency{
                            .name = if (utilities.isSlice(deref_dep)) @typeName(utilities.deref(std.meta.Child(deref_dep))) else @typeName(deref_dep),
                            .verify_behavior = if (is_reserved) ReservedVerifyBehavior(deref_dep).f else if (utilities.isSlice(deref_dep)) SliceVerifyBehavior.f else SimpleVerifyBehavior(deref_dep).f,
                        };
                    }

                    // Ensure that the dependency should be a reference
                    if (!utilities.isSlice(deref_dep) and
                        dep != std.mem.Allocator and
                        deref_dep == dep)
                        @compileError(@typeName(DerefT) ++ " dependency " ++ @typeName(dep) ++ " should be a reference");
                }
            }

            return self;
        }

        /// Initializes the DependencyInfo with a custom builder and lifecycle
        pub fn initWithBuilder(builder: Builder(DerefT), life_cycle: LifeCycle) Self {
            return Self{
                .builder = builder,
                .with_comptime_builder = false,
                .life_cycle = life_cycle,
                .dep_array = undefined, // Not used when not using comptime builder
            };
        }

        /// Provides the interface representation of the dependency info
        pub fn getInterface(self: *Self) IDependencyInfo {
            return IDependencyInfo{
                .ptr = self,
                .vtable = .{
                    .get_dependencies_fn = Self.getDependencies,
                    .get_name_fn = Self.getName,
                    .call_deinit_fn = Self.callDeinit,
                    .destroy_fn = Self.destroySelf,
                    .destroy_dependency_fn = Self.destroyDependency,
                },
                .life_cycle = self.life_cycle,
            };
        }

        /// Retrieves dependencies based on the builder type
        fn getDependencies(ctx: *anyopaque) []const Dependency {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (!self.with_comptime_builder) {
                return &.{};
            }

            return &self.dep_array;
        }

        /// Retrieves the name of the dependency
        fn getName(ctx: *anyopaque) []const u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.name;
        }

        /// Deinitializes the dependency if necessary
        fn callDeinit(ptr: *anyopaque, sp: *ServiceProvider) void {
            const item: *DerefT = @ptrCast(@alignCast(ptr));

            Destructor(DerefT).deinit(item, sp) catch |err| {
                std.log.warn("Error when deinit {any} with error {any}", .{ DerefT, err });
            };
        }

        fn destroyDependency(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const item: *DerefT = @ptrCast(@alignCast(ptr));
            allocator.destroy(item);
        }

        fn destroySelf(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            allocator.destroy(self);
        }
    };
}

// Structure to handle destruction of a type `T`
fn Destructor(comptime T: type) type {
    return struct {
        /// Deinitializes an instance of `T`
        pub fn deinit(t: *T, sp: *ServiceProvider) !void {
            // Check if `T` has a `deinit` method
            if (!std.meta.hasFn(T, "deinit")) return;

            const deinit_fn_type = @typeInfo(@TypeOf(T.deinit)).Fn;

            // Ensure `deinit` has exactly one parameter
            if ((deinit_fn_type.params[0].type != *T and
                deinit_fn_type.params[0].type != T))
                @compileError("deinit should have one parameter for " ++ @typeName(T) ++ " and have single arg as *Self");

            switch (deinit_fn_type.params.len) {
                2 => {
                    if (utilities.deref(deinit_fn_type.params[0].type.?) != T or
                        deinit_fn_type.params[1].type.? != *ServiceProvider)
                        @compileError("deinit should have siganture fn (*Self, *ServiceProvider)");

                    if (@typeInfo(deinit_fn_type.return_type.?) != .ErrorUnion) {
                        t.deinit(sp);
                    } else {
                        return try t.deinit(sp);
                    }
                },
                1 => {
                    if (utilities.deref(deinit_fn_type.params[0].type.?) != T)
                        @compileError("deinit should have siganture fn (*Self)");

                    if (@typeInfo(deinit_fn_type.return_type.?) != .ErrorUnion) {
                        t.deinit();
                    } else {
                        return try t.deinit();
                    }
                },
                else => @compileError("deinit should have siganture fn (*Self, *ServiceProvider) or fn (*Self) or fn (Self)"),
            }
        }
    };
}
