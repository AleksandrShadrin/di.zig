const std = @import("std");
const ServiceProvider = @import("di").ServiceProvider;

pub const A = struct {
    a: std.mem.Allocator,
    sp: *ServiceProvider,

    pub fn init(allocator: std.mem.Allocator, sp: *ServiceProvider) A {
        return A{
            .a = allocator,
            .sp = sp,
        };
    }
};
