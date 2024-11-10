const std = @import("std");
const Builder = @import("builder.zig").Builder;
const ServiceProvider = @import("service_provider.zig").ServiceProvider;

/// Errors specific to Builder-related functions
const BuilderFnErrors = error{
    PassedNotFn, // "The provided argument is not a function.
    NotSupportedParams, // The function has unsupported parameters.
    InvalidReturnType, // The function has an invalid return type.
};

/// Checks if the type `T` has an `init` method that returns either `T`
/// or an error union with `T` as the payload.
///
/// # Example
/// ```zig
/// const hasInitFn = hasInit(MyType);
/// ```
pub fn hasInit(comptime T: type) bool {
    // Check if `T` has a function named `init`
    if (!std.meta.hasFn(T, "init")) {
        return false;
    }

    // Obtain the return type information of `T.init`
    const return_type = @typeInfo(return_type_of_init_fn(T));
    return return_type_match(return_type, T);
}

/// Helper function to extract the return type of `T.init`
fn return_type_of_init_fn(comptime T: type) type {
    return @typeInfo(@TypeOf(T.init)).Fn.return_type.?;
}

/// Helper function to match the return type against expected patterns
fn return_type_match(return_ti: std.builtin.Type, T: type) bool {
    switch (return_ti) {
        .ErrorUnion => return return_ti.ErrorUnion.payload == T,
        else => return return_ti == @typeInfo(T),
    }
}

/// Retrieves the argument types of the `init` method of type `T`.
/// Returns an array of types representing each parameter.
///
/// # Example
/// ```zig
/// const args = getInitArgs(MyType);
/// ```
pub fn getInitArgs(comptime T: type) []const type {
    const init_fn = T.init;
    const ti = @typeInfo(@TypeOf(init_fn)).Fn;

    comptime var fn_args: [ti.params.len]type = undefined;

    inline for (ti.params, 0..) |p, i| {
        fn_args[i] = p.type.?;
    }

    return &fn_args;
}

/// Dereferences a pointer type `T` and returns its child type.
/// If `T` is not a pointer, it returns `T` itself.
///
/// # Example
/// ```zig
/// const child = deref(*MyType); // Returns MyType
/// const same = deref(MyType);   // Returns MyType
/// ```
pub fn deref(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Pointer => @typeInfo(T).Pointer.child,
        else => T,
    };
}

/// Retrieves the return type of a function `t`.
/// If the return type is an error union, it extracts and returns the payload type.
///
/// # Example
/// ```zig
/// const retType = getReturnType(fn() MyType);
/// ```
pub fn getReturnType(comptime t: anytype) type {
    const ti = @typeInfo(@TypeOf(t));

    if (ti != .Fn) {
        @compileError("Argument must be a function, but got: " ++ @typeName(@TypeOf(t)));
    }

    const return_type = ti.Fn.return_type.?;
    const return_ti = @typeInfo(return_type);

    return if (return_ti == .ErrorUnion) return_ti.ErrorUnion.payload else return_type;
}

/// Retrieves a `Builder` instance for type `t` using function `f`.
/// The function `f` must conform to specific signature constraints.
///
/// # Errors
/// - `BuilderFnErrors.PassedNotFn`: If `f` is not a function.
/// - `BuilderFnErrors.NotSupportedParams`: If `f` has unsupported parameters.
/// - `BuilderFnErrors.InvalidReturnType`: If `f` has an invalid return type.
///
/// # Example
/// ```zig
/// const builder = getBuilder(MyType, initFn) catch |err| {
///     // Handle error
/// };
/// ```
pub fn getBuilder(comptime t: type, comptime f: anytype) !Builder(t) {
    const fi = @typeInfo(@TypeOf(f));

    // Ensure `f` is a function
    if (fi != .Fn) {
        return BuilderFnErrors.PassedNotFn;
    }

    // Check parameter constraints
    switch (fi.Fn.params.len) {
        0 => {},
        1 => {
            const param_type = fi.Fn.params[0].type.?;
            if (param_type != *ServiceProvider) {
                return BuilderFnErrors.NotSupportedParams;
            }
        },
        else => return BuilderFnErrors.NotSupportedParams,
    }

    // Determine how to construct the Builder based on the return type
    const return_type = fi.Fn.return_type.?;
    const return_ti = @typeInfo(return_type);

    const fnWrapper = struct {
        pub fn wrapper(ctx: *anyopaque) !t {
            const sp: *ServiceProvider = @ptrCast(@alignCast(ctx));
            return switch (fi.Fn.params.len) {
                0 => f(),
                1 => f(sp),
                else => {},
            };
        }

        pub fn wrapperNoError(ctx: *anyopaque) t {
            const sp: *ServiceProvider = @ptrCast(@alignCast(ctx));
            return switch (fi.Fn.params.len) {
                0 => f(),
                1 => f(sp),
                else => {},
            };
        }
    };

    if (return_ti == .ErrorUnion) {
        return Builder(t).fromFn(fnWrapper.wrapper);
    } else if (return_type == t) {
        return Builder(t).fromFnWithNoError(fnWrapper.wrapperNoError);
    } else {
        return BuilderFnErrors.InvalidReturnType;
    }
}

/// Additional Utility: Checks if a type has a specific function with the expected signature.
///
/// # Example
/// ```zig
/// const hasStart = hasFnSignature(MyType, "start", fn() !void);
/// ```
pub fn hasFnSignature(comptime T: type, comptime fnName: []const u8, comptime fnType: type) bool {
    if (!std.meta.hasFn(T, fnName)) {
        return false;
    }

    const fn_found = T.fnName;
    return @TypeOf(fn_found) == fnType;
}

/// Additional Utility: Retrieves the type of a specific function from a type.
///
/// # Example
/// ```zig
/// const startFnType = getFnType(MyType, "start") orelse return;
/// ```
pub fn getFnType(comptime T: type, comptime fnName: []const u8) ?type {
    if (!std.meta.hasFn(T, fnName)) {
        return null;
    }

    return @field(T, fnName);
}
