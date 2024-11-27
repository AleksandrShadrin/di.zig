pub const A = struct {
    b: *B,

    pub fn init(b: *B) A {
        return A{
            .b = b,
        };
    }
};

pub const B = struct {
    a: *A,

    pub fn init(a: *A) B {
        return B{
            .a = a,
        };
    }
};
