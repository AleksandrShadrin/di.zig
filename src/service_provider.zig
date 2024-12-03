const std = @import("std");
const container = @import("container.zig");
const utilities = @import("utilities.zig");
const dependency = @import("dependency.zig");
const builder = @import("builder.zig");
const generic = @import("generics.zig");

const Mutex = std.Thread.Mutex;

// Define custom errors specific to the ServiceProvider's operations.
// These errors are used to handle various failure scenarios during dependency resolution.
pub const ServiceProviderError = error{
    NoResolveContextFound, // Indicates that no active resolution context was found.
    ServiceNotFound, // The requested service is not registered in the container.
    NoActiveScope, // Attempted to resolve a scoped service without an active scope.
    UnresolveLifeCycleShouldBeTransient, // Tried to unresolve a service that isn't transient.
    CycleDependency,
};

// Type aliases for dependency-related interfaces for convenience and readability.
const DependencyInfo = dependency.DependencyInfo;
const IDependencyInfo = dependency.IDependencyInfo;

// Alias for the Builder used in creating instances of dependencies.
const Builder = builder.Builder;

// The ServiceProvider is responsible for managing and resolving dependencies,
// handling their lifecycles (singleton, scoped, transient), and ensuring proper resource management.
pub const ServiceProvider = struct {
    const Self = @This();

    container: *container.Container, // Points to the dependency container holding all service registrations.
    allocator: std.mem.Allocator, // Allocator used for dynamic memory operations during resolution.

    transient_services: TransientResolvedServices, // Maintains a list of root resolution contexts for tracking.

    singleton: OnceResolvedServices, // Stores instances of singleton services managed by the provider.

    scope: ?*Scope = null,

    /// Initializes a new ServiceProvider instance.
    ///
    /// Parameters:
    /// - `a`: Allocator for memory allocations.
    /// - `c`: Pointer to the dependency container with service registrations.
    ///
    /// Returns:
    /// - A new instance of ServiceProvider.
    pub fn init(a: std.mem.Allocator, c: *container.Container) !Self {
        return .{
            .allocator = a,
            .container = c,
            .transient_services = TransientResolvedServices.init(a),
            .singleton = try OnceResolvedServices.init(a),
        };
    }

    fn clone(self: *Self) !Self {
        return Self{
            .singleton = self.singleton,
            .allocator = self.allocator,
            .container = self.container,
            .transient_services = TransientResolvedServices.init(self.allocator),
        };
    }

    /// Deinitializes the ServiceProvider, ensuring all managed dependencies are properly cleaned up.
    pub fn deinit(self: *Self) void {
        // Iterate through all root resolution contexts and deinitialize transient dependencies.
        self.transient_services.deinit();

        if (self.scope == null)
            self.singleton.deinit();
    }

    /// Unresolves (deinitializes) a previously resolved dependency along with its nested dependencies.
    ///
    /// Parameters:
    /// - `T`: The type of the dependency to unresolve. Must be a pointer type.
    ///
    /// Returns:
    /// - `Ok` on successful unresolution.
    /// - A `ServiceProviderError` if the dependency cannot be unresolved.
    pub fn unresolve(self: *Self, T: anytype) !void {
        // Ensure at compile-time that T is a pointer type.
        if (@typeInfo(@TypeOf(T)) != .Pointer)
            @compileError("Type " ++ @typeName(@TypeOf(T)) ++ " must be a pointer type for unresolve.");

        const dereferenced_type = utilities.deref(@TypeOf(T));

        // Fetch the dependency information from the container.
        const dep_interface = self.container.getDependencyInfo(dereferenced_type) orelse return ServiceProviderError.ServiceNotFound;

        // Only dependencies with a transient lifecycle are eligible for unresolution.
        if (dep_interface.life_cycle != .transient)
            return ServiceProviderError.UnresolveLifeCycleShouldBeTransient;

        // Search through all root resolution contexts to locate the matching dependency instance.
        if (!self.transient_services.delete(@as(*anyopaque, T))) return ServiceProviderError.NoResolveContextFound;
    }

    /// Determines the error type based on the type `T` being resolved.
    ///
    /// - If `T` is an Allocator, it returns `anyerror!T`.
    /// - Otherwise, it returns `anyerror!*T`.
    inline fn getResolveType(comptime T: type) type {
        if (T == std.mem.Allocator) {
            return anyerror!T;
        } else {
            return anyerror!*T;
        }
    }

    /// Resolves a dependency of the specified type `T`.
    ///
    /// This function initiates the dependency resolution process by creating a new BuilderContext
    /// and delegating the resolution to `inner_resolve`.
    ///
    /// Parameters:
    /// - `T`: The type of the dependency to resolve.
    ///
    /// Returns:
    /// - A pointer to the resolved dependency.
    /// - An error if the resolution process fails.
    pub fn resolve(self: *Self, comptime T: type) !*T {
        // Initialize a new BuilderContext for this resolution operation.
        var ctx = BuilderContext{
            .sp = self,
            .active_root = Resolved.empty(self.allocator),
            .current_resolve = null,
        };

        // Perform the actual resolution using the internal resolve method.
        return try self.inner_resolve(&ctx, T);
    }

    /// Internal method responsible for the actual resolution of a dependency.
    ///
    /// This method manages the resolution context and delegates to `resolve_strategy` to handle the
    /// specifics based on the dependency's type and lifecycle.
    ///
    /// Parameters:
    /// - `ctx`: Pointer to the BuilderContext managing the resolution state.
    /// - `T`: The type of the dependency to resolve. Must not be a pointer type.
    ///
    /// Returns:
    /// - A pointer to the resolved dependency.
    /// - An error if the resolution process fails.
    fn inner_resolve(self: *Self, ctx: *BuilderContext, comptime T: type) !*T {
        // Ensure at compile-time that T is not a pointer type.
        if (@typeInfo(T) == .Pointer)
            @compileError("Type " ++ @typeName(T) ++ " should not be a pointer type for resolve.");

        // Prevent direct resolution of Allocator or ServiceProvider types.
        if (T == std.mem.Allocator or
            T == Self)
            @compileError("Can't return " ++ @typeName(T) ++ " it can be accessed through service provider or as dependency");

        // Execute the resolution strategy to obtain the dependency instance.
        const resolved = try self.resolve_strategy(ctx, T);

        // Append the fully resolved context to the list of resolve roots.
        if (ctx.active_root.?.info.?.life_cycle == .transient)
            try self.transient_services.add(ctx.active_root.?);

        return resolved;
    }

    /// Determines and executes the appropriate resolution strategy based on the dependency's type and lifecycle.
    ///
    /// Parameters:
    /// - `ctx`: Pointer to the BuilderContext managing the resolution state.
    /// - `T`: The type of the dependency to resolve.
    ///
    /// Returns:
    /// - An instance of the resolved dependency.
    /// - An error if the resolution strategy fails.
    fn resolve_strategy(self: *Self, ctx: *BuilderContext, comptime T: type) getResolveType(T) {
        // Special case handling for Allocator type.
        if (T == std.mem.Allocator)
            return self.allocator;

        // Special case handling for the ServiceProvider type.
        if (T == Self) {
            return self;
        }

        const dereferenced_type: type = utilities.deref(T);

        // Determine if the type is generic and delegate to the appropriate builder method.
        if (generic.isGeneric(dereferenced_type)) {
            return try self.buildGenericType(ctx, dereferenced_type);
        } else {
            return try self.buildSimpleType(ctx, dereferenced_type);
        }
    }

    /// Handles the resolution of generic dependency types.
    ///
    /// This method ensures that both the inner type and the generic type itself are registered
    /// in the container, then delegates to `buildSimpleType` for instantiation.
    ///
    /// Parameters:
    /// - `ctx`: Pointer to the BuilderContext managing the resolution state.
    /// - `T`: The generic type to resolve.
    ///
    /// Returns:
    /// - A pointer to the resolved generic dependency.
    /// - An error if the resolution process fails.
    fn buildGenericType(self: *Self, ctx: *BuilderContext, T: type) !*T {
        const inner_type: type = generic.getGenericType(T);

        // Retrieve the dependency interface for the generic type from the container.
        const generic_di_interface = self.container.getGenericWrapper(T);

        // Check if the inner type and the generic type are already registered.
        const concrete_di_interface = self.container.getDependencyInfo(inner_type);
        const container_di_interface = self.container.getDependencyInfo(T);

        if (generic_di_interface == null and
            concrete_di_interface == null)
            return ServiceProviderError.ServiceNotFound;

        const life_cycle = if (concrete_di_interface != null) concrete_di_interface.?.life_cycle else generic_di_interface.?.life_cycle;

        // If the inner type is not registered, register it based on its lifecycle.
        if (concrete_di_interface == null) {
            try switch (life_cycle) {
                .singleton => self.container.registerSingleton(inner_type),
                .scoped => self.container.registerScoped(inner_type),
                .transient => self.container.registerTransient(inner_type),
            };
        }

        // If the generic type itself is not registered, register it based on its lifecycle.
        if (container_di_interface == null) {
            try switch (life_cycle) {
                .singleton => self.container.registerSingleton(T),
                .scoped => self.container.registerScoped(T),
                .transient => self.container.registerTransient(T),
            };
        }

        // Proceed to build the generic type as a simple (non-generic) type.
        return try self.buildSimpleType(ctx, T);
    }

    /// Builds and instantiates a simple (non-generic) dependency type.
    ///
    /// This method handles the creation of dependencies based on their lifecycle (transient, singleton, scoped)
    /// and manages their placement within the resolution context.
    ///
    /// Parameters:
    /// - `ctx`: Pointer to the BuilderContext managing the resolution state.
    /// - `T`: The type of the dependency to build.
    ///
    /// Returns:
    /// - A pointer to the instantiated dependency.
    /// - An error if the building process fails.
    fn buildSimpleType(self: *Self, ctx: *BuilderContext, T: type) !*T {
        // Retrieve the dependency interface information from the container.
        var di_interface = self.container.getDependencyInfo(T) orelse return ServiceProviderError.ServiceNotFound;

        // Ensure that the resolution context is properly cleaned up in case of failure.
        errdefer {
            if (ctx.active_root != null) {
                ctx.active_root.?.deinit();

                ctx.active_root = null;
            }
            ctx.current_resolve = null;
        }

        // Cast the dependency interface to the specific DependencyInfo type.
        const dep_info: *DependencyInfo(*T) = @ptrCast(@alignCast(di_interface.ptr));

        const current = ctx.current_resolve;
        var new_current: *Resolved = undefined;

        // Handle hierarchical resolution contexts by either initializing the root or appending to the current context.
        if (current == null) {
            new_current = &ctx.active_root.?;
        } else {
            try current.?.child.append(Resolved.empty(self.allocator));
            new_current = &current.?.child.items[current.?.child.items.len - 1];
        }

        // Update the current resolution context to point to the new dependency being resolved.
        ctx.current_resolve = new_current;
        new_current.info = di_interface;

        try ctx.active_root.?.checkCycles(null);

        // Instantiate the dependency based on its lifecycle configuration.
        switch (dep_info.life_cycle) {
            .transient => {
                // Transient services always create a new instance upon resolution.
                const value = try self.build(ctx, T, dep_info);
                const ptr = try self.allocator.create(T);

                ptr.* = value;
                new_current.ptr = ptr;
            },
            .singleton => {
                var ptr: ?*T = @ptrCast(@alignCast(self.singleton.get(di_interface.getName())));

                // If no existing singleton, create and store it.
                if (ptr == null) {
                    const value = try self.build(ctx, T, dep_info);

                    ptr = try self.allocator.create(T);

                    ptr.?.* = value;

                    new_current.ptr = ptr;
                    try self.singleton.add(new_current.*);
                    errdefer self.allocator.destroy(ptr.?);
                } else {
                    new_current.ptr = ptr;
                }
            },
            .scoped => {
                // Scoped services require an active scope to be resolved within.
                if (self.scope == null) {
                    return ServiceProviderError.NoActiveScope;
                }

                var ptr: ?*T = @ptrCast(@alignCast(self.scope.?.resolved_services.get(di_interface.getName())));

                // If no existing scoped instance, create and store it within the current scope.
                if (ptr == null) {
                    const value = try self.build(ctx, T, dep_info);

                    ptr = try self.allocator.create(T);

                    ptr.?.* = value;

                    new_current.ptr = ptr;

                    try self.scope.?.resolved_services.add(new_current.*);
                    errdefer self.allocator.destroy(ptr.?);
                } else {
                    new_current.ptr = ptr;
                }
            },
        }

        // Restore the previous resolution context after completing the current dependency resolution.
        if (current != null) {
            ctx.current_resolve = current;
        } else {
            ctx.current_resolve = &ctx.active_root.?;
        }

        new_current.info.?.verify();
        // Return the pointer to the newly resolved dependency.
        return @ptrCast(@alignCast(new_current.ptr));
    }

    /// Constructs an instance of type `T` using the provided BuilderContext.
    ///
    /// This method handles the instantiation logic, determining whether to use a custom builder
    /// or the default compile-time builder based on the dependency's configuration.
    ///
    /// Parameters:
    /// - `ctx`: Pointer to the BuilderContext containing the ServiceProvider and optional Scope.
    /// - `T`: The type of the dependency to build.
    /// - `dep_info`: Information about the dependency, including its builder function.
    ///
    /// Returns:
    /// - An instance of type `T`.
    /// - An error if the building process fails.
    fn build(self: *Self, ctx: *BuilderContext, comptime T: type, dep_info: *DependencyInfo(*T)) !T {
        if (dep_info.builder == null) {
            // If no custom builder is provided, utilize the default compile-time builder.
            var b = ServiceProviderBuilder(T).createBuilder();

            return try b.buildFn(ctx);
        } else {
            // Use the custom builder function specified in the dependency's configuration.
            return try dep_info.builder.?.build(self);
        }
    }

    pub fn initScope(self: *Self) !*Scope {
        var sp = try self.clone();

        const scope_ptr = try self.allocator.create(Scope);
        errdefer self.allocator.destroy(scope_ptr);

        sp.scope = scope_ptr;

        scope_ptr.* = try Scope.init(sp, self.allocator);
        return scope_ptr;
    }
};

pub const ScopeError = error{
    ServiceNotFound,
    LifeCycleNotScope,
};

// Represents a scoped container that manages dependencies within a specific scope.
// Scoped dependencies are tied to the lifecycle of the scope.
pub const Scope = struct {
    const Self = @This();

    sp: ServiceProvider, // Reference to the parent ServiceProvider managing this scope.
    resolved_services: OnceResolvedServices, // List of dependencies instantiated within this scope.
    allocator: std.mem.Allocator, // Allocator for memory operations within the scope.

    /// Initializes a new Scope instance.
    ///
    /// Parameters:
    /// - `sp`: The ServiceProvider that manages this scope.
    /// - `allocator`: Allocator for memory allocations within the scope.
    ///
    /// Returns:
    /// - A new instance of Scope.
    pub fn init(sp: ServiceProvider, allocator: std.mem.Allocator) !Self {
        return Self{
            .sp = sp,
            .resolved_services = try OnceResolvedServices.init(allocator),
            .allocator = allocator,
        };
    }

    /// Resolves a dependency of the specified type `T` within the current scope.
    ///
    /// This method initializes a new BuilderContext tailored for scoped resolution
    /// and delegates the resolution process to the ServiceProvider.
    ///
    /// Parameters:
    /// - `T`: The type of the dependency to resolve.
    ///
    /// Returns:
    /// - A pointer to the resolved dependency.
    /// - An error if the resolution process fails.
    pub fn resolve(self: *Self, comptime T: type) !*T {
        // Delegate the resolution to the ServiceProvider's internal resolve method.
        return try self.sp.resolve(T);
    }

    pub fn deinit(self: *Self) void {
        self.resolved_services.deinit();

        self.sp.deinit();
        self.allocator.destroy(self.sp.scope.?);
    }
};

// Represents a resolved dependency within a resolution context.
// This structure holds the instance pointer and metadata about the dependency.
const Resolved = struct {
    const Self = @This();

    ptr: ?*anyopaque = null, // Pointer to the instantiated dependency instance.

    info: ?*IDependencyInfo = null, // Interface information for the dependency, including lifecycle and deinit function.

    child: std.ArrayList(Resolved), // List of nested dependencies resolved by this dependency.

    allocator: std.mem.Allocator, // Allocator used for managing memory within this Resolved context.

    deinitialized: bool = false, // Flag indicating whether the dependency has been deinitialized.

    /// Constructs an empty Resolved instance with an initialized child list.
    ///
    /// Parameters:
    /// - `a`: Allocator for memory allocations within this Resolved instance.
    ///
    /// Returns:
    /// - A new, empty Resolved instance.
    pub fn empty(a: std.mem.Allocator) Self {
        return Self{
            .child = std.ArrayList(Resolved).init(a),
            .allocator = a,
        };
    }

    pub fn checkCycles(self: *Self, ctx: ?*Self) !void {
        if (self.info.?.isVerified())
            return;

        for (self.child.items) |*child| {
            if (child.info == null)
                continue;

            try child.checkCycles(self);

            if (ctx == null) {
                continue;
            }

            try child.checkCycles(ctx);

            if (std.mem.eql(u8, child.info.?.getName(), ctx.?.info.?.getName())) {
                return ServiceProviderError.CycleDependency;
            }
        }
    }

    /// Deinitializes the Resolved instance, recursively cleaning up all nested dependencies.
    pub fn deinit(self: *Self) void {
        // Recursively deinitialize all child dependencies to ensure proper cleanup.
        self.deinitialized = true;

        for (self.child.items) |*child| {
            child.inner_deinit();
        }

        // Deinitialize the dependency instance if it exists.
        if (self.info != null and
            self.ptr != null)
        {
            self.info.?.callDeinit(self.ptr.?);
            self.info.?.destroyDependency(self.ptr.?, self.allocator);
        }

        // Deinitialize the list holding child dependencies.
        self.child.deinit();
    }

    /// Recursively deinitializes only transient dependencies within this Resolved context.
    fn inner_deinit(self: *Self) void {
        self.deinitialized = true;

        // Skip deinitialization for non-transient dependencies to preserve their lifecycle.
        if (self.info != null and
            self.info.?.life_cycle != .transient)
        {
            return;
        }

        // Recursively deinitialize all child dependencies that are transient.
        for (self.child.items) |*child| {
            child.inner_deinit();
        }

        // Deinitialize the transient dependency instance if it exists.
        if (self.info != null and
            self.ptr != null)
        {
            self.info.?.callDeinit(self.ptr.?);
            self.info.?.destroyDependency(self.ptr.?, self.allocator);
        }

        // Deinitialize the list holding child dependencies.
        self.child.deinit();
    }
};

// Manages the context during dependency resolution, encapsulating the state required to resolve dependencies.
// This structure ensures that resolution state is maintained correctly and isolated per resolution process.
const BuilderContext = struct {
    const Self = @This();

    sp: *ServiceProvider, // Reference to the ServiceProvider responsible for resolving dependencies.
    active_root: ?Resolved, // Root of the current resolution context, tracking the top-level dependency.
    current_resolve: ?*Resolved, // Pointer to the currently active Resolved context during the resolution process.

    /// Initializes a new BuilderContext instance.
    ///
    /// Parameters:
    /// - `sp`: Reference to the ServiceProvider managing this resolution context.
    /// - `scope`: Optional scope within which scoped dependencies are resolved.
    /// - `allocator`: Allocator for memory allocations within the resolution context.
    ///
    /// Returns:
    /// - A newly initialized BuilderContext.
    pub fn init(sp: *ServiceProvider, allocator: std.mem.Allocator) Self {
        return Self{
            .sp = sp,
            .active_root = Resolved.empty(allocator),
            .current_resolve = null,
        };
    }
};

// Defines custom errors specific to the compile-time builder used in dependency resolution.
// These errors handle issues related to the builder's configuration and functionality.
const ComptimeBuilderError = error{
    NoInitFn, // The type `T` does not provide an `init` function required for instantiation.
    MismatchReturnType, // The return type of the `init` function does not match the expected type.
};

/// A compile-time builder responsible for constructing instances of dependency types.
/// This builder introspects the `init` function of type `T` and resolves its dependencies recursively.
///
/// Parameters:
/// - `T`: The type to build.
///
/// Functionality:
/// - Provides `buildFn` to instantiate `T` using resolved dependencies.
/// - Provides `createBuilder` to obtain a configured Builder for type `T`.
fn ServiceProviderBuilder(comptime T: type) type {
    return struct {
        /// Builds an instance of type `T` using the provided BuilderContext.
        ///
        /// Parameters:
        /// - `ctx`: Pointer to BuilderContext containing the ServiceProvider and optional Scope.
        ///
        /// Returns:
        /// - An instance of type `T`.
        /// - An error if the building process fails.
        pub fn buildFn(ctx: *anyopaque) !T {
            const b_ctx: *BuilderContext = @ptrCast(@alignCast(ctx));

            // Verify that type `T` has an `init` function for instantiation.
            if (!utilities.hasInit(T))
                return ComptimeBuilderError.NoInitFn;

            // Retrieve the list of argument types required by the `init` function of `T`.
            const arg_types = utilities.getInitArgs(T);

            // Create a tuple to hold the resolved dependencies that will be passed to `init`.
            var tuple: std.meta.Tuple(arg_types) = undefined;

            // Iterate over each argument type, resolve it, and populate the tuple.
            inline for (arg_types, 0..) |arg_type, i| {
                tuple[i] = try b_ctx.sp.resolve_strategy(b_ctx, utilities.deref(arg_type));
            }

            // Call the `init` function with the resolved dependencies.
            if (@typeInfo(utilities.getReturnType(T.init)) == .ErrorUnion) {
                return try @call(.auto, T.init, tuple);
            }

            return @call(.auto, T.init, tuple);
        }

        /// Creates a Builder instance for type `T` using the provided `buildFn`.
        ///
        /// Returns:
        /// - A configured `Builder` for type `T` that utilizes `buildFn` for instantiation.
        pub fn createBuilder() Builder(T) {
            return Builder(T).fromFn(@This().buildFn);
        }
    };
}

const OnceResolvedServices = struct {
    const Self = @This();

    items: *std.StringHashMap(Resolved),
    allocator: std.mem.Allocator,

    mutex: Mutex,

    pub fn init(a: std.mem.Allocator) !Self {
        const items_ptr = try a.create(std.StringHashMap(Resolved));
        items_ptr.* = std.StringHashMap(Resolved).init(a);

        return Self{
            .items = items_ptr,
            .allocator = a,
            .mutex = Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.items.valueIterator();
        while (iter.next()) |r| {
            r.deinit();
        }

        self.items.deinit();
        self.allocator.destroy(self.items);
    }

    pub fn get(self: *Self, name: []const u8) ?*anyopaque {
        const result = self.items.get(name) orelse return null;
        return result.ptr;
    }

    pub fn add(self: *Self, resolved: Resolved) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.items.put(resolved.info.?.getName(), resolved);
    }
};

const TransientResolvedServices = struct {
    const Self = @This();

    items: std.ArrayList(Resolved),
    allocator: std.mem.Allocator,

    mutex: Mutex,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{
            .items = std.ArrayList(Resolved).init(a),
            .allocator = a,
            .mutex = Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        while (self.items.popOrNull()) |r| {
            var mut = r;
            mut.deinit();
        }

        self.items.deinit();
    }

    pub fn delete(self: *Self, ptr: *anyopaque) bool {
        for (self.items.items, 0..) |*ctx, i| {
            if (ctx.ptr != null and
                ctx.ptr.? == ptr)
            {
                var removed = self.items.swapRemove(i);
                if (!removed.deinitialized)
                    removed.deinit();

                return true;
            }
        }

        return false;
    }

    pub fn add(self: *Self, resolved: Resolved) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.items.append(resolved);
    }
};
