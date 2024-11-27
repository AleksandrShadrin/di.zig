const di = @import("di");

pub fn A(comptime T: type) type {
    return struct {
        t: *T,

        pub fn init(t: *T) @This() {
            return @This(){
                .t = t,
            };
        }
    };
}

pub const B = struct {
    pub fn init(a: *C) B {
        _ = a;
        return B{};
    }
};

pub const C = struct {
    pub fn init(a: *di.Generic(A, .{B})) C {
        _ = a;
        return C{};
    }
};
