const di = @import("di");

pub const e = error{some_error};

pub const A = struct {
    pub fn init(b: *B, c: *C) !A {
        _ = c;
        _ = b;

        return A{};
    }
};

pub const B = struct {
    pub fn init(sp: *di.ServiceProvider) !B {
        // not tracked -> leaked
        _ = try sp.resolve(D);
        return B{};
    }
};

pub const C = struct {
    pub fn init() !C {
        return e.some_error;
    }
};

pub const D = struct {
    pub fn init() D {
        return D{};
    }
};
