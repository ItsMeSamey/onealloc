const std = @import("std");
pub const meta = @import("meta.zig");
pub const simple = @import("simple.zig");

/// Options to control the behavior of the `SimpleWrapper` function.
pub const SimpleOptions = simple.ToMergedOptions;

/// A generic wrapper that manages the memory for a merged object.
pub const SimpleWrapper = simple.Wrapper;

test {
  std.testing.refAllDeclsRecursive(@This());
}

