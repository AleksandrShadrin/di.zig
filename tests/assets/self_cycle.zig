pub const A = struct {
    pub fn init(this: *A) A {
        _ = this;
        return A{};
    }
};
