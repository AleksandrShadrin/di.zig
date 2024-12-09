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
    pub fn init(allocator: std.mem.Allocator, c: *container.Container) !Self {
        return .{
            .allocator = allocator,
            .container = c,
            .transient_services = TransientResolvedServices.init(allocator),
            .singleton = try OnceResolvedServices.init(allocator),
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
        self.transient_services.deinit(self);

        if (self.scope == null)
            self.singleton.deinit(self);
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
        const info = self.container.getDependencyInfo(dereferenced_type) orelse return ServiceProviderError.ServiceNotFound;

        // Only dependencies with a transient lifecycle are eligible for unresolution.
        if (info.life_cycle != .transient)
            return ServiceProviderError.UnresolveLifeCycleShouldBeTransient;

        // Search through all root resolution contexts to locate the matching dependency instance.
        if (!self.transient_services.delete(@as(*anyopaque, T), info, self)) return ServiceProviderError.NoResolveContextFound;
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
        var ctx = BuilderContext.init(self);

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
        var info = self.container.getDependencyInfo(T) orelse return ServiceProviderError.ServiceNotFound;

        var node = std.DoublyLinkedList(*IDependencyInfo).Node{ .data = info };
        ctx.append(&node);
        defer {
            ctx.pop();
            node.data.verify();
        }

        var new_root = Resolved.empty(self.allocator);
        new_root.info = info;

        const current_root = ctx.current_resolve;
        ctx.current_resolve = &new_root;

        try ctx.verify();

        var storage: ?*Resolved = null;
        errdefer switch (info.life_cycle) {
            .singleton, .scoped => new_root.deinit(self),
            .transient => if (storage != null) self.transient_services.tryPassToAvailable(storage.?, self),
        };

        // Instantiate the dependency based on its lifecycle configuration.
        switch (info.life_cycle) {
            .transient => {
                storage = try self.transient_services.findPartiallyDeinitOrCreate();
                storage.?.info = info;

                ctx.current_resolve = storage;
                const dep_info: *DependencyInfo(*T) = @ptrCast(@alignCast(info.ptr));

                const value = try self.build(ctx, T, dep_info);

                const ptr = try self.allocator.create(T);

                ptr.* = value;
                storage.?.ptr = ptr;
            },
            .singleton => {
                if (self.singleton.get(info.getName())) |singleton| {
                    storage = singleton;
                } else {
                    const dep_info: *DependencyInfo(*T) = @ptrCast(@alignCast(info.ptr));
                    const value = try self.build(ctx, T, dep_info);

                    const ptr: *T = try self.allocator.create(T);
                    errdefer self.allocator.destroy(ptr);

                    ptr.* = value;
                    new_root.ptr = ptr;

                    storage = try self.singleton.add(new_root);
                }
            },
            .scoped => {
                if (self.scope == null)
                    return ServiceProviderError.NoActiveScope;

                if (self.scope.?.resolved_services.get(info.getName())) |scoped| {
                    storage = scoped;
                } else {
                    const dep_info: *DependencyInfo(*T) = @ptrCast(@alignCast(info.ptr));
                    const value = try self.build(ctx, T, dep_info);

                    const ptr: *T = try self.allocator.create(T);
                    errdefer self.allocator.destroy(ptr);

                    ptr.* = value;
                    new_root.ptr = ptr;

                    storage = try self.scope.?.resolved_services.add(new_root);
                }
            },
        }

        // Restore the previous resolution context after completing the current dependency resolution.
        ctx.current_resolve = current_root;

        if (current_root != null) try current_root.?.child.append(storage.?);

        // Return the pointer to the newly resolved dependency.
        return @ptrCast(@alignCast(storage.?.ptr));
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
        self.sp.deinit();

        self.resolved_services.deinit(&self.sp);
        self.allocator.destroy(self.sp.scope.?);
    }
};

// Represents a resolved dependency within a resolution context.
// This structure holds the instance pointer and metadata about the dependency.
const Resolved = struct {
    const Self = @This();

    ptr: ?*anyopaque = null, // Pointer to the instantiated dependency instance.

    info: ?*IDependencyInfo = null, // Interface information for the dependency, including lifecycle and deinit function.

    child: std.ArrayList(*Resolved), // List of nested dependencies resolved by this dependency.

    allocator: std.mem.Allocator, // Allocator used for managing memory within this Resolved context.

    /// Constructs an empty Resolved instance with an initialized child list.
    ///
    /// Parameters:
    /// - `a`: Allocator for memory allocations within this Resolved instance.
    ///
    /// Returns:
    /// - A new, empty Resolved instance.
    pub fn empty(allocator: std.mem.Allocator) Self {
        return Self{
            .child = std.ArrayList(*Resolved).init(allocator),
            .allocator = allocator,
        };
    }

    /// Deinitializes the Resolved instance, recursively cleaning up all nested dependencies.
    pub fn deinit(self: *Self, sp: *ServiceProvider) void {
        defer self.child.clearAndFree();
        // Recursively deinitialize all child dependencies to ensure proper cleanup.
        if (self.info == null) return;

        // Deinitialize the dependency instance if it exists.
        if (self.ptr != null) {
            self.info.?.callDeinit(self.ptr.?, sp);
            self.info.?.destroyDependency(self.ptr.?, self.allocator);

            self.ptr = null;
        }

        self.info = null;
    }

    /// Recursively deinitializes only transient dependencies within this Resolved context.
    pub fn partiallyDeinit(self: *Self, sp: *ServiceProvider) void {
        // Recursively deinitialize all child dependencies to ensure proper cleanup.
        defer self.child.clearRetainingCapacity();
        if (self.info == null) return;

        // Deinitialize the dependency instance if it exists.
        if (self.ptr != null) {
            self.info.?.callDeinit(self.ptr.?, sp);
            self.info.?.destroyDependency(self.ptr.?, self.allocator);

            self.ptr = null;
        }

        self.info = null;
    }

    fn hasLifeCycle(self: *Self, life_cycle: dependency.LifeCycle) bool {
        return self.info != null and self.info.?.life_cycle == life_cycle;
    }

    pub const TransientIterator = struct {
        stack: std.ArrayList(*Resolved),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, root: *Resolved) !TransientIterator {
            var stack = std.ArrayList(*Resolved).init(allocator);

            if (root.hasLifeCycle(.transient))
                try stack.append(root);

            return .{
                .stack = stack,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *TransientIterator) void {
            self.stack.deinit();
        }

        pub fn next(self: *TransientIterator) ?*Resolved {
            if (self.stack.items.len == 0) return null;

            const current = self.stack.pop();

            // Add children in reverse order so they're processed left-to-right
            var i: usize = current.child.items.len;
            while (i > 0) {
                i -= 1;

                if (current.child.items[i].hasLifeCycle(.transient))
                    self.stack.append(current.child.items[i]) catch return null;
            }

            return current;
        }
    };
};

// Manages the context during dependency resolution, encapsulating the state required to resolve dependencies.
// This structure ensures that resolution state is maintained correctly and isolated per resolution process.
const BuilderContext = struct {
    const Self = @This();

    sp: *ServiceProvider, // Reference to the ServiceProvider responsible for resolving dependencies.
    active_root: ?*Resolved, // Root of the current resolution context, tracking the top-level dependency.
    current_resolve: ?*Resolved, // Pointer to the currently active Resolved context during the resolution process.

    info_chain: std.DoublyLinkedList(*IDependencyInfo),

    /// Initializes a new BuilderContext instance.
    ///
    /// Parameters:
    /// - `sp`: Reference to the ServiceProvider managing this resolution context.
    /// - `scope`: Optional scope within which scoped dependencies are resolved.
    /// - `allocator`: Allocator for memory allocations within the resolution context.
    ///
    /// Returns:
    /// - A newly initialized BuilderContext.
    pub fn init(sp: *ServiceProvider) Self {
        return Self{
            .sp = sp,
            .active_root = null,
            .current_resolve = null,
            .info_chain = std.DoublyLinkedList(*IDependencyInfo){},
        };
    }

    pub fn append(self: *Self, node: *std.DoublyLinkedList(*IDependencyInfo).Node) void {
        self.info_chain.append(node);
    }

    pub fn pop(self: *Self) void {
        _ = self.info_chain.pop();
    }

    pub fn verify(self: *Self) !void {
        var node = self.info_chain.first;

        if (node == null or
            node.?.data.isVerified())
            return;

        var visited = std.StringHashMap(bool).init(self.sp.allocator);
        defer visited.deinit();

        while (node != null) : (node = node.?.next) {
            if (visited.contains(node.?.data.getName()))
                return ServiceProviderError.CycleDependency;

            try visited.put(node.?.data.getName(), true);
        }
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

    items: *std.StringHashMap(*Resolved),
    allocator: std.mem.Allocator,

    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator) !Self {
        const items_ptr = try allocator.create(std.StringHashMap(*Resolved));
        items_ptr.* = std.StringHashMap(*Resolved).init(allocator);

        return Self{
            .items = items_ptr,
            .allocator = allocator,
            .mutex = Mutex{},
        };
    }

    pub fn deinit(self: *Self, sp: *ServiceProvider) void {
        var iter = self.items.valueIterator();
        while (iter.next()) |r| {
            r.*.deinit(sp);

            self.allocator.destroy(r.*);
        }

        self.items.deinit();
        self.allocator.destroy(self.items);
    }

    pub fn get(self: *Self, name: []const u8) ?*Resolved {
        return self.items.get(name);
    }

    pub fn add(self: *Self, resolved: Resolved) !*Resolved {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ptr = try self.allocator.create(Resolved);
        ptr.* = resolved;

        errdefer self.allocator.destroy(ptr);

        try self.items.put(resolved.info.?.getName(), ptr);
        return ptr;
    }
};

const TransientResolvedServices = struct {
    const Self = @This();

    items: std.ArrayList(*Resolved),
    available: std.ArrayList(*Resolved),

    allocator: std.mem.Allocator,

    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .items = std.ArrayList(*Resolved).init(allocator),
            .available = std.ArrayList(*Resolved).init(allocator),
            .allocator = allocator,
            .mutex = Mutex{},
        };
    }

    pub fn deinit(self: *Self, sp: *ServiceProvider) void {
        for (self.items.items) |r| {
            var mut = r;
            mut.deinit(sp);
        }

        for (self.items.items) |r| {
            self.allocator.destroy(r);
        }

        self.items.deinit();
        self.available.deinit();
    }

    pub fn delete(self: *Self, ptr: *anyopaque, info: *IDependencyInfo, sp: *ServiceProvider) bool {
        var found_idx: ?usize = null;

        for (self.items.items, 0..) |resolved, i| {
            if (resolved.ptr != null and
                resolved.ptr.? == ptr and
                resolved.info.? == info)
                found_idx = i;
        }

        if (found_idx == null)
            return false;

        const found = self.items.items[found_idx.?];

        self.makeAvailable(found, sp, found_idx);

        return true;
    }

    pub fn findPartiallyDeinitOrCreate(self: *Self) !*Resolved {
        self.mutex.lock();
        defer self.mutex.unlock();

        var ptr = self.available.popOrNull();
        if (ptr == null) {
            ptr = try self.addNewPtr();
        }

        return ptr.?;
    }

    fn addNewPtr(self: *Self) !*Resolved {
        const ptr = try self.allocator.create(Resolved);
        ptr.* = Resolved.empty(self.allocator);

        try self.items.append(ptr);
        return self.items.items[self.items.items.len - 1];
    }

    pub fn tryPassToAvailable(self: *Self, resolved: *Resolved, sp: *ServiceProvider) void {
        if (resolved.info == null or resolved.info.?.life_cycle != .transient)
            return;

        self.makeAvailable(resolved, sp, null);
    }

    fn getIdx(self: *Self, resolved: *Resolved) ?usize {
        for (self.items.items, 0..) |r, i| {
            if (resolved == r)
                return i;
        }

        return null;
    }

    pub fn makeAvailable(self: *Self, resolved: *Resolved, sp: *ServiceProvider, idx: ?usize) void {
        var swa = std.heap.stackFallback(1024, self.allocator);
        var iter = Resolved.TransientIterator.init(swa.get(), resolved) catch {
            const found_idx = idx orelse self.getIdx(resolved) orelse return;
            _ = self.items.swapRemove(found_idx);

            resolved.deinit(sp);
            self.allocator.destroy(resolved);

            return;
        };
        defer iter.deinit();

        while (iter.next()) |next| {
            next.partiallyDeinit(sp);

            self.available.append(next) catch {
                const found_idx = idx orelse self.getIdx(resolved) orelse return;
                _ = self.items.swapRemove(found_idx);

                next.deinit(sp);
                self.allocator.destroy(next);
            };
        }
    }
};
