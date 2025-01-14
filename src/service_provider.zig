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
    singleton_locks: ?SingletonLocks = null,

    scope: ?*Scope = null,
    parent: ?*ServiceProvider = null,

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
            .singleton_locks = SingletonLocks.init(allocator),
        };
    }

    fn clone(self: *Self, allocator: std.mem.Allocator) !Self {
        return Self{
            .singleton = self.singleton,
            .allocator = allocator,
            .container = self.container,
            .transient_services = TransientResolvedServices.init(allocator),
        };
    }

    /// Deinitializes the ServiceProvider, ensuring all managed dependencies are properly cleaned up.
    pub fn deinit(self: *Self) void {
        // Iterate through all root resolution contexts and deinitialize transient dependencies.
        self.transient_services.deinit(self);

        if (self.parent == null)
            self.singleton.deinit(self);

        if (self.singleton_locks != null)
            self.singleton_locks.?.deinit();
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

        if (utilities.isSlice(dereferenced_type)) {
            if (!self.transient_services.delete(getPtr(T), null, self)) return ServiceProviderError.NoResolveContextFound;
            return;
        }

        // Fetch the dependency information from the container.
        const info = self.container.getDependencyInfo(dereferenced_type) orelse return ServiceProviderError.ServiceNotFound;

        // Only dependencies with a transient lifecycle are eligible for unresolution.
        if (info.life_cycle != .transient)
            return ServiceProviderError.UnresolveLifeCycleShouldBeTransient;

        // delete simple dependency
        if (!self.transient_services.delete(getPtr(T), info, self)) return ServiceProviderError.NoResolveContextFound;
    }

    inline fn getPtr(T: anytype) *anyopaque {
        if (utilities.isSlice(@TypeOf(T)))
            return @ptrCast(@constCast(T.ptr));

        return @as(*anyopaque, T);
    }

    /// Determines the error type based on the type `T` being resolved.
    ///
    /// - If `T` is an Allocator, it returns `anyerror!T`.
    /// - Otherwise, it returns `anyerror!*T`.
    inline fn getResolveType(comptime T: type) type {
        if (T == std.mem.Allocator) {
            return anyerror!T;
        } else if (utilities.isSlice(T)) {
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
        const result = try self.inner_resolve(&ctx, T);
        return result;
    }

    pub fn resolveSlice(self: *Self, comptime T: type) ![]const *T {
        // Initialize a new BuilderContext for this resolution operation.
        var ctx = BuilderContext.init(self);

        // Perform the actual resolution using the internal resolve method.
        const result = try self.resolveStrategy(&ctx, []const *T);
        return result;
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
        const resolved = try self.resolveStrategy(ctx, T);

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
    fn resolveStrategy(self: *Self, ctx: *BuilderContext, comptime T: type) getResolveType(T) {
        // Special case handling for Allocator type.
        if (T == std.mem.Allocator)
            return self.allocator;

        // Special case handling for the ServiceProvider type.
        if (T == Self) {
            return ctx.sp;
        }

        const dereferenced_type: type = utilities.deref(T);

        // Determine if the type is generic and delegate to the appropriate builder method.
        if (utilities.isSlice(T)) {
            const child = utilities.deref(std.meta.Child(T));
            return try self.buildSlice(ctx, child);
        } else if (generic.isGeneric(dereferenced_type)) {
            return try self.buildGenericType(ctx, dereferenced_type);
        } else {
            const info = self.container.getDependencyInfo(dereferenced_type) orelse return ServiceProviderError.ServiceNotFound;
            return try self.buildSimpleType(ctx, dereferenced_type, info);
        }
    }

    fn buildSlice(self: *Self, ctx: *BuilderContext, T: type) ![]const *T {
        var resolved = try self.transient_services.findPartiallyDeinitOrCreate();
        resolved.is_slice = true;

        errdefer self.transient_services.tryPassToAvailable(resolved, self);

        const infos = try self.container.getDependencyWithFactories(T);
        var len: usize = if (infos.dependency != null) 1 else 0;
        len += infos.factories.len;

        if (len == 0) {
            if (ctx.root == null) ctx.root = resolved;
            return &.{};
        }

        var slice = try self.allocator.alloc(*T, len);
        errdefer self.allocator.free(slice);

        var createdServicesLen: usize = 0;

        if (infos.dependency != null) {
            var in_ctx = BuilderContext.init(self);
            in_ctx.root = resolved;

            slice[0] = try self.buildSimpleType(&in_ctx, T, infos.dependency.?);

            createdServicesLen += 1;
        }

        for (infos.factories) |info| {
            var in_ctx = BuilderContext.init(self);
            in_ctx.root = resolved;

            slice[createdServicesLen] = try self.buildSimpleType(&in_ctx, T, info);

            createdServicesLen += 1;
        }

        if (ctx.root != null) try ctx.root.?.child.append(resolved) else ctx.root = resolved;

        resolved.ptr = @ptrCast(@alignCast(slice.ptr));

        return slice;
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
        const info = try container.getOrAddGeneric(self.container, T);
        return try self.buildSimpleType(ctx, T, info);
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
    fn buildSimpleType(self: *Self, ctx: *BuilderContext, T: type, info: *IDependencyInfo) !*T {
        var new_root = Resolved.empty(self.allocator);
        new_root.info = info;

        const current_root = ctx.root;
        ctx.root = &new_root;

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

                ctx.root = storage;
                const dep_info: *DependencyInfo(*T) = @ptrCast(@alignCast(info.ptr));

                const value = try self.build(ctx, T, dep_info);

                const ptr = try self.allocator.create(T);

                ptr.* = value;
                storage.?.ptr = ptr;
            },
            .singleton => {
                const root_sp = self.getRoot();
                new_root.allocator = root_sp.allocator;

                const mutex = try root_sp.singleton_locks.?.acquireLock(info);
                defer mutex.unlock();

                if (self.singleton.get(info)) |singleton| {
                    storage = singleton;
                } else {
                    const dep_info: *DependencyInfo(*T) = @ptrCast(@alignCast(info.ptr));
                    const value = try self.build(ctx, T, dep_info);

                    const ptr: *T = try root_sp.allocator.create(T);
                    errdefer root_sp.allocator.destroy(ptr);

                    ptr.* = value;
                    new_root.ptr = ptr;

                    storage = try self.singleton.add(new_root);
                }
            },
            .scoped => {
                if (self.scope == null)
                    return ServiceProviderError.NoActiveScope;

                if (self.scope.?.resolved_services.get(info)) |scoped| {
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

        if (current_root != null) {
            ctx.root = current_root;
            try current_root.?.child.append(storage.?);
        }

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
        const sp = switch (dep_info.life_cycle) {
            .scoped, .transient => self,
            .singleton => self.getRoot(),
        };

        const called_from = ctx.sp;
        ctx.sp = sp;

        defer ctx.sp = called_from;

        if (dep_info.builder == null) {
            // If no custom builder is provided, utilize the default compile-time builder.
            var b = ServiceProviderBuilder(T).createBuilder();
            return try b.buildFn(ctx);
        } else {
            // Use the custom builder function specified in the dependency's configuration.
            return try dep_info.builder.?.build(sp);
        }
    }

    pub fn initScope(self: *Self) !*Scope {
        return try self.initScopeWithAllocator(self.allocator);
    }

    pub fn initScopeWithAllocator(self: *Self, allocator: std.mem.Allocator) !*Scope {
        var sp = try self.clone(allocator);

        sp.parent = self.getRoot();

        const scope_ptr = try allocator.create(Scope);
        errdefer allocator.destroy(scope_ptr);

        sp.scope = scope_ptr;

        scope_ptr.* = try Scope.init(sp, allocator);
        return scope_ptr;
    }

    fn getRoot(self: *Self) *Self {
        return self.parent orelse self;
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

    is_slice: bool = false,

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
        defer {
            self.child.clearAndFree();
            self.is_slice = false;
            self.info = null;
        }

        // Deinitialize the dependency instance
        if (self.is_slice) self.deinitSlice(sp) else self.deinitDependency(sp);
    }

    pub fn partiallyDeinit(self: *Self, sp: *ServiceProvider) void {
        defer {
            self.child.clearRetainingCapacity();
            self.is_slice = false;
            self.info = null;
        }

        // Deinitialize the dependency instance
        if (self.is_slice) self.deinitSlice(sp) else self.deinitDependency(sp);
    }

    fn deinitDependency(self: *Self, sp: *ServiceProvider) void {
        if (self.ptr == null)
            return;

        self.info.?.callDeinit(self.ptr.?, sp);
        self.info.?.destroyDependency(self.ptr.?, self.allocator);

        self.ptr = null;
    }

    fn deinitSlice(self: *Self, sp: *ServiceProvider) void {
        if (self.ptr == null)
            return;

        const slice: []*anyopaque = @as([*]*anyopaque, @ptrCast(@alignCast(self.ptr)))[0..self.child.items.len];

        sp.allocator.free(slice);
        self.ptr = null;
    }

    fn isTransient(self: *Self) bool {
        return self.is_slice or
            (self.info != null and self.info.?.life_cycle == .transient);
    }

    pub const TransientIterator = struct {
        stack: std.ArrayList(*Resolved),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, root: *Resolved) !TransientIterator {
            var stack = std.ArrayList(*Resolved).init(allocator);

            if (root.isTransient())
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

                if (current.child.items[i].isTransient())
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
    root: ?*Resolved, // Pointer to the currently active Resolved context during the resolution process.

    /// Initializes a new BuilderContext instance.
    ///
    /// Parameters:
    /// - `sp`: Reference to the ServiceProvider managing this resolution context.
    ///
    /// Returns:
    /// - A newly initialized BuilderContext.
    pub fn init(sp: *ServiceProvider) Self {
        return Self{
            .sp = sp,
            .root = null,
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
                tuple[i] = try b_ctx.sp.resolveStrategy(b_ctx, utilities.deref(arg_type));
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

const SingletonLocks = struct {
    const Self = @This();

    locks: std.AutoHashMap(*IDependencyInfo, Mutex),
    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .locks = std.AutoHashMap(*IDependencyInfo, Mutex).init(allocator),
            .mutex = Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.locks.deinit();
    }

    // lock founded mutex or create new and lock it.
    // Mutext should be unlocked from inner
    pub fn acquireLock(self: *Self, info: *IDependencyInfo) !*Mutex {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = try self.locks.getOrPut(info);
        if (result.found_existing) {
            result.value_ptr.lock();
            return result.value_ptr;
        }

        result.value_ptr.* = Mutex{};
        result.value_ptr.lock();

        return result.value_ptr;
    }
};

const OnceResolvedServices = struct {
    const Self = @This();

    items: *std.AutoHashMap(*IDependencyInfo, *Resolved),
    allocator: std.mem.Allocator,

    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator) !Self {
        const items_ptr = try allocator.create(std.AutoHashMap(*IDependencyInfo, *Resolved));
        items_ptr.* = std.AutoHashMap(*IDependencyInfo, *Resolved).init(allocator);

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

    pub fn get(self: *Self, info: *IDependencyInfo) ?*Resolved {
        return self.items.get(info);
    }

    pub fn add(self: *Self, resolved: Resolved) !*Resolved {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = try self.items.getOrPut(resolved.info.?);
        errdefer _ = self.items.remove(resolved.info.?);

        if (!entry.found_existing) {
            const ptr = try self.allocator.create(Resolved);
            ptr.* = resolved;

            entry.value_ptr.* = ptr;
        }

        return entry.value_ptr.*;
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

    pub fn delete(self: *Self, ptr: *anyopaque, info: ?*IDependencyInfo, sp: *ServiceProvider) bool {
        var found_idx: usize = undefined;

        if (info == null) {
            found_idx = self.searchByPtr(ptr) orelse return false;
        } else {
            found_idx = self.searchByPtrAndInfo(ptr, info.?) orelse return false;
        }

        const found = self.items.items[found_idx];

        self.makeAvailable(found, sp, found_idx);

        return true;
    }

    fn searchByPtr(self: *Self, ptr: *anyopaque) ?usize {
        for (self.items.items, 0..) |r, i| {
            if (r.ptr != null and
                r.ptr.? == ptr)
                return i;
        }

        return null;
    }

    fn searchByPtrAndInfo(self: *Self, ptr: *anyopaque, info: *IDependencyInfo) ?usize {
        for (self.items.items, 0..) |r, i| {
            if (r.ptr != null and
                r.info != null and
                r.ptr.? == ptr and
                r.info.? == info)
                return i;
        }

        return null;
    }

    pub fn findPartiallyDeinitOrCreate(self: *Self) !*Resolved {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.available.popOrNull() orelse try self.addNewPtr();
    }

    fn addNewPtr(self: *Self) !*Resolved {
        const ptr = try self.allocator.create(Resolved);
        ptr.* = Resolved.empty(self.allocator);

        try self.items.append(ptr);
        return self.items.items[self.items.items.len - 1];
    }

    pub fn tryPassToAvailable(self: *Self, resolved: *Resolved, sp: *ServiceProvider) void {
        if (!resolved.isTransient())
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
