const std = @import("std");
const builtin = @import("builtin");
const meta = @import("meta.zig");
const simple = @import("simple.zig");

const Bytes = meta.Bytes;
const BytesLen = meta.BytesLen;
const FnReturnType = meta.FnReturnType;
const MergedSignature = simple.MergedSignature;
pub const Context = meta.GetContext(ToMergedOptions);

/// Options to control how merging of a type is performed
pub const ToMergedOptions = struct {
  /// The type that is to be merged
  T: type,
  /// Int type used for lengths
  len_int: type = u32,
  /// Int type used for offsets
  offset_int: type = u32,
  /// Recurse into structs and unions
  recurse: bool = true,
  /// Whether to dereference pointers or use them by value
  dereference: bool = true,
  /// What is the maximum number of expansion of slices that can be done
  /// for example in a recursive structure or nested slices
  ///
  /// eg.
  /// If we have [][]u8, and deslice = 1, we will write pointer+size of all the strings in this slice
  /// If we have [][]u8, and deslice = 2, we will write all the characters in this block
  deslice: comptime_int = 1024,
  /// Error if deslice = 0
  error_on_0_deslice: bool = true,
  /// Allow for recursive re-referencing, eg. (A has ?*A), (A has ?*B, B has ?*A), etc.
  /// When this is false and the type is recursive, compilation will error
  allow_recursive_rereferencing: bool = false,
  /// Serialize unknown pointers (C / Many / opaque pointers) as usize. Make data non-portable
  serialize_unknown_pointer_as_usize: bool = false,
};

/// We take in a type and just use its byte representation to store into bits.
/// Zero-sized types ares supported and take up no space at all
pub fn GetDirectMergedT(context: Context) type {
  const T = context.options.T;
  return opaque {
    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(.@"1"),
      .static_size = @sizeOf(T),
      .alignment = context.align_hint orelse .fromByteUnits(@alignOf(T)),
    };

    pub fn write(val: *const T, static: S, _: Signature.D) usize {
      if (@bitSizeOf(T) != 0) @memcpy(static.slice(Signature.static_size), std.mem.asBytes(val));
      return 0;
    }

    pub fn read(static: S, _: Signature.D) *T {
      return @ptrCast(static.ptr);
    }
  };
}

/// Convert a supplid pointer type to writable opaque
pub fn GetPointerMergedT(context: Context) type {
  const T = context.options.T;
  if (!context.options.dereference) return GetDirectMergedT(context);

  const is_optional = @typeInfo(T) == .optional;
  const pi = @typeInfo(if (is_optional) @typeInfo(T).optional.child else T).pointer;
  std.debug.assert(pi.size == .one);

  if (@sizeOf(pi.child) == 0) return opaque {
    // We need a tag for zero sized types
    const Existence = GetDirectMergedT(context.T(if (is_optional) u1 else void));
    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(.@"1"),
      .static_size = if (is_optional) 1 else 0,
      .alignment = .@"1",
    };

    pub fn write(val: *const T, static: S, _dynamic: Signature.D) usize {
      if (is_optional) {
        if (val.* == null) {
          std.debug.assert(0 == Existence.write(&@as(u1, 0), static, undefined));
        } else {
          std.debug.assert(0 == Existence.write(&@as(u1, 1), static, undefined));
        }
      }
      return 0;
    }

    const Self = @This();
    pub const GS = struct {
      exists: if (is_optional) *u1 else void,

      pub const Parent = Self;
      pub fn get(self: GS) if (is_optional) ?pi.child else pi.child {
        if (is_optional and self.exists.* == 0) return null;
        return undefined;
      }

      pub fn set(self: GS, val: if (is_optional) ?*pi.child else *pi.child) void {
        if (!is_optional) return;
        if (val == null) {
          self.exists.* = 0;
        } else {
          self.exists.* = 1;
        }
      }
    };

    pub fn read(static: S, _dynamic: Signature.D) GS {
      return .{ .exists = if (is_optional) @as(*u1, @ptrCast(static.ptr)) else undefined };
    }
  };

  const Retval = opaque {
    const next_context = context.realign(.fromByteUnits(pi.alignment)).see(T, @This());
    const Child = context.merge(next_context.T(pi.child));

    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = (if (is_optional or Child.Signature.D.need_len) BytesLen else Bytes)(if (is_optional) .@"1" else .fromByteUnits(pi.alignment)),
      .static_size = Existence.Signature.static_size,
      .alignment = .@"1",
    };

    pub fn write(val: *const T, static: S, _dynamic: Signature.D) usize {
      if (is_optional and val.* == null) return 0;

      const dynamic = if (is_optional) _dynamic.alignForward(Child.Signature.alignment) else _dynamic;
      const child_static = dynamic.till(Child.Signature.static_size);
      // Align 1 if child is static, so no issue here, static and dynamic children an be written by same logic
      const child_dynamic = dynamic.from(Child.Signature.static_size).alignForward(.fromByteUnits(Child.Signature.D.alignment));
      const written = Child.write(if (is_optional) val.*.? else val.*, child_static, child_dynamic);

      if (std.meta.hasFn(Child, "getDynamicSize") and builtin.mode == .Debug) {
        std.debug.assert(written == Child.getDynamicSize(if (is_optional) val.*.? else val.*, @intFromPtr(child_dynamic.ptr)) - @intFromPtr(child_dynamic.ptr));
      } else {
        std.debug.assert(0 == written);
      }

      return written + @intFromPtr(child_dynamic.ptr) - @intFromPtr(_dynamic.ptr);
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      std.debug.assert(std.mem.isAligned(size, Signature.D.alignment));
      var new_size = size;

      if (is_optional) {
        if (val.* == null) return new_size;
        new_size = std.mem.alignForward(usize, new_size, Child.Signature.alignment.toByteUnits());
      }

      new_size += Child.Signature.static_size;
      if (std.meta.hasFn(Child, "getDynamicSize")) {
        new_size = std.mem.alignForward(usize, new_size, Child.Signature.D.alignment);
        new_size = Child.getDynamicSize(if (is_optional) val.*.? else val.*, new_size);
      }

      return new_size;
    }

    const Self = @This();
    pub const GS = struct {
      dynamic: Signature.D,

      pub const Parent = Self;
      const GetRT = FnReturnType(Child.read);
      pub fn get(self: GS) if (is_optional) ?GetRT else GetRT {
        if (is_optional and self.dynamic.len == 0) return null;

        const dynamic = if (is_optional) self.dynamic.alignForward(Child.Signature.alignment) else self.dynamic;
        const child_static = dynamic.till(Child.Signature.static_size);
        const child_dynamic = dynamic.from(Child.Signature.static_size).alignForward(.fromByteUnits(Child.Signature.D.alignment));

        return Child.read(child_static, child_dynamic);
      }

      pub fn set(self: GS, val: *const T) void {
        const child = if (is_optional) self.get().? // You cant set a null value
          else self.get();
        child.set(if (is_optional) val.*.? // You cant make a non-null value null
          else val.*);
      }
    };

    pub fn read(_: S, dynamic: Signature.D) GS {
      return .{ .dynamic = dynamic };
    }
  };

  if (Retval.next_context.seen_recursive >= 0) return context.result_types[Retval.next_context.seen_recursive];
  return Retval;
}

pub fn GetSliceMergedT(context: Context) type {
  const T = context.options.T;
  if (context.options.deslice == 0) {
    if (context.options.error_on_0_deslice) {
      @compileError("Cannot deslice type " ++ @typeName(T) ++ " any further as options.deslice is 0");
    }
    return GetDirectMergedT(context);
  }

  const is_optional = @typeInfo(T) == .optional;
  const pi = @typeInfo(if (is_optional) @typeInfo(T).optional.child else T).pointer;
  std.debug.assert(pi.size == .slice);

  const Len = GetDirectMergedT(context);
  if (@sizeOf(pi.child) == 0) return opaque {
    pub const Signature = Len.Signature;

    fn gl(val: *const T) context.options.len_int {
      const len = if (is_optional) if (val.*) |v| v.len else std.math.maxInt(context.options.len_int) else val.*.len;
      return @intCast(len);
    }

    pub fn write(val: *const T, static: S, _: Signature.D) usize {
      const len = gl(val);
      std.debug.assert(0 == Len.write(&len, static, undefined));
      return 0;
    }

    const Self = @This();
    pub const GS = struct {
      len: *context.options.len_int,

      pub const Parent = Self;
      pub fn get(self: GS) context.options.len_int {
        return self.len.*;
      }

      pub fn set(self: GS, val: *const T) void {
        self.len.* = gl(val);
      }
    };

    pub fn read(static: S, _: Signature.D) GS {
      return .{ .len = @ptrCast(static.ptr) };
    }
  };

  const Index = GetDirectMergedT(context.T(context.options.offset_int));
  const Retval = opaque {
    const next_context = context.realign(.fromByteUnits(pi.alignment)).see(T, @This());
    const next_options = blk: {
      var retval = context.options;
      if (next_context.seen_recursive == -1) retval.deslice -= 1;
      break :blk retval;
    };

    const Child = context.merge(next_context.reop(next_options).T(pi.child));
    const SubStatic = !std.meta.hasFn(Child, "getDynamicSize");
    const IndexBeforeStatic = Len.Signature.alignment.toByteUnits() >= Child.Signature.alignment.toByteUnits();

    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = (if (Child.Signature.D.need_len) BytesLen else Bytes)(.@"1"),
      .static_size = Len.Signature.static_size,
      .alignment = Len.Signature.alignment,
    };

    fn gl(val: *const T) context.options.len_int {
      const len = if (is_optional) if (val.*) |v| v.len else std.math.maxInt(context.options.len_int) else val.*.len;
      return @intCast(len);
    }

    fn getStuff(dynamic: Signature.D, len: context.options.len_int) struct {
      @"0": Bytes(Len.Signature.alignment),
      @"1": Bytes(Child.Signature.alignment),
      @"2": Bytes(Child.Signature.D.alignment),
    } {
      if (len == 1) return .{
        .@"0" = undefined,
        .@"1" = dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment)).till(Child.Signature.static_size * len),
        .@"2" = dynamic.from(Child.Signature.static_size * len).alignForward(.fromByteUnits(Child.Signature.D.alignment)),
      };
      if (IndexBeforeStatic) {
        const index_aligned = dynamic.alignForward(.fromByteUnits(Len.Signature.alignment));
        return .{
          .@"0" = index_aligned.till(Len.Signature.static_size * (len - 1)),
          .@"1" = index_aligned.from(Len.Signature.static_size * (len - 1)).assertAligned(.fromByteUnits(Child.Signature.D.alignment)).till(Child.Signature.static_size * len),
          .@"2" = index_aligned.from(Len.Signature.static_size * (len - 1) + Child.Signature.static_size * len).assertAligned(.fromByteUnits(Child.Signature.D.alignment)),
        };
      } else {
        const static_aligned = dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        return .{
          .@"0" = dynamic.from(Child.Signature.static_size * len).assertAligned(.fromByteUnits(Len.Signature.alignment)).till(Len.Signature.static_size * (len - 1)),
          .@"1" = static_aligned.till(Child.Signature.static_size * len),
          .@"2" = static_aligned.from(Len.Signature.static_size * (len - 1) + Child.Signature.static_size * len).assertAligned(.fromByteUnits(Child.Signature.D.alignment)),
        };
      }
    }

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      const len = gl(val);
      std.debug.assert(0 == Len.write(&len, static, undefined));
      if ((is_optional and val.* == null) or len == 0) return 0;

      const index, var child_static, var child_dynamic = getStuff(dynamic, len);

      // First iteration
      const written = Child.write(item, child_static, if (SubStatic) undefined else child_dynamic);
      if (!SubStatic and builtin.mode == .Debug) {
        std.debug.assert(written == Child.getDynamicSize(item, @intFromPtr(child_dynamic.ptr) - @intFromPtr(child_dynamic.ptr)));
      }
      child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);
      if (!SubStatic) child_dynamic = child_dynamic.from(written);

      for (1..len) |i| {
        const item = &val.*[i];

        if (!SubStatic) {
          
          child_dynamic = child_dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        }
        const written = Child.write(item, child_static, if (SubStatic) undefined else child_dynamic);

        if (!SubStatic and builtin.mode == .Debug) {
          std.debug.assert(written == Child.getDynamicSize(item, @intFromPtr(child_dynamic.ptr) - @intFromPtr(child_dynamic.ptr)));
        }

        child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);
        if (!SubStatic) child_dynamic = child_dynamic.from(written);
      }

      return @intFromPtr(child_dynamic.ptr) - @intFromPtr(_dynamic.ptr);
    }

    pub const getDynamicSize = if (Child.Signature.static_size == 0) void else _getDynamicSize;
    fn _getDynamicSize(val: *const T, size: usize) usize {
      std.debug.assert(std.mem.isAligned(size, Signature.D.alignment));
      if (is_optional and val.* == null) return size;
      const slice = if (is_optional) val.*.? else val.*;
      var new_size = size + Child.Signature.static_size * slice.len;

      if (!SubStatic) {
        for (slice) |*item| {
          new_size = std.mem.alignForward(usize, new_size, Child.Signature.D.alignment);
          new_size = Child.getDynamicSize(item, new_size);
        }
      }

      return new_size;
    }

    pub fn repointer(static: S, _dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(_dynamic.ptr), Signature.D.alignment));
      const dynamic = if (is_optional) _dynamic.alignForward(Child.Signature.alignment) else _dynamic;

      const header: *T = @ptrCast(static.ptr);
      if (is_optional and header.* == null) return 0;
      header.*.ptr = @ptrCast(dynamic.ptr);
      const len = header.*.len;

      if (Child.Signature.static_size == 0 or len == 0) return 0;
      if (SubStatic) return Child.Signature.static_size * len;

      var child_static = dynamic.till(Child.Signature.static_size * len);
      var child_dynamic = dynamic.from(Child.Signature.static_size * len).alignForward(.fromByteUnits(Child.Signature.D.alignment));

      for (0..len) |i| {
        child_dynamic = child_dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.repointer(child_static, child_dynamic);

        if (builtin.mode == .Debug) {
          std.debug.assert(written == Child.getDynamicSize(&header.*[i], @intFromPtr(child_dynamic.ptr) - @intFromPtr(child_dynamic.ptr)));
        }

        child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);
        child_dynamic = child_dynamic.from(written);
      }

      return @intFromPtr(child_dynamic.ptr) - @intFromPtr(_dynamic.ptr);
    }
  };

  if (Retval.next_context.seen_recursive >= 0) return context.result_types[Retval.next_context.seen_recursive];
  return Retval;
}

pub fn ToMergedT(context: Context) type {
  const T = context.options.T;
  @setEvalBranchQuota(1000_000);
  return switch (@typeInfo(T)) {
    .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal => {
      @compileError("Type '" ++ @tagName(std.meta.activeTag(@typeInfo(T))) ++ "' is not mergeable\n");
    },
    .void, .bool, .int, .float, .vector, .error_set, .null => GetDirectMergedT(context),
    .pointer => |pi| switch (pi.size) {
      .many, .c => if (context.options.serialize_unknown_pointer_as_usize) GetDirectMergedT(context) else {
        @compileError(@tagName(pi.size) ++ " pointer cannot be serialized for type " ++ @typeName(T) ++ ", consider setting serialize_many_pointer_as_usize to true\n");
      },
      .one => switch (@typeInfo(pi.child)) {
        .@"opaque" => if (@hasDecl(pi.child, "Signature") and @TypeOf(pi.child.Signature) == MergedSignature) pi.child
          else if (context.options.error_on_unsafe_conversion) GetDirectMergedT(context) else {
          @compileError("A non-mergeable opaque " ++ @typeName(pi.child) ++ " was provided to `ToMergedT`\n");
        },
        else => GetPointerMergedT(context),
      },
      .slice => GetSliceMergedT(context),
    },
    .array => GetArrayMergedT(context),
    .@"struct" => GetStructMergedT(context),
    .optional => |oi| switch (@typeInfo(oi.child)) {
      .pointer => |pi| switch (pi.size) {
        .many, .c => if (context.options.serialize_unknown_pointer_as_usize) GetDirectMergedT(context) else {
          @compileError(@tagName(pi.size) ++ " pointer cannot be serialized for type " ++ @typeName(T) ++ ", consider setting serialize_many_pointer_as_usize to true\n");
        },
        .one => GetPointerMergedT(context),
        .slice => GetSliceMergedT(context),
      },
      else => GetOptionalMergedT(context),
    },
    .error_union => GetErrorUnionMergedT(context),
    .@"enum" => GetDirectMergedT(context),
    .@"union" => GetUnionMergedT(context),
    .@"opaque" => if (@hasDecl(T, "Signature") and @TypeOf(T.Signature) == MergedSignature) T else {
      @compileError("A non-mergeable opaque " ++ @typeName(T) ++ " was provided to `ToMergedT`\n");
    },
  };
}

