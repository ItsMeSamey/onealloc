const std = @import("std");

/// Given a function type, get the return type
pub fn FnReturnType(T: type) type {
  return switch (@typeInfo(T)) {
    .@"fn" => |info| info.return_type.?,
    else => @compileError("Expected function type, got " ++ @typeName(T)),
  };
}

