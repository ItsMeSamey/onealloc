const std = @import("std");
const root = @import("root.zig");
const testing = std.testing;

/// Given a function type, get the return type
pub fn FnReturnType(T: type) type {
  return switch (@typeInfo(T)) {
    .@"fn" => |info| info.return_type.?,
    else => @compileError("Expected function type, got " ++ @typeName(T)),
  };
}

pub const SerializationType = enum {
  ///stuffs together like in packed struct, 2 u22's take up 44 bits
  pack,
  /// remove alignment when packing, 2 u22's take up 2 * 24 = 48 bits
  noalign,
  /// do not remove padding, 2 u22's will take up 2 * 32 = 64 bits
  default,
};

/// Shrink the enum type, if return type of this function is used, enum is guaranteed to not be shrunk (it is already shrunk)
/// You can get the original enum value using `@enumFromInt(@typeInfo(OriginalEnumType).@"enum".fields[@intFromEnum(val)])`
pub fn GetShrunkEnumType(T: type, serialization: SerializationType) type {
  const ei = @typeInfo(T).@"enum";
  const min_bits = std.math.log2_int_ceil(usize, ei.fields.len);
  const TagType = std.meta.Int(.unsigned, min_bits);
  if (switch (serialization) {
    .default => @sizeOf(TagType) == @sizeOf(T),
    .noalign => std.math.divCeil(comptime_int, @bitSizeOf(TagType), 8) == std.math.divCeil(comptime_int, @bitSizeOf(T), 8),
    .pack => @bitSizeOf(TagType) == @bitSizeOf(T),
  }) return T;

  var fields: []const std.builtin.Type.EnumField = &.{};
  for (ei.fields, 0..) |f, i| {
    fields = fields ++ [1]std.builtin.Type.EnumField{std.builtin.Type.EnumField{
      .value = i,
      .name = f.name,
    }};
  }

  return @Type(.{
    .@"enum" = .{
      .tag_type = TagType,
      .fields = fields,
      .decls = ei.decls,
      .is_exhaustive = ei.is_exhaustive,
    }
  });
}

// ========================================
//                 Testing                 
// ========================================

test GetShrunkEnumType {
  const LargeTagEnum = enum(u64) {
    a = 0,
    b = 0xffff_ffff_ffff_ffff,
  };
  const ShrunkT = GetShrunkEnumType(LargeTagEnum, .pack);
  try testing.expect(@typeInfo(ShrunkT).@"enum".tag_type == u1);

  const OptimalEnum = enum(u1) {
    a, b,
  };
  const NotShrunkT = GetShrunkEnumType(OptimalEnum, .pack);
  try testing.expect(OptimalEnum == NotShrunkT);
}

