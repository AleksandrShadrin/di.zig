pub fn A(comptime T: type) type {
    return struct {
        pub fn init() @This() {
            _ = T;
            return @This(){};
        }
    };
}
