const assert = @import("std").testing.expectEqual;

const std = @import("std");
const di = @import("di");

const Generic = di.Generic;

pub fn main() !void {
    var ga = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    const allocator = ga.allocator();

    var cont = di.Container.init(allocator);

    defer cont.deinit();
}
