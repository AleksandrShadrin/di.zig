const std = @import("std");
const di = @import("di");

pub const Mediatr = struct {
    const Self = @This();

    sp: *di.ServiceProvider,

    pub fn init(sp: *di.ServiceProvider) Self {
        return Self{
            .sp = sp,
        };
    }

    pub fn addHandler(container: *di.Container, HandlerType: type) !void {
        const handler_fn = @typeInfo(@TypeOf(HandlerType.handle)).Fn;
        comptime var return_type = handler_fn.return_type.?;

        if (@typeInfo(return_type) == .ErrorUnion)
            return_type = @typeInfo(return_type).ErrorUnion.payload;

        if (handler_fn.params.len != 2 or
            handler_fn.params[0].type.? != *HandlerType)
            @compileError(@typeName(HandlerType) ++ " should have handle with signature fn (*Self, *ReqeustType)");

        const Request = std.meta.Child(handler_fn.params[1].type.?);

        try container.registerScoped(HandlerType);

        const create_handler = struct {
            pub fn create_handler(sp: *di.ServiceProvider) !Handler(Request, return_type) {
                const h = try sp.resolve(HandlerType);
                return Handler(Request, return_type){
                    .ctx = h,
                    .handle_fn = call_handler,
                    .deinit_fn = deinit_handler,
                };
            }

            pub fn call_handler(ctx: *anyopaque, request: *Request) !return_type {
                const h: *HandlerType = @ptrCast(@alignCast(ctx));
                if (@typeInfo(return_type) == .ErrorUnion) {
                    return try h.handle(request);
                } else {
                    return h.handle(request);
                }
            }

            pub fn deinit_handler(handler: *Handler(Request, return_type), sp: *di.ServiceProvider) !void {
                const h: *HandlerType = @ptrCast(@alignCast(handler.ctx));
                try sp.unresolve(h);
            }
        }.create_handler;

        try container.registerScopedWithFactory(create_handler);
    }

    pub fn addBehavior(container: *di.Container, BehaviorType: type) !void {
        const handler_fn = @typeInfo(@TypeOf(BehaviorType.handle)).Fn;
        comptime var return_type = handler_fn.return_type.?;

        if (@typeInfo(return_type) == .ErrorUnion)
            return_type = @typeInfo(return_type).ErrorUnion.payload;

        const Request = std.meta.Child(handler_fn.params[1].type.?);

        if (handler_fn.params.len != 3 or
            handler_fn.params[0].type.? != *BehaviorType and
            handler_fn.params[2].type.? != *Behavior(Request, return_type))
            @compileError(@typeName(BehaviorType) ++ " should have handle with signature fn (*Self, *ReqeustType, NextDelegate(GreetHandler.Output))");

        try container.registerScoped(BehaviorType);

        const create_handler = struct {
            pub fn create_handler(sp: *di.ServiceProvider) !Behavior(Request, return_type) {
                const h = try sp.resolve(BehaviorType);
                return Behavior(Request, return_type){
                    .ctx = h,
                    .handle_fn = call_handler,
                    .deinit_fn = deinit_handler,
                };
            }

            pub fn call_handler(ctx: *anyopaque, request: *Request, next: NextDelegate(return_type)) !return_type {
                const h: *BehaviorType = @ptrCast(@alignCast(ctx));
                if (@typeInfo(return_type) == .ErrorUnion) {
                    return try h.handle(request, next);
                } else {
                    return h.handle(request, next);
                }
            }

            pub fn deinit_handler(handler: *Behavior(Request, return_type), sp: *di.ServiceProvider) !void {
                const h: *BehaviorType = @ptrCast(@alignCast(handler.ctx));
                try sp.unresolve(h);
            }
        }.create_handler;

        try container.registerScopedWithFactory(create_handler);
    }

    pub fn send(self: *Self, request: anytype, output: type) !output {
        const Request = std.meta.Child(@TypeOf(request));

        const handler = try self.sp.resolve(Handler(Request, output));
        const behaviors = try self.sp.resolveSlice(Behavior(Request, output));

        defer self.sp.unresolve(behaviors) catch {};

        const Ctx = struct {
            ptr: *anyopaque,
            req: *Request,

            next: ?*@This(),
            wrap_fn: *const fn (*anyopaque) anyerror!output,
        };

        var calls_ctx = try std.ArrayList(Ctx)
            .initCapacity(self.sp.allocator, behaviors.len);
        calls_ctx.expandToCapacity();

        defer calls_ctx.deinit();

        const behavior_wrapper = struct {
            fn wrapper(ctx: *anyopaque) !output {
                const real_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                const behavior: *Behavior(Request, output) = @ptrCast(@alignCast(real_ctx.ptr));

                return behavior.handle(real_ctx.req, .{
                    .ptr = real_ctx.next.?,
                    .handle_fn = real_ctx.next.?.wrap_fn,
                });
            }
        }.wrapper;

        const handler_wrapper = struct {
            fn wrapper(ctx: *anyopaque) !output {
                const real_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                const h: *Handler(Request, output) = @ptrCast(@alignCast(real_ctx.ptr));

                return h.handle(real_ctx.req);
            }
        }.wrapper;

        if (behaviors.len == 0) {
            return try handler.handle(request);
        }

        for (0..behaviors.len) |i| {
            calls_ctx.items[i] = Ctx{
                .ptr = @as(*anyopaque, behaviors[i]),
                .req = request,
                .next = if (i == behaviors.len - 1) null else &calls_ctx.items[i + 1],
                .wrap_fn = behavior_wrapper,
            };
        }

        var handler_ctx = Ctx{
            .ptr = @as(*anyopaque, handler),
            .req = request,
            .wrap_fn = handler_wrapper,
            .next = null,
        };

        calls_ctx.items[calls_ctx.items.len - 1].next = &handler_ctx;

        return try behavior_wrapper(@as(*anyopaque, &calls_ctx.items[0]));
    }
};

pub fn Handler(TIn: type, TOut: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,

        handle_fn: *const fn (*anyopaque, *TIn) anyerror!TOut,
        deinit_fn: *const fn (*Self, *di.ServiceProvider) anyerror!void,

        pub fn deinit(self: *Self, sp: *di.ServiceProvider) void {
            self.deinit_fn(self, sp) catch {};
        }

        pub fn handle(self: *Self, request: *TIn) !TOut {
            return try self.handle_fn(self.ctx, request);
        }
    };
}

pub fn Behavior(TIn: type, TOut: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,

        handle_fn: *const fn (*anyopaque, *TIn, NextDelegate(TOut)) anyerror!TOut,
        deinit_fn: *const fn (*Self, *di.ServiceProvider) anyerror!void,

        pub fn deinit(self: *Self, sp: *di.ServiceProvider) void {
            self.deinit_fn(self, sp) catch {};
        }

        pub fn handle(self: *Self, request: *TIn, next: NextDelegate(TOut)) !TOut {
            return try self.handle_fn(self.ctx, request, next);
        }
    };
}

pub fn NextDelegate(TOut: type) type {
    return struct {
        ptr: *anyopaque,
        handle_fn: *const fn (*anyopaque) anyerror!TOut,

        pub fn handle(self: *const @This()) !TOut {
            return try self.handle_fn(self.ptr);
        }
    };
}
