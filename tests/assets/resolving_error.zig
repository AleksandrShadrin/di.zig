const di = @import("di");

const e = error{some_error};

pub const A = struct {
    pub fn init(b: *B, c: *C) A {
        _ = b;
        _ = c;

        return A{};
    }
};

pub const B = struct {
    pub fn init() B {
        return B{};
    }
};

pub const C = struct {
    pub fn init() !C {
        return e.some_error;
    }
};
