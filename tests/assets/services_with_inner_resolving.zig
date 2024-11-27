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
    c: *C,
    pub fn init(sp: *di.ServiceProvider) !B {
        const c = try sp.resolve(C);
        return B{
            .c = c,
        };
    }
};

pub const C = struct {
    pub fn init() C {
        return C{};
    }
};
