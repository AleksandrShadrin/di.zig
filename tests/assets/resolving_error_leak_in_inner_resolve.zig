const di = @import("di");

pub const err = error{some_error};

pub const A = struct {
    pub fn init(b: *B, c: *C) !A {
        _ = c;
        _ = b;

        return A{};
    }
};

pub const B = struct {
    pub fn init(sp: *di.ServiceProvider) !B {
        _ = try sp.resolve(D);
        return B{};
    }
};

pub const C = struct {
    pub fn init() !C {
        return err.some_error;
    }
};

pub const D = struct {
    pub fn init(e: *E) D {
        _ = e;
        return D{};
    }
};

pub const E = struct {
    pub fn init() !E {
        return err.some_error;
    }
};
