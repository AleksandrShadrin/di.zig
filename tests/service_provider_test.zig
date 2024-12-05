const std = @import("std");
const di = @import("di");

const Container = di.Container;
const LifeCycle = di.LifeCycle;
const ContainerError = di.ContainerError;

test "Service Provider - Should resolve singleton services correct" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const simple_dep = @import("assets/simple_dependency.zig");
    try container.registerSingleton(simple_dep.A);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    const service1 = try sp.resolve(simple_dep.A);
    const service2 = try sp.resolve(simple_dep.A);

    try std.testing.expect(service1 == service2);
}

test "Service Provider - Should resolve transient services correct" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const simple_dep = @import("assets/simple_dependency.zig");
    try container.registerTransient(simple_dep.A);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    const service1 = try sp.resolve(simple_dep.A);
    const service2 = try sp.resolve(simple_dep.A);

    try std.testing.expect(service1 != service2);
}

test "Service Provider - Should resolve services if it's zero-sized" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const zero_sized_dep = struct {
        pub fn init() @This() {
            return @This(){};
        }
    };
    try container.registerTransient(zero_sized_dep);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    // Verify zero-sized dependencies which resolved together should point to same memory
    const service1 = try sp.resolve(zero_sized_dep);
    const service2 = try sp.resolve(zero_sized_dep);

    try std.testing.expect(service1 == service2);
}

test "Service Provider - Should resolve services correct when used builtin dependencies" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const services = @import("assets/service_with_builtin_dependecies.zig");
    try container.registerTransient(services.A);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    // Verify zero-sized dependencies which resolved together should point to same memory
    const a = try sp.resolve(services.A);

    try std.testing.expect(a.sp == &sp);
    try std.testing.expect(a.a.ptr == allocator.ptr);
}

test "Service Provider - Should resolve services correct and call deinit when using unresolve" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const statement = "service deinitialized";

    const Interceptor = @import("mocks/interceptor.zig").Interceptor;

    const service = struct {
        interceptor: *Interceptor,

        pub fn init(interceptor: *Interceptor) @This() {
            return @This(){
                .interceptor = interceptor,
            };
        }

        pub fn deinit(self: *@This()) !void {
            try self.interceptor.confirm(statement);
        }
    };

    try container.registerTransient(service);
    try container.registerSingleton(Interceptor);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    // Verify zero-sized dependencies which resolved together should point to same memory
    const a = try sp.resolve(service);
    try sp.unresolve(a);

    const interceptor = try sp.resolve(Interceptor);
    try interceptor.assert_confirmed(statement);
}

test "Service Provider - Should not allocate services when allocator error" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const services = @import("assets/services_out_of_memory_case.zig");

    try container.registerTransient(services.A);
    try container.registerSingleton(services.B);

    var sp = try container.createServiceProvider();
    sp.allocator = std.testing.failing_allocator;

    defer {
        sp.allocator = allocator;
        sp.deinit();
    }

    const service_1 = sp.resolve(services.A);
    try std.testing.expectError(std.mem.Allocator.Error.OutOfMemory, service_1);

    const service_2 = sp.resolve(services.B);
    try std.testing.expectError(std.mem.Allocator.Error.OutOfMemory, service_2);
}

test "Service Provider - Should create scope and correct resolve services" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const simple_dep = @import("assets/simple_dependency.zig");
    const service = struct {
        a: *simple_dep.A,

        pub fn init(a: *simple_dep.A) @This() {
            return @This(){
                .a = a,
            };
        }
    };
    try container.registerScoped(simple_dep.A);
    try container.registerTransient(service);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    var scope = try sp.initScope();
    defer scope.deinit();

    const service1 = try scope.resolve(simple_dep.A);
    const service2 = try scope.resolve(simple_dep.A);

    try std.testing.expect(service1 == service2);

    const service3 = try scope.resolve(service);

    try std.testing.expect(service3.a == service2);
}

test "Service Provider - Should correctly allocate services when resolving error" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const mock_err = error{e};
    const service1 = struct {
        f: u8 = 12,

        pub fn init() !@This() {
            return mock_err.e;
        }
    };

    const service2 = struct {
        f: u8 = 12,

        pub fn init() !@This() {
            return mock_err.e;
        }
    };
    try container.registerTransient(service1);
    try container.registerSingleton(service2);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    const service_1 = sp.resolve(service1);
    try std.testing.expectError(mock_err.e, service_1);

    const service_2 = sp.resolve(service2);
    try std.testing.expectError(mock_err.e, service_2);
}

test "Service Provider - In scope should correctly allocate services when resolving error" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const mock_err = error{e};
    const service = struct {
        f: u8 = 12,

        pub fn init() !@This() {
            return mock_err.e;
        }
    };

    try container.registerScoped(service);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    var scope = try sp.initScope();
    defer scope.deinit();

    const service1 = scope.resolve(service);
    try std.testing.expectError(mock_err.e, service1);
}

test "Service Provider - Should correctly work when service resolved inside of service" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const services = @import("assets/services_with_inner_resolving.zig");
    try container.registerTransient(services.A);
    try container.registerTransient(services.B);
    try container.registerTransient(services.C);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    _ = try sp.resolve(services.A);
}

test "Service Provider - Should validate generics for cycles" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const services = @import("assets/services_runtime_generic_validation.zig");
    try container.registerTransient(services.A);
    try container.registerTransient(services.B);
    try container.registerTransient(services.C);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    const service = sp.resolve(services.B);
    try std.testing.expectError(di.ServiceProviderError.CycleDependency, service);
}

test "Service Provider - Should correctly resolve generics" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const services = @import("assets/services_correct_generics.zig");
    try container.registerTransient(services.A);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    _ = try sp.resolve(di.Generic(services.A, .{u8}));
}

test "Service Provider - Should return UnresolveLifeCycleShouldBeTransient when try unresolve service with no transient life cycle" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const services = @import("assets/services_correct_generics.zig");
    try container.registerSingleton(services.A(u5));
    try container.registerScoped(services.A(u6));
    try container.registerTransient(services.A(u7));

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    const singleton = try sp.resolve(services.A(u5));

    var err = sp.unresolve(singleton);
    try std.testing.expectError(di.ServiceProviderError.UnresolveLifeCycleShouldBeTransient, err);

    const scope = try sp.initScope();
    defer scope.deinit();

    const scoped = try scope.resolve(services.A(u6));

    err = scope.sp.unresolve(scoped);
    try std.testing.expectError(di.ServiceProviderError.UnresolveLifeCycleShouldBeTransient, err);

    const transient = try sp.resolve(services.A(u7));

    try sp.unresolve(transient);
}

test "Service Provider - Should return NoResolveContextFound when try unresolve pointer created not by provider" {
    const allocator = std.testing.allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    const services = @import("assets/simple_dependency.zig");
    try container.registerTransient(services.A);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    const p = try allocator.create(services.A);
    defer allocator.destroy(p);

    const err = sp.unresolve(p);
    try std.testing.expectError(di.ServiceProviderError.NoResolveContextFound, err);

    const sp_p = try sp.resolve(services.A);
    try sp.unresolve(sp_p);
}

test "Service Provider - Should be able to pass itself on deinit call" {
    const allocator = std.testing.allocator;

    var container = Container.init(allocator);
    defer container.deinit();

    const statement = "ServiceProvider passed";

    const Interceptor = @import("mocks/interceptor.zig").Interceptor;
    const Service = struct {
        pub fn init() @This() {
            return .{};
        }

        pub fn deinit(self: @This(), sp: *di.ServiceProvider) !void {
            _ = self;
            var interceptor = try sp.resolve(Interceptor);
            try interceptor.confirm(statement);
        }
    };

    try container.registerSingleton(Interceptor);
    try container.registerTransient(Service);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    const service = try sp.resolve(Service);
    try sp.unresolve(service);

    const interceptor = try sp.resolve(Interceptor);
    try interceptor.assert_confirmed(statement);
}

test "Service Provider - Should deinit correct for many resolved services" {
    const allocator = std.testing.allocator;

    var container = Container.init(allocator);
    defer container.deinit();

    const service = @import("assets/services_with_inner_resolve_and_deinit.zig");

    try container.registerTransient(service.A);
    try container.registerTransient(service.B);
    try container.registerTransient(service.C);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    _ = try sp.resolve(service.A);
    _ = try sp.resolve(service.A);
    _ = try sp.resolve(service.A);
}

test "Service Provider - Should deinit failed dependency" {
    const allocator = std.testing.allocator;

    var container = Container.init(allocator);
    defer container.deinit();

    const service = @import("assets/resolving_error.zig");

    try container.registerTransient(service.A);
    try container.registerSingleton(service.B);
    try container.registerTransient(service.C);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    _ = sp.resolve(service.A) catch {};
    try std.testing.expect(sp.transient_services.items.items.len == 0);
    try std.testing.expect(sp.singleton.items.count() == 1);
}

test "Service Provider - Should not add failed singleton dependency" {
    const allocator = std.testing.allocator;

    var container = Container.init(allocator);
    defer container.deinit();

    const service = @import("assets/resolving_error.zig");

    try container.registerSingleton(service.A);
    try container.registerSingleton(service.B);
    try container.registerSingleton(service.C);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    _ = sp.resolve(service.A) catch {};
    try std.testing.expect(sp.singleton.items.count() == 1);
}

test "Service Provider - Should leak inner resolve dependency on fail build" {
    const allocator = std.testing.allocator;

    var container = Container.init(allocator);
    defer container.deinit();

    const service = @import("assets/resolving_error_leak.zig");

    try container.registerTransient(service.A);
    try container.registerTransient(service.B);
    try container.registerTransient(service.C);
    try container.registerTransient(service.D);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    const a = sp.resolve(service.A);
    try std.testing.expectError(service.e.some_error, a);

    // leaked
    try std.testing.expect(sp.transient_services.items.items.len == 1);
}

test "Service Provider - Should deinit inner resolve dependency on both fail build" {
    const allocator = std.testing.allocator;

    var container = Container.init(allocator);
    defer container.deinit();

    const service = @import("assets/resolving_error_leak_in_inner_resolve.zig");

    try container.registerTransient(service.A);
    try container.registerTransient(service.B);
    try container.registerTransient(service.C);
    try container.registerTransient(service.D);
    try container.registerTransient(service.E);

    var sp = try container.createServiceProvider();
    defer sp.deinit();

    const a = sp.resolve(service.A);
    try std.testing.expectError(service.err.some_error, a);

    // leaked
    try std.testing.expect(sp.transient_services.items.items.len == 0);
}
