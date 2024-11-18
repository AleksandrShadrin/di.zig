const std = @import("std");
const utilities = @import("utilities.zig");
const service_provider = @import("service_provider.zig");
const builder_module = @import("builder.zig");
// Consolidated imports from service_provider.zig
const ServiceProvider = service_provider.ServiceProvider;

// Import Builder from builder.zig
const Builder = builder_module.Builder;

// Define possible dependency errors
const DependencyError = error{
    DependencyShouldBeReference,
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
};

// Interface for dependency information
pub const IDependencyInfo = struct {
    ptr: *anyopaque,
    destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void, // destroy ptr object

    get_dependencies_fn: *const fn (ctx: *anyopaque) []const Dependency,
    get_name_fn: *const fn (ctx: *anyopaque) []const u8,
    deinit_fn: *const fn (ctx: *anyopaque, std.mem.Allocator) void,

    life_cycle: LifeCycle,

    /// Retrieves the list of dependencies
    pub fn getDependencies(self: *IDependencyInfo) []const Dependency {
        return self.get_dependencies_fn(self.ptr);
    }

    /// Retrieves the name of the dependency
    pub fn getName(self: *IDependencyInfo) []const u8 {
        return self.get_name_fn(self.ptr);
    }

    /// Deinitializes the dependency
    pub fn deinit(self: *IDependencyInfo, ptr: *anyopaque, allocator: std.mem.Allocator) void {
        return self.deinit_fn(ptr, allocator);
    }
};

// Function to generate DependencyInfo for a given type `T`
pub fn DependencyInfo(comptime T: type, comptime is_generic: bool) type {
    const DerefT = utilities.deref(T);

    const dep_count: usize = if (is_generic) 0 else utilities.getInitArgs(DerefT).len;

    if (dep_count == 0 and
        !is_generic)
        @compileError(@typeName(DerefT) ++ " hasn't init fn");

    return struct {
        const Self = @This();

        name: []const u8 = @typeName(DerefT),
        dep_array: [dep_count]Dependency = undefined, // Initialized in `init`

        builder: ?Builder(DerefT) = null,
        with_comptime_builder: bool,

        life_cycle: LifeCycle,

        /// Initializes the DependencyInfo with a lifecycle
        pub fn init(life_cycle: LifeCycle) !Self {
            var self = Self{
                .with_comptime_builder = true,
                .life_cycle = life_cycle,
                .dep_array = undefined, // Will be initialized below
            };

            if (!is_generic) {
                const dependencies = utilities.getInitArgs(DerefT);

                inline for (dependencies, 0..) |dep, i| {
                    self.dep_array[i] = Dependency{ .name = @typeName(utilities.deref(dep)) };

                    // Ensure that the dependency should be a reference
                    if (utilities.deref(dep) == dep and
                        dep != std.mem.Allocator)
                    {
                        return DependencyError.DependencyShouldBeReference;
                    }
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
                .get_dependencies_fn = Self.getDependencies,
                .get_name_fn = Self.getName,
                .deinit_fn = Self.deinit,
                .life_cycle = self.life_cycle,
                .destroy_fn = Self.destroy,
            };
        }

        /// Retrieves dependencies based on the builder type
        pub fn getDependencies(ctx: *anyopaque) []const Dependency {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (!self.with_comptime_builder) {
                return &.{};
            }

            return &self.dep_array;
        }

        /// Retrieves the name of the dependency
        pub fn getName(ctx: *anyopaque) []const u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.name;
        }

        /// Deinitializes the dependency if necessary
        pub fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const item: *DerefT = @ptrCast(@alignCast(ptr));

            Destructor(DerefT).deinit(item) catch |err| {
                std.log.err("Error when deinit {any} with error {any}", .{ DerefT, err });
            };

            allocator.destroy(item);
        }

        pub fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            allocator.destroy(self);
        }
    };
}

// Structure to handle destruction of a type `T`
fn Destructor(comptime T: type) type {
    return struct {
        /// Deinitializes an instance of `T`
        pub fn deinit(t: *T) !void {
            // Check if `T` has a `deinit` method
            if (!std.meta.hasFn(T, "deinit")) return;

            const deinit_fn_type = @typeInfo(@TypeOf(T.deinit)).Fn;

            // Ensure `deinit` has exactly one parameter
            if (deinit_fn_type.params.len != 1 or
                (deinit_fn_type.params[0].type != *T and
                deinit_fn_type.params[0].type != T))
                @compileError("deinit should have one parameter for " ++ @typeName(T) ++ " and have single arg as *Self");

            // Handle `deinit` based on its return type
            if (@typeInfo(deinit_fn_type.return_type.?) != .ErrorUnion) {
                t.deinit();
            } else {
                return try t.deinit();
            }
        }
    };
}
