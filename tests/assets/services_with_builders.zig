const Interceptor = @import("../mocks/interceptor.zig").Interceptor;
const di = @import("di");

pub const statements = .{
    .init = "init",
    .build1 = "builded 1",
    .build2 = "builded 2",
    .build3 = "builded 3",
};

pub const A = struct {
    pub fn init(interceptor: *Interceptor) !A {
        try interceptor.confirm(statements.init);

        return A{};
    }

    pub fn build1(sp: *di.ServiceProvider) !A {
        const interceptor = try sp.resolve(Interceptor);
        try interceptor.confirm(statements.build1);

        return A{};
    }

    pub fn build2(sp: *di.ServiceProvider) !A {
        const interceptor = try sp.resolve(Interceptor);
        try interceptor.confirm(statements.build2);

        return A{};
    }

    pub fn build3(sp: *di.ServiceProvider) !A {
        const interceptor = try sp.resolve(Interceptor);
        try interceptor.confirm(statements.build3);

        return A{};
    }
};
