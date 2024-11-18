const std = @import("std");
const container = @import("container.zig");
const utilities = @import("utilities.zig");
const dependency = @import("dependency.zig");
const builder = @import("builder.zig");
const generic = @import("generics.zig");

// Define custom errors related to the ServiceProvider.
const ServiceProviderError = error{
    NoResolveContextFound, // Indicates that no resolve context was found.
    ServiceNotFound, // Indicates that the requested service was not found.
};

// Represents information about a dependency.
const DependencyInfo = dependency.DependencyInfo;
const IDependencyInfo = dependency.IDependencyInfo;

// Represents a builder for creating instances of dependencies.
const Builder = builder.Builder;

// ServiceProvider is responsible for managing and resolving dependencies.
pub const ServiceProvider = struct {
    const Self = @This();

    container: *container.Container, // Reference to the dependency container.
    allocator: std.mem.Allocator, // Allocator for memory management.

    resolve_ctx: ?ResolveContext = null, // Current resolve context, if any.
    resolve_ctx_container: std.ArrayList(ResolveContext), // List of resolve contexts.

    singleton: std.ArrayList(Resolved),

    /// Initializes a new ServiceProvider.
    ///
    /// `a` The allocator to use for memory allocations.
    /// `c` The dependency container.
    /// return A new instance of ServiceProvider.
    pub fn init(a: std.mem.Allocator, c: *container.Container) !Self {
        return .{
            .allocator = a,
            .container = c,
            .resolve_ctx_container = std.ArrayList(ResolveContext).init(a),
            .singleton = std.ArrayList(Resolved).init(a),
        };
    }

    pub fn deinit(self: *Self) void {
        self.resolve_ctx_container.deinit();
        for (self.singleton.items) |*r| {
            r.info.deinit(r.ptr, self.allocator);
        }
        self.singleton.deinit();
    }

    /// Unresolves (deinitializes) resolved dependency and it's nested dependencies.
    ///
    /// `T` The pointer of resolved dependency.
    /// Return An error if there not founded dependency information.
    pub fn unresolve(self: *Self, T: anytype) !void {
        // Ensure that T is a pointer type at compile time.
        if (@typeInfo(@TypeOf(T)) != .Pointer)
            @compileError("Type " ++ @typeName(@TypeOf(T)) ++ " must be a pointer type for unresolve.");

        const dereferenced_type = utilities.deref(@TypeOf(T));
        const dep_info = self.container.dependencies.get(@typeName(dereferenced_type));

        // Return an error if the dependency information is not found.
        if (dep_info == null)
            return ServiceProviderError.ServiceNotFound;

        // Iterate through all resolve contexts to find the origin of T.
        for (self.resolve_ctx_container.items, 0..) |*ctx, i| {
            if (ctx.is_origin(T)) {
                // Remove the resolve context from the container and deinitialize it.
                defer _ = self.resolve_ctx_container.swapRemove(i);

                var iter = ctx.iter();

                // Iterate through all nodes in the resolve context and deinitialize them.
                while (iter.next()) |service| {
                    const ptr = service.ptr;
                    const info = @constCast(&service.info);

                    info.deinit(ptr, self.allocator);
                    std.debug.print("Deinitialized service: {s}\n", .{info.getName()});
                }

                ctx.deinit();

                return;
            }
        }

        // Return an error if no matching resolve context is found.
        return ServiceProviderError.NoResolveContextFound;
    }

    inline fn getResolveType(comptime T: type) type {
        if (T == std.mem.Allocator) {
            return anyerror!T;
        } else {
            return anyerror!*T;
        }
    }

    /// Resolves a dependency of the specified type.
    ///
    /// T The type of the dependency to resolve. Must not be a pointer type.
    /// Return A pointer to the resolved dependency.
    pub fn resolve(self: *Self, comptime T: type) !*T {
        // Ensure that T is not a pointer type at compile time.
        if (@typeInfo(T) == .Pointer)
            @compileError("Type " ++ @typeName(T) ++ " should not be a pointer type for resolve.");

        // Handle special case for Allocator if not registered in dependencies.
        if (T == std.mem.Allocator or
            T == Self)
            @compileError("Can't return " ++ @typeName(T) ++ " it can be accessed through service provider or as dependency");

        // If there is no current resolve context, create one.
        if (self.resolve_ctx == null) {
            self.resolve_ctx = ResolveContext.init(self.allocator);
            defer {
                // Clear the resolve context after resolution.
                if (self.resolve_ctx != null) self.resolve_ctx = null;
            }

            // Perform the actual resolution.
            const resolved = try self.inner_resolve(T);

            // Add the resolve context to the container.
            try self.resolve_ctx_container.append(self.resolve_ctx.?);

            return resolved;
        }

        // Perform the actual resolution within the existing context.
        return self.inner_resolve(T);
    }

    /// Internal function to handle the resolution logic.
    ///
    /// T The type of the dependency to resolve.
    /// Return An instance of the resolved dependency.
    fn inner_resolve(self: *Self, T: type) getResolveType(T) {
        if (T == std.mem.Allocator)
            return self.allocator;

        if (T == Self) {
            return self;
        }

        const dereferenced_type: type = utilities.deref(T);

        if (generic.isGeneric(dereferenced_type)) {
            return try self.buildGenericType(dereferenced_type);
        } else {
            return try self.buildSimpleType(dereferenced_type);
        }
    }

    fn buildGenericType(self: *Self, T: type) !*T {
        const inner_type: type = generic.getGenericType(T);
        const generic_name = generic.getName(T);

        const generic_di_interface = self.container.dependencies.get(generic_name);

        if (generic_di_interface == null) {
            // return try self.buildSimpleType(inner_type);
            return ServiceProviderError.ServiceNotFound;
        }

        const concrete_di_interface = self.container.dependencies.get(@typeName(inner_type));
        const container_di_interface = self.container.dependencies.get(@typeName(T));

        if (concrete_di_interface == null) {
            try switch (generic_di_interface.?.life_cycle) {
                .singleton => self.container.registerSingleton(inner_type),
                .scoped => self.container.registerScoped(inner_type),
                .transient => self.container.registerTransient(inner_type),
            };
        }

        if (container_di_interface == null) {
            try switch (generic_di_interface.?.life_cycle) {
                .singleton => self.container.registerSingleton(T),
                .scoped => self.container.registerScoped(T),
                .transient => self.container.registerTransient(T),
            };
        }

        return try self.buildSimpleType(T);
    }

    inline fn buildSimpleType(self: *Self, T: type) !*T {
        var di_interface = self.container.dependencies.get(@typeName(T));

        // Return an error if the dependency information is not found.
        if (di_interface == null) {
            return ServiceProviderError.ServiceNotFound;
        }

        // Cast the dependency interface to the appropriate type.
        const dep_info: *DependencyInfo(*T, false) = @ptrCast(@alignCast(di_interface.?.ptr));

        switch (dep_info.life_cycle) {
            .transient => {
                const ptr = try self.allocator.create(T);
                ptr.* = try self.build(T, dep_info);

                try self.resolve_ctx.?.append(ptr, di_interface.?);

                return ptr;
            },
            .singleton => {
                for (self.singleton.items) |*r| {
                    if (std.mem.eql(u8, r.info.getName(), di_interface.?.getName())) {
                        const ptr: *T = @ptrCast(@alignCast(r.ptr));
                        return ptr;
                    }
                }

                const ptr = try self.allocator.create(T);
                ptr.* = try self.build(T, dep_info);

                try self.singleton.append(.{ .info = di_interface.?, .ptr = ptr });

                return ptr;
            },
            .scoped => {},
        }

        unreachable;
    }

    fn build(self: *Self, comptime T: type, dep_info: *DependencyInfo(*T, false)) !T {
        var t: T = undefined;

        if (dep_info.builder == null) {
            var b = ServiceProviderBuilder(T).createBuilder();
            t = try b.build(self);
        } else {
            t = try dep_info.builder.?.build(self);
        }

        return t;
    }
};

// Represents a node in the resolve context linked list.
const Resolved = struct {
    ptr: *anyopaque, // Pointer to the dependency instance.
    info: IDependencyInfo, // Interface information for the dependency.
};

// Manages the context during dependency resolution to handle circular dependencies and cleanup.
const ResolveContext = struct {
    const Self = @This();

    resolved_services: std.ArrayList(Resolved), // Sequence of resolved dependencies.
    allocator: std.mem.Allocator, // Allocator for memory management.

    is_deinit: bool = false,

    /// Initializes a new ResolveContext.
    ///
    /// allocator The allocator to use.
    /// Return A new instance of ResolveContext.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .resolved_services = std.ArrayList(Resolved).init(allocator),
            .allocator = allocator,
        };
    }

    /// Appends a new node to the resolve sequence.
    ///
    /// ptr  Pointer to the dependency instance.
    /// info Interface information for the dependency.
    pub fn append(self: *Self, ptr: *anyopaque, info: IDependencyInfo) !void {
        const resolved_service = Resolved{
            .ptr = ptr,
            .info = info,
        };

        try self.resolved_services.append(resolved_service);
    }

    /// Returns an iterator for the resolve sequence.
    ///
    /// Return An iterator over the resolve sequence.
    pub fn iter(self: *Self) ResolvedServicesIter {
        return ResolvedServicesIter{ .items = self.resolved_services.items };
    }

    /// Cleans up all nodes in the resolve sequence.
    pub fn deinit(self: *Self) void {
        self.resolved_services.deinit();
        self.is_deinit = true;
    }

    /// Checks if the given pointer is the origin (last resolved dependency).
    ///
    /// ptr The pointer to check.
    /// Return `true` if the pointer is the origin, `false` otherwise.
    pub fn is_origin(self: *Self, ptr: *anyopaque) bool {
        if (self.resolved_services.items.len == 0) return false;

        return self.resolved_services.items[0].ptr == ptr;
    }

    /// Iterator for the linked list in ResolveContext.
    const ResolvedServicesIter = struct {
        const Self = @This();

        items: []Resolved, // Current node in the iteration.
        index: usize = 0,

        /// Advances the iterator and returns the next node.
        ///
        /// Return The next node or `null` if the end is reached.
        pub fn next(self: *ResolvedServicesIter) ?Resolved {
            self.index += 1;
            if (self.index == self.items.len + 1) return null;

            return self.items[self.items.len - self.index];
        }
    };
};

// Defines custom errors for the ComptimeBuilder.
const ComptimeBuilderError = error{
    NoInitFn, // Indicates that the type does not have an init function.
    MismatchReturnType, // Indicates a mismatch in the return type of the init function.
};

/// A compile-time builder for creating dependency instances.
///
/// This builder inspects the `init` function of the type `T` and resolves its dependencies
/// accordingly.
///
/// T The type to build.
/// Return A struct with `buildFn` and `createBuilder` methods.
pub fn ServiceProviderBuilder(comptime T: type) type {
    return struct {
        /// Builds an instance of type `T` using the provided ServiceProvider.
        ///
        /// sp The ServiceProvider to use for resolving dependencies.
        /// Return An instance of type `T` or an error if building fails.
        pub fn buildFn(ctx: *anyopaque) !T {
            const sp: *ServiceProvider = @ptrCast(@alignCast(ctx));
            // Ensure that type T has an init function.
            if (!utilities.hasInit(T))
                return ComptimeBuilderError.NoInitFn;

            const arg_types = utilities.getInitArgs(T);

            // Create a tuple to hold resolved dependencies.
            var tuple: std.meta.Tuple(arg_types) = undefined;

            // Resolve each dependency and populate the tuple.
            inline for (arg_types, 0..) |arg_type, i| {
                tuple[i] = try sp.inner_resolve(utilities.deref(arg_type));
            }

            // Call the init function with the resolved dependencies.
            if (@typeInfo(utilities.getReturnType(T.init)) == .ErrorUnion) {
                return try @call(.auto, T.init, tuple);
            }

            return @call(.auto, T.init, tuple);
        }

        /// Creates a Builder instance for type `T` using the `buildFn`.
        ///
        /// Return A Builder configured for type `T`.
        pub fn createBuilder() Builder(T) {
            return Builder(T).fromFn(@This().buildFn);
        }
    };
}
