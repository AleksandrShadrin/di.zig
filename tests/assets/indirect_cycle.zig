pub const A = struct {
    b: *B,

    pub fn init(b: *B) A {
        return A{
            .b = b,
        };
    }
};

pub const B = struct {
    c: *C,

    pub fn init(c: *C) B {
        return B{
            .c = c,
        };
    }
};

pub const C = struct {
    a: *A,

    pub fn init(a: *A) C {
        return C{
            .a = a,
        };
    }
};
