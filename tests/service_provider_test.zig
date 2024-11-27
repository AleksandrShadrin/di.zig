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