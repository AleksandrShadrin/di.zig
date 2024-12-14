const di = @import("di");

pub const err = error{some_error};

pub const A = struct {
    pub fn init() A {
        return A{};
    }

    pub fn build1() A {
        return A{};
    }

    pub fn build2() A {
        return A{};
    }

    pub fn build3() !A {
        return err.some_error;
    }
};
