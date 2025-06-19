const std = @import("std");
const root = @import("root.zig");

/// Given a function type, get the return type
pub fn FnReturnType(T: type) type {
  return switch (@typeInfo(T)) {
    .@"fn" => |info| info.return_type.?,
    else => @compileError("Expected function type, got " ++ @typeName(T)),
  };
}

/// Shrink the enum type, if return type of this function is used, enum is guaranteed to not be shrunk (it is already shrunk)
/// You can get the original enum value using `@enumFromInt(@typeInfo(OriginalEnumType).@"enum".fields[@intFromEnum(val)])`
pub fn GetShrunkEnumType(T: type, serialization: root.ToSerializableOptions.SerializationOptions) type {
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

pub fn WrapSuper(T: type, options: root.ToSerializableOptions) type {
  std.debug.assert(@typeInfo(T) == .@"opaque");
  return struct {
    _allocation: []align(T.Signature.alignment.toByteUnits()) T,

    pub const Underlying = T;
    const StaticSize = switch (options.serialization) {
      .default, .noalign => T.Signature.static_size,
      .pack => std.math.divCeil(comptime_int, T.Signature.static_size, 8),
    };

    pub fn init(allocator: std.mem.Allocator, val: T) !@This() {
      const allocation_size: usize = StaticSize + if (std.meta.hasFn(T, "getDynamicSize")) T.getDynamicSize(&val) else 0;
      const allocation = try allocator.alignedAlloc(u8, T.Signature.alignment, allocation_size);
      return @This(){ ._allocation = allocation };
    }

    pub fn clone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
      return .{ ._allocation = try allocator.dupe(u8, self._allocation) };
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
      allocator.free(self._allocation);
      self._allocation = undefined;
    }

    pub fn sub(self: @This()) WrapSub(T, options) {
      return .{ ._static = self._allocation[0..StaticSize], ._offset = 0, ._dynamic = self._allocation[StaticSize..] };
    }
  };
}

pub fn WrapSub(T: type, options: root.ToSerializableOptions) type {
  std.debug.assert(@typeInfo(T) == .@"opaque");
  return struct {
    _static: []u8,
    _dynamic: []u8,
    _offset: if (options.serialization == .pack) u3 else u0 = 0,

    pub const Underlying = T;
    const StaticSize = switch (options.serialization) {
      .default, .noalign => T.Signature.static_size,
      .pack => std.math.divCeil(comptime_int, T.Signature.static_size, 8),
    };

    pub fn init(static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) @This() {
      return .{ ._static = static, ._offset = offset, ._dynamic = dynamic };
    }

    const GetFnInfo = @typeInfo(@TypeOf(Underlying.GG.get)).@"fn";
    const GetReturnType = GetFnInfo.return_type.?;
    const GetParam1 = if (GetFnInfo.params.len == 1) void else GetFnInfo.params[1].type.?;

    fn _get_comptime(self: @This(), comptime arg: GetParam1) GetReturnType {
      return T.read(self._static, self._offset, self._dynamic).get(arg);
    }
    fn _get_runtime(self: @This(), arg: GetParam1) GetReturnType {
      return T.read(self._static, self._offset, self._dynamic).get(arg);
    }
    fn _get(self: @This()) GetReturnType {
      return T.read(self._static, self._offset, self._dynamic).get();
    }

    /// This function has an integral second argument if the underlying type is an array or a slice
    /// This function has a comptime []const u8 as second argument if the underlying type is a struct
    pub const get = if (GetParam1 == void) _get else if (GetParam1 == []const u8) _get_comptime else _get_runtime;

    const GetReturnWrapped = switch (@typeInfo(GetReturnType)) {
      .error_union => |ei| ei.error_set!WrapSub(ei.payload, options),
      .optional => |oi| ?WrapSub(oi.child, options),
      .@"opaque" => WrapSub(GetReturnType, options),
      else => GetReturnType,
    };
    fn _sub_comptime(self: @This(), comptime arg: GetParam1) GetReturnWrapped {
      return get(self, arg).sub();
    }
    fn _sub_runtime(self: @This(), arg: GetParam1) GetReturnWrapped {
      return get(self, arg).sub();
    }
    fn _sub(self: @This()) GetReturnWrapped {
      return get(self).sub();
    }

    /// This function has an integral second argument if the underlying type is an array or a slice
    /// This function has a comptime []const u8 as second argument if the underlying type is a struct
    /// return_type of this function is another wrapped type, unlike get
    pub const sub = if (GetParam1 == void) _sub else if (GetParam1 == []const u8) _sub_comptime else _sub_runtime;

    const SetFnInfo = @typeInfo(@TypeOf(Underlying.GG.set)).@"fn";
    pub fn set(self: @This(), val: SetFnInfo.params[1].type.?) void {
      T.read(self._static, self._offset, self._dynamic).set(val);
    }

    pub fn go(self: @This(), args: anytype) GoIndexReturnType(@TypeOf(args), 0) {
      return self.goIndex(args, 0);
    }

    pub fn goIndex(self: @This(), args: anytype, comptime index: comptime_int) GoIndexReturnType(@TypeOf(args), index) {
      const field_val = @field(args, std.fmt.comptimePrint("{d}", .{index}));
      const is_void = @TypeOf(field_val) == void;
      if (@typeInfo(@TypeOf(args)).@"struct".fields.len == index + 1) return if (is_void) self.get() else self.get(field_val);
      const sub_val = if (is_void) self.sub() else self.sub(field_val);
      return switch (@typeInfo(@TypeOf(sub_val))) {
        .error_union => try sub_val,
        .optional => sub_val.?,
        .@"opaque" => sub_val,
        else => unreachable,
      }.goIndex(args, index + 1);
    }

    fn GoIndexReturnType(comptime Args: type, comptime index: comptime_int) type {
      if (@typeInfo(Args).@"struct".fields.len == index + 1) return FnReturnType(get);
      return GoIndexReturnType(Args, index + 1);
    }
  };
}

test {
  std.testing.refAllDeclsRecursive(@This());
}

