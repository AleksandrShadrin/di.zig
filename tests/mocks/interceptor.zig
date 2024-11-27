const std = @import("std");

pub const InterceptorErrors = error{ StatementDenied, StatementConfirmed, NoStatement };

pub const Interceptor = struct {
    map: std.StringHashMap(bool),

    pub fn init(a: std.mem.Allocator) Interceptor {
        return Interceptor{
            .map = std.StringHashMap(bool).init(a),
        };
    }

    pub fn deinit(self: *Interceptor) void {
        self.map.deinit();
    }

    pub fn confirm(self: *Interceptor, statement: []const u8) !void {
        try self.map.put(statement, true);
    }

    pub fn deny(self: *Interceptor, statement: []const u8) !void {
        try self.map.put(statement, false);
    }

    pub fn assert_confirmed(self: *Interceptor, statement: []const u8) !void {
        const statement_state = self.map.get(statement) orelse return InterceptorErrors.NoStatement;

        if (!statement_state) return InterceptorErrors.StatementDenied;
    }

    pub fn assert_denied(self: *Interceptor, statement: []const u8) !void {
        const statement_state = self.map.get(statement) orelse return InterceptorErrors.NoStatement;

        if (statement_state) return InterceptorErrors.StatementConfirmed;
    }
};
