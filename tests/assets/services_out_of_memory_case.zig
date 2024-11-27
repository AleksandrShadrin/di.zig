const std = @import("std");
const di = @import("di");

pub const A = struct {
    b: *B,

    pub fn init(sp: *di.ServiceProvider) !@This() {
        const b = try sp.resolve(B);
        return @This(){
            .b = b,
        };
    }
};

pub const B = struct {
    f: u8 = 22,
    pub fn init(sp: *di.ServiceProvider) !B {
        sp.allocator = std.testing.failing_allocator;
        return B{};
    }
};
