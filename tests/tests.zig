const std = @import("std");
const container_tests = @import("container_test.zig");
const service_provider_tests = @import("service_provider_test.zig");

test {
    std.testing.refAllDecls(container_tests);
    std.testing.refAllDecls(service_provider_tests);
}
