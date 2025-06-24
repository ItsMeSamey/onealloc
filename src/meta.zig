const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const testing = std.testing;

/// This is used to recognize if types were returned by ToMerged.
/// This is done by assigning `pub const Signature = MergedSignature;` inside an opaque
pub const MergedSignature = struct {
  /// The underlying type that was transformed
  T: type,
  /// The type of dynamic data that will be written to by the child
  D: type,
  /// Static size (in bits if pack, in bytes if default/noalign)
  static_size: comptime_int,
  /// Always .@"1" unless .default is used
  alignment: std.mem.Alignment,
};

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

/// Returns true is parent contains child exactly 1 inderictions away
/// i.e. exactly one pointer dereference (/ slice access) is needed to go from parent to child
///
/// this may return `true` yet ContainsT may return false and vice versa
pub fn ContainsIndirectedT(parent: type, child: type) bool {
  if (parent == child) return false;
  switch (@typeInfo(parent)) {
    .type, .void, .bool, .noreturn, .int, .float, .comptime_float, .comptime_int, .undefined, .null,
    .@"enum", .error_set, .@"fn", .@"opaque", .frame, .@"anyframe", .enum_literal => {},
    .pointer => |pi| return ContainsT(pi.child, child),
    .array => |ai| return ContainsIndirectedT(ai.child, child),
    .@"struct" => |si| inline for (si.fields) |f| if (ContainsIndirectedT(f.type, child)) return true,
    .optional => |oi| return ContainsIndirectedT(oi.child, child),
    .error_union => |ei| return ContainsIndirectedT(ei.error_set, child) or ContainsIndirectedT(ei.payload, child),
    .@"union" => |ui| inline for (ui.fields) |f| if (ContainsIndirectedT(f.type, child)) return true,
    .vector => |vi| return ContainsIndirectedT(vi.child, child),
  }
  return false;
}

/// Returns true if parent and child are equivalent
/// i.e. they are both equal or parent contains child 0 indirections away
///
/// 0 inderictions away means no pointer dereference (/ slice access) is needed to go from parent to child
pub fn ContainsT(parent: type, child: type) bool {
  if (parent == child) return true;
  switch (@typeInfo(parent)) {
    .type, .void, .bool, .noreturn, .int, .float, .comptime_float, .comptime_int, .undefined, .null,
    .@"enum", .error_set, .@"fn", .@"opaque", .frame, .@"anyframe", .enum_literal => {},
    .pointer => {}, // Needs dereference
    .array => |ai| return ContainsT(ai.child, child),
    .@"struct" => |si| inline for (si.fields) |f| if (ContainsT(f.type, child)) return true,
    .optional => |oi| return ContainsT(oi.child, child),
    .error_union => |ei| return ContainsT(ei.error_set, child) or ContainsT(ei.payload, child),
    .@"union" => |ui| inline for (ui.fields) |f| if (ContainsT(f.type, child)) return true,
    .vector => |vi| return ContainsT(vi.child, child),
  }
  return false;
}

/// We dont need the length of the allocations but they are useful for debugging
/// This is a helper type designed to help with catching errors
pub fn Bytes(comptime _alignment: std.mem.Alignment) type {
  return struct {
    ptr: [*]align(alignment) u8,
    /// We only use this in debug mode
    _len: if (builtin.mode == .Debug) usize else void,

    pub const alignment = _alignment.toByteUnits();

    pub fn init(v: []align(alignment) u8) @This() {
      return .{ .ptr = v.ptr, ._len = if (builtin.mode == .Debug) v.len else {} };
    }

    pub fn initAssert(v: []u8) @This() {
      std.debug.assert(std.mem.isAligned(@intFromPtr(v.ptr), _alignment.toByteUnits()));
      return .{ .ptr = @alignCast(v.ptr), ._len = if (builtin.mode == .Debug) v.len else {} };
    }

    pub fn from(self: @This(), index: usize) Bytes(.@"1") {
      if (builtin.mode == .Debug and index > self._len) {
        std.debug.panic("Index {d} is out of bounds for slice of length {d}\n", .{ index, self._len });
      }
      return .{ .ptr = self.ptr + index, ._len = if (builtin.mode == .Debug) self._len - index else {} };
    }

    pub fn till(self: @This(), index: usize) @This() {
      if (builtin.mode == .Debug and index > self._len) {
        std.debug.panic("Index {d} is out of bounds for slice of length {d}\n", .{ index, self._len });
      }
      return .{ .ptr = self.ptr, ._len = if (builtin.mode == .Debug) index else {} };
    }

    pub fn range(self: @This(), start_index: usize, end_index: usize) @This() {
      return self.from(start_index).till(end_index);
    }

    pub fn slice(self: @This(), end_index: usize) []align(alignment) u8 {
      // .till is used for bounds checking in debug mode, otherwise its just a no-op
      return self.till(end_index).ptr[0..end_index];
    }

    pub fn assertAligned(self: @This(), comptime new_alignment: std.mem.Alignment) if (new_alignment == _alignment) @This() else Bytes(new_alignment) {
      std.debug.assert(std.mem.isAligned(@intFromPtr(self.ptr), new_alignment.toByteUnits()));
      return .{ .ptr = @alignCast(self.ptr), ._len = self._len };
    }

    pub fn alignForward(self: @This(), comptime new_alignment: std.mem.Alignment) if (new_alignment == _alignment) @This() else Bytes(new_alignment) {
      const aligned_ptr = std.mem.alignForward(usize, @intFromPtr(self.ptr), new_alignment.toByteUnits());
      return .{
        .ptr = @ptrFromInt(aligned_ptr),
        ._len = self._len - (aligned_ptr - @intFromPtr(self.ptr)) // Underflow => user error
      };
    }
  };
}

pub fn GetContext(Options: type) type {
  return struct {
    /// What should be the alignment of the type being merged
    align_hint: ?std.mem.Alignment,
    /// The types that have been seen so far
    seen_types: []const type,
    /// The types that have been merged so far (each corresponding to a seen type)
    result_types: []const type,
    /// If we have seen a type passed to .see before, this will give it's index
    seen_recursive: comptime_int,
    /// The options used by the merging function
    options: Options,
    /// The function that will be used to merge a type
    merge: fn (context: @This()) type,

    pub fn init(options: Options, merge_fn: fn (context: @This()) type) type {
      const self = @This(){
        .align_hint = null,
        .seen_types = &.{},
        .result_types = &.{},
        .options = options,
        .seen_recursive = -1,
        .merge = merge_fn,
      };

      return self.merge(self);
    }

    pub fn realign(self: @This(), align_hint: ?std.mem.Alignment) @This() {
      var retval = self;
      retval.align_hint = align_hint;
      return retval;
    }

    pub fn see(self: @This(), new_T: type, Result: type) @This() { // Yes we can do this, Zig is f****ing awesome
      const have_seen = comptime blk: {
        for (self.seen_types, 0..) |t, i| if (new_T == t) break :blk i;
        break :blk -1;
      };

      if (have_seen != -1 and !self.options.allow_recursive_rereferencing) {
        @compileError("Recursive type " ++ @typeName(new_T) ++ " is not allowed to be referenced by another type");
      }

      var retval = self;
      retval.seen_types = self.seen_types ++ [1]type{new_T};
      retval.result_types = self.result_types ++ [1]type{Result};
      retval.seen_recursive = have_seen;
      return retval;
    }

    pub fn reop(self: @This(), options: Options) @This() {
      var retval = self;
      retval.options = options;
      return retval;
    }

    pub fn T(self: @This(), comptime new_T: type) @This() {
      var retval = self;
      retval.options.T = new_T;
      return retval;
    }
  };
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

