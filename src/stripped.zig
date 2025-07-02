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

/// Special case for zero sized types.
/// We need to store existence tag as dynamic data size is always 0
pub fn GetZstPointerMergedT(context: Context) type {
  const T = context.options.T;
  if (!context.options.dereference) return GetDirectMergedT(context);

  const is_optional = @typeInfo(T) == .optional;
  const pi = @typeInfo(if (is_optional) @typeInfo(T).optional.child else T).pointer;
  std.debug.assert(pi.size == .one);
  std.debug.assert(@sizeOf(pi.child) == 0);

  const Existence = GetDirectMergedT(context.T(if (is_optional) u1 else void));

  return opaque {
    // We need a tag for zero sized types
    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(.@"1"),
      .static_size = if (is_optional) 1 else 0,
      .alignment = .@"1",
    };

    pub fn write(val: *const T, static: S, _: Signature.D) usize {
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
      _exists: if (is_optional) *u1 else void,

      pub const Parent = Self;
      pub fn get(self: GS) if (is_optional) ?pi.child else pi.child {
        if (is_optional and self._exists.* == 0) return null;
        return undefined;
      }

      pub fn set(self: GS, val: if (is_optional) ?*pi.child else *pi.child) void {
        if (!is_optional) return;
        if (val == null) {
          self._exists.* = 0;
        } else {
          self._exists.* = 1;
        }
      }
    };

    pub fn read(static: S, _: Signature.D) GS {
      return .{ .exists = if (is_optional) @as(*u1, @ptrCast(static.ptr)) else undefined };
    }
  };
}

/// Convert a supplid pointer type to writable opaque.
/// Existence in case of optional inferred from dynamic data size, so no tag needed
pub fn GetPointerMergedT(context: Context) type {
  const T = context.options.T;
  if (!context.options.dereference) return GetDirectMergedT(context);

  const is_optional = @typeInfo(T) == .optional;
  const pi = @typeInfo(if (is_optional) @typeInfo(T).optional.child else T).pointer;
  std.debug.assert(pi.size == .one);

  if (@sizeOf(pi.child) == 0) return GetZstPointerMergedT(context);

  const Retval = opaque {
    const next_context = context.realign(.fromByteUnits(pi.alignment)).see(T, @This());
    const Child = next_context.T(pi.child).merge();
    const SubStatic = !std.meta.hasFn(Child, "getDynamicSize");

    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = (if (is_optional or Child.Signature.D.need_len) BytesLen else Bytes)(if (is_optional) .@"1" else .fromByteUnits(pi.alignment)),
      .static_size = 0,
      .alignment = .@"1",
    };

    pub fn write(val: *const T, _: S, _dynamic: Signature.D) usize {
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
      if (!SubStatic) {
        new_size = std.mem.alignForward(usize, new_size, Child.Signature.D.alignment);
        new_size = Child.getDynamicSize(if (is_optional) val.*.? else val.*, new_size);
      }

      return new_size;
    }

    const Self = @This();
    pub const GS = struct {
      _static: Signature.D,
      _dynamic: Child.Signature.D,

      pub const Parent = Self;
      pub fn get(self: GS) if (is_optional) FnReturnType(@TypeOf(Child.read)) {
        if (is_optional and self._static.len == 0) return null;

        return Child.read(self._static, self._dynamic);
      }

      pub fn set(self: GS, val: *const T) void {
        std.debug.assert(val.* != null); // You cant make a non-null value null
        self.get().set(if (is_optional) val.*.? else val.*);
      }
    };

    pub fn read(_: S, dynamic: Signature.D) ?GS {
      const aligned = if (is_optional) dynamic.alignForward(Child.Signature.alignment) else dynamic;
      if (aligned.len == 0) return null;
      const child_static = aligned.till(Child.Signature.static_size);
      const child_dynamic = aligned.from(Child.Signature.static_size).alignForward(.fromByteUnits(Child.Signature.D.alignment));
      return .{ ._static = child_static, ._dynamic = child_dynamic };
    }
  };

  if (Retval.next_context.seen_recursive >= 0) return context.result_types[Retval.next_context.seen_recursive];
  return Retval;
}

/// Special case for zero sized types.
/// We store only the length. std.math.maxInt(context.options.len_int) is used as a null value in case of nullable slice.
pub fn GetZstSliceMergedT(context: Context) type {
  const T = context.options.T;
  const Len = GetDirectMergedT(context.T(context.options.len_int));

  const is_optional = @typeInfo(T) == .optional;
  const pi = @typeInfo(if (is_optional) @typeInfo(T).optional.child else T).pointer;
  std.debug.assert(pi.size == .slice);
  std.debug.assert(@sizeOf(pi.child) == 0);

  return opaque {
    const S = Bytes(Signature.alignment);
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

    pub fn read(static: S, _: Signature.D) *context.options.len_int {
      return @ptrCast(static.ptr);
    }
  };
}

/// Special case when the child is static.
/// We dont need to store the length as it can be inferred from the dynamic data size.
/// We will need a tag for optional slices to store existence.
pub fn GetStaticSliceMergedT(context: Context) type {
  const T = context.options.T;

  const is_optional = @typeInfo(T) == .optional;
  const pi = @typeInfo(if (is_optional) @typeInfo(T).optional.child else T).pointer;
  std.debug.assert(pi.size == .slice);

  const Existence = GetDirectMergedT(context.T(if (is_optional) u1 else void));

  return opaque {
    const S = Bytes(Signature.alignment);
    pub const Signature = Existence.Signature;

    pub fn write(val: *const T, static: S, _dynamic: Signature.D) usize {
      if (is_optional) {
        if (val.* == null) {
          std.debug.assert(0 == Existence.write(&@as(u1, 0), static, undefined));
          return 0;
        }
        std.debug.assert(0 == Existence.write(&@as(u1, 1), static, undefined));
      }

      const slice = if (is_optional) val.*.? else val.*;
      if (slice.len == 0) return 0;

      const child_static = _dynamic.alignForward(.fromByteUnits(@alignOf(pi.child)));
      const child_bytes = @as([*]align(@alignOf(pi.child)) u8, @ptrCast(slice.ptr))[0..@sizeOf(pi.child) * slice.len];
      @memcpy(child_static.slice(child_bytes.len), child_bytes);

      return @sizeOf(pi.child) * slice.len;
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      if (is_optional and val.* == null) return size;
      const slice = if (is_optional) val.*.? else val.*;
      if (slice.len == 0) return size;

      var new_size = std.mem.alignForward(usize, size, @alignOf(pi.child));
      new_size += @sizeOf(pi.child) * slice.len;
      return new_size;
    }

    pub fn read(static: S, dynamic: Signature.D) T {
      if (is_optional and Existence.read(static, undefined) == 0) return null;
      const aligned_dynamic = std.mem.alignForward(usize, @intFromPtr(static.ptr), Signature.alignment.toByteUnits());
      return @as([*]pi.child, @ptrCast(aligned_dynamic.ptr))[0..@sizeOf(pi.child) * dynamic.len];
    }
  };
}

/// Convert a slice type to writable opaque.
/// We store only the length. std.math.maxInt(context.options.len_int) is used as a null value in case of nullable slice.
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

  if (@sizeOf(pi.child) == 0) return GetZstSliceMergedT(context);
  const Len = GetDirectMergedT(context.T(context.options.len_int));
  const Index = GetDirectMergedT(context.T(context.options.offset_int));

  const Retval = opaque {
    const next_context = context.realign(.fromByteUnits(pi.alignment)).see(T, @This());
    const next_options = blk: {
      var retval = context.options;
      if (next_context.seen_recursive == -1) retval.deslice -= 1;
      break :blk retval;
    };

    const Child = next_context.reop(next_options).T(pi.child).merge();
    // we want to write the "more" aligned thing first
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
      @"0": Bytes(Index.Signature.alignment),
      @"1": Bytes(Child.Signature.alignment),
      @"2": Child.Signature.D,
    } {
      if (len == 1) {
        const aligned = dynamic.alignForward(Child.Signature.alignment);
        return .{
          .@"0" = undefined,
          .@"1" = aligned.till(Child.Signature.static_size * len),
          .@"2" = aligned.from(Child.Signature.static_size * len).alignForward(.fromByteUnits(Child.Signature.D.alignment)),
        };
      }
      if (IndexBeforeStatic) {
        const index_aligned = dynamic.alignForward(Index.Signature.alignment);
        return .{
          .@"0" = index_aligned.till(Index.Signature.static_size * (len - 1)),
          .@"1" = index_aligned.from(Index.Signature.static_size * (len - 1)).assertAligned(.fromByteUnits(Child.Signature.D.alignment)).till(Child.Signature.static_size * len),
          .@"2" = index_aligned.from(Index.Signature.static_size * (len - 1) + Child.Signature.static_size * len).alignForward(.fromByteUnits(Child.Signature.D.alignment)),
        };
      } else {
        const static_aligned = dynamic.alignForward(Child.Signature.alignment);
        return .{
          .@"0" = dynamic.from(Child.Signature.static_size * len).assertAligned(.fromByteUnits(Index.Signature.alignment)).till(Index.Signature.static_size * (len - 1)),
          .@"1" = static_aligned.till(Child.Signature.static_size * len),
          .@"2" = static_aligned.from(Index.Signature.static_size * (len - 1) + Child.Signature.static_size * len).alignForward(.fromByteUnits(Child.Signature.D.alignment)),
        };
      }
    }

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      const len = gl(val);
      std.debug.assert(0 == Len.write(&len, static, undefined));
      if ((is_optional and val.* == null) or len == 0) return 0;

      const index, var child_static, const child_dynamic = getStuff(dynamic, len);

      // First iteration
      var dwritten: context.options.offset_int = @intCast(Child.write(&val.*[0], child_static, child_dynamic));
      if (builtin.mode == .Debug) {
        std.debug.assert(dwritten == Child.getDynamicSize(&val.*[0], @intFromPtr(child_dynamic.ptr) - @intFromPtr(child_dynamic.ptr)));
      }
      child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);

      for (1..len) |i| {
        const item = &val.*[i];

        dwritten = std.mem.alignForward(context.options.offset_int, dwritten, Child.Signature.D.alignment);
        const written = Child.write(item, child_static, child_dynamic.from(dwritten).assertAligned(.fromByteUnits(Child.Signature.D.alignment)));
        if (builtin.mode == .Debug) {
          std.debug.assert(written == Child.getDynamicSize(item, @intFromPtr(child_dynamic.ptr) - @intFromPtr(child_dynamic.ptr)));
        }

        std.debug.assert(0 == Index.write(&dwritten, child_static, undefined));
        index = index.from(Index.Signature.static_size).assertAligned(Index.Signature.alignment);
        child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);
        dwritten += @intCast(written);
      }

      return dwritten + @intFromPtr(child_dynamic.ptr) - @intFromPtr(dynamic.ptr);
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      std.debug.assert(std.mem.isAligned(size, Signature.D.alignment));
      if (is_optional and val.* == null) return size;
      const slice = if (is_optional) val.*.? else val.*;
      if (slice.len == 0) return size;
      var new_size = std.mem.alignForward(usize, size, @max(Index.Signature.alignment.toByteUnits(), Child.Signature.alignment.toByteUnits()));
      new_size += Index.Signature.static_size * (slice.len - 1) + Child.Signature.static_size * slice.len;

      for (slice) |*item| {
        new_size = std.mem.alignForward(usize, new_size, Child.Signature.D.alignment);
        new_size = Child.getDynamicSize(item, new_size);
      }

      return new_size;
    }

    const Self = @This();
    pub const GS = struct {
      _len: *context.options.len_int,
      _index: Bytes(Len.Signature.alignment),
      _static: Bytes(Child.Signature.alignment),
      _dynamic: Child.Signature.D,

      pub const Parent = Self;
      pub fn len(self: GS) context.options.len_int {
        return self._len.*;
      }

      /// Be very careful with this. You cant overwrite beyond the dynamic data size
      pub fn setLen(self: GS, v: context.options.len_int) void {
        std.debug.assert(v != std.math.maxInt(context.options.len_int));
        self._len.* = v;
      }

      pub fn get(self: GS, i: context.options.offset_int) FnReturnType(@TypeOf(Child.read)) {
        const index_from = if (i == 0) 0 else Index.read(self._index.from(Index.Signature.static_size * (i - 1)).assertAligned(Index.Signature.alignment), undefined).*;
        const index_till = if (!Child.Signature.D.need_len) {} else if (i == self.len() - 1) self._dynamic.len
          else Index.read(self._index.from(Index.Signature.static_size * i).assertAligned(Index.Signature.alignment), undefined).*;

        var dynamic = self._dynamic.from(index_from).assertAligned(.fromByteUnits(Child.Signature.D.alignment));
        if (Child.Signature.D.need_len) dynamic = dynamic.till(index_till); // length needed

        return Child.read(self._static.from(Child.Signature.static_size * i).assertAligned(.fromByteUnits(Child.Signature.alignment)), dynamic);
      }

      pub fn set(self: GS, i: context.options.offset_int, val: *const pi.child) void {
        const index_offset = if (i == 0) 0
          else Index.read(self._index.from(Index.Signature.static_size * (i - 1)).assertAligned(.fromByteUnits(Index.Signature.alignment)), undefined).*;
        const written = Child.write(
          val,
          self._static.from(Child.Signature.static_size * i).assertAligned(.fromByteUnits(Child.Signature.alignment)),
          self._dynamic.from(index_offset).assertAligned(.fromByteUnits(Child.Signature.D.alignment)),
        );

        if (builtin.mode == .Debug) {
          const dynamic_len = (if (i == self.len() - 1) self._dynamic.len
            else Index.read(self._index.from(Index.Signature.static_size * i).assertAligned(.fromByteUnits(Index.Signature.alignment)), undefined)) - index_offset;
          if (Child.Signature.D.need_len) {
            std.debug.assert(written == dynamic_len);
          } else {
            std.debug.assert(written <= dynamic_len); // Cant overwrite beyond the max dynamic data size
          }
        }
      }
    };

    pub fn read(static: S, dynamic: Signature.D) ?GS {
      const len_ptr: *context.options.len_int = @ptrCast(static.ptr);
      if (is_optional and len_ptr.* == std.math.maxInt(context.options.len_int)) return null;

      const index, const child_static, const child_dynamic = getStuff(dynamic, len_ptr.*);
      return .{
        .len = len_ptr,
        .index = index,
        .static = child_static,
        .dynamic = child_dynamic,
      };
    }
  };

  if (!std.meta.hasFn(Retval.Child, "getDynamicSize")) return GetStaticSliceMergedT(context);
  if (Retval.next_context.seen_recursive >= 0) return context.result_types[Retval.next_context.seen_recursive];
  return Retval;
}

pub fn GetArrayMergedT(context: Context) type {
  @setEvalBranchQuota(1000_000);
  const T = context.options.T;
  const ai = @typeInfo(T).array;
  const Child = context.T(ai.child).merge();

  if (!std.meta.hasFn(Child, "getDynamicSize") or ai.len == 0) return GetDirectMergedT(context);
  const Index = GetDirectMergedT(context.T(context.options.offset_int));
  const IndexBeforeStatic = Index.Signature.alignment.toByteUnits() >= Child.Signature.alignment.toByteUnits();

  return opaque {
    const S = Bytes(Signature.alignment);

    pub const Signature = MergedSignature{
      .T = T,
      .D = Child.Signature.D,
      .static_size = Index.Signature.static_size * (ai.len - 1) + Child.Signature.static_size * ai.len,
      .alignment = if (ai.len == 1) Child.Signature.alignment else .fromByteUnits(@max(Child.Signature.alignment.toByteUnits, Index.Signature.alignment.toByteUnits())),
    };

    fn getStuff(static: S) struct {
      @"0": if (ai.len == 1) void else Bytes(Index.Signature.alignment),
      @"1": Bytes(Child.Signature.alignment),
    } {
      if (ai.len == 1) {
        return .{
          .@"0" = undefined,
          .@"1" = static.assertAligned(Child.Signature.alignment),
        };
      }
      if (IndexBeforeStatic) {
        return .{
          .@"0" = static.till(Index.Signature.static_size * (ai.len - 1)),
          .@"1" = static.from(Index.Signature.static_size * (ai.len - 1)).assertAligned(Child.Signature.alignment),
        };
      } else {
        return .{
          .@"0" = static.from(Child.Signature.static_size * ai.len).assertAligned(Index.Signature.alignment),
          .@"1" = static.till(Child.Signature.static_size * ai.len),
        };
      }
    }

    pub fn write(val: *const T, static: S, _dynamic: Signature.D) usize {
      const index, var child_static = getStuff(static);
      var dynamic = _dynamic;
      // First iteration
      var dwritten: context.options.offset_int = @intCast(Child.write(&val[0], child_static, dynamic));
      if (builtin.mode == .Debug) {
        std.debug.assert(dwritten == Child.getDynamicSize(&val[0], @intFromPtr(dynamic.ptr) - @intFromPtr(_dynamic.ptr)));
      }
      child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);

      inline for (1..ai.len) |i| {
        const item = &val[i];

        dwritten = std.mem.alignForward(context.options.offset_int, dwritten, Child.Signature.D.alignment);
        const written = Child.write(item, child_static, dynamic.from(dwritten).assertAligned(.fromByteUnits(Child.Signature.D.alignment)));
        if (builtin.mode == .Debug) {
          std.debug.assert(written == Child.getDynamicSize(item, @intFromPtr(dynamic.ptr) - @intFromPtr(_dynamic.ptr)));
        }

        std.debug.assert(0 == Index.write(&dwritten, index, undefined));
        index = index.from(Index.Signature.static_size).assertAligned(Index.Signature.alignment);
        child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);
        dwritten += @intCast(written);
      }

      return dwritten + @intFromPtr(dynamic.ptr) - @intFromPtr(_dynamic.ptr);
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      std.debug.assert(std.mem.isAligned(size, Signature.D.alignment));
      var new_size = size;

      inline for (0..ai.len) |i| {
        new_size = std.mem.alignForward(usize, new_size, Child.Signature.D.alignment);
        new_size = Child.getDynamicSize(&val[i], new_size);
      }

      return new_size;
    }

    const Self = @This();
    pub const GS = struct {
      _index: if (ai.len == 1) void else Bytes(Index.Signature.alignment),
      _static: Bytes(Child.Signature.alignment),
      _dynamic: Signature.D,

      pub const Parent = Self;

      pub fn get(self: GS, i: usize) FnReturnType(@TypeOf(Child.read)) {
        if (i == 0) return Child.read(self._static, self._dynamic);
        const offset_from = if (i == 0) 0 else Index.read(self._index.from(Index.Signature.static_size * (i - 1)).assertAligned(Index.Signature.alignment), undefined).*;
        const offset_till = if (!Child.Signature.D.need_len) {} else if (i == ai.len - 1) self._dynamic.len
          else Index.read(self._index.from(Index.Signature.static_size * i).assertAligned(Index.Signature.alignment), undefined).*;

        var dynamic = self._dynamic.from(offset_from).assertAligned(.fromByteUnits(Child.Signature.D.alignment));
        if (Child.Signature.D.need_len) dynamic = dynamic.till(offset_till); // length needed

        return Child.read(self._static.from(Child.Signature.static_size * i).assertAligned(.fromByteUnits(Child.Signature.alignment)), dynamic);
      }

      /// WARNING: This set method is dangerous. It cannot handle cases where the new value has a different dynamic size than the old one
      pub fn set(self: GS, i: context.options.offset_int, val: *const ai.child) void {
        const index_offset = if (i == 0) 0
          else Index.read(self._index.from(Index.Signature.static_size * (i - 1)).assertAligned(.fromByteUnits(Index.Signature.alignment)), undefined).*;
        const written = Child.write(
          val,
          self._static.from(Child.Signature.static_size * i).assertAligned(.fromByteUnits(Child.Signature.alignment)),
          self._dynamic.from(index_offset).assertAligned(.fromByteUnits(Child.Signature.D.alignment)),
        );

        if (builtin.mode == .Debug) {
          const dynamic_len = (if (i == self.len() - 1) self._dynamic.len
            else Index.read(self._index.from(Index.Signature.static_size * i).assertAligned(.fromByteUnits(Index.Signature.alignment)), undefined)) - index_offset;
          if (Child.Signature.D.need_len) {
            std.debug.assert(written == dynamic_len); // Cant change offsets if child type requires dynamic data size as well
          } else {
            std.debug.assert(written <= dynamic_len); // Cant overwrite beyond the max dynamic data size
          }
        }
      }
    };

    pub fn read(static: S, dynamic: Signature.D) GS {
      const index, const child_static = getStuff(static);
      return .{ ._index = index, ._static = child_static, ._dynamic = dynamic };
    }
  };
}

pub fn GetStructMergedT(context: Context) type {
  @setEvalBranchQuota(1000_000);
  const T = context.options.T;
  if (!context.options.recurse) return GetDirectMergedT(context);

  const si = @typeInfo(T).@"struct";
  const Retval = opaque {
    const next_context = context.see(T, @This());

    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = (if (fields[last_dynamic_field].merged.Signature.D.need_len) BytesLen else Bytes)(.fromByteUnits(fields[first_dynamic_field].merged.Signature.D.alignment)),
      .static_size = @sizeOf(T),
      .alignment = context.align_hint orelse .fromByteUnits(@alignOf(T)),
    };

    const Self = @This();
    const SD = struct {
      _static: S,
      _dynamic: Signature.D,
      comptime Parent: type = Self,
    };

    const ProcessedField = struct {
      /// original field
      original: std.builtin.Type.StructField,
      /// the merged type
      merged: type,
      /// is this field dynamic
      is_dynamic: bool,
      /// is this field an offset field
      is_offset: bool,

      pub fn sized(self: @This()) std.builtin.Type.StructField {
        return .{
          .name = self.original.name,
          .type = [self.merged.Signature.static_size]u8,
          .alignment = self.original.alignment,
          .default_value_ptr = null,
          .is_comptime = false,
        };
      }

      pub fn wrapped(self: @This(), index: comptime_int) std.builtin.Type.StructField {
        std.debug.assert(!self.is_offset);
        return .{
          .name = self.original.name,
          .type = struct {
            fn getSD(me: *const @This()) struct { _static: Bytes(self.merged.Signature.alignment), _dynamic: if (self.is_dynamic) self.merged.Signature.D else void } {
              const parent_ptr: *const RetTypeStruct = @fieldParentPtr(self.original.name, me);
              const sd = @field(parent_ptr, "\x00offset\xff");
              const static = sd.static.from(@offsetOf(RetTypeStruct, self.original.name)).assertAligned(self.merged.Signature.alignment);
              if (!self.is_dynamic) return .{ ._static = static, ._dynamic = undefined };

              const dynamic_from = sd.dynamic.from(@offsetOf(RetTypeStruct, self.original.name)).assertAligned(.fromByteUnits(self.merged.Signature.D.alignment));
              if (!self.merged.Signature.D.need_len) return .{ ._static = static, ._dynamic = dynamic_from };

              const next_index = comptime blk: {
                for (index + 1 .. fields.len) |i| if (fields[i].is_dynamic) break :blk i;
                break :blk fields.len;
              };
              if (next_index == fields.len) return .{ ._static = static, ._dynamic = dynamic_from };

              const next_name = fields[next_index].original.name;
              const dtill = @FieldType(RetTypeStruct, next_name).read(static.from(@offsetOf(OptimalLayoutStruct, "\x00offset\xff" ++ next_name)), undefined);
              return .{ ._static = static, ._dynamic = dynamic_from.upto(dtill) };
            }

            pub fn read(me: *const @This()) FnReturnType(@TypeOf(self.merged.read)) {
              const sd = getSD(me);
              return self.merged.read(sd._static, sd._dynamic);
            }
          },
          .alignment = self.original.alignment,
          .default_value_ptr = null,
          .is_comptime = false,
        };
      }
    };

    const fields = blk: {
      var processed: []const ProcessedField = &.{};
      var first = true;

      for (si.fields) |f| {
        std.debug.assert(!std.mem.startsWith(u8, f.name, "\x00offset\xff")); // This is not allowed
        const merged_child = next_context.realign(.fromByteUnits(f.alignment)).T(f.type).merge();
        const is_dynamic = std.meta.hasFn(merged_child, "getDynamicSize");
        processed = processed ++ &[1]ProcessedField{.{
          .original = f,
          .merged = merged_child,
          .is_dynamic = is_dynamic,
          .is_offset = false,
        }};
        if (is_dynamic) {
          const int_t = std.meta.Int(.unsigned, if (first) 0 else context.options.offset_int);
          first = false;
          processed = processed ++ &[1]ProcessedField{.{
            .original = std.builtin.Type.StructField{
              .name = "\x00offset\xff" ++ f.name,
              .type = int_t,
              .alignment = @alignOf(int_t),
              .default_value_ptr = null,
              .is_comptime = false,
            },
            .merged = next_context.realign(null).T(int_t).merge(),
            .is_dynamic = false,
            .is_offset = true,
          }};
        }
      }

      var processed_array: [processed.len]ProcessedField = undefined;
      for (processed, 0..) |f, i| processed_array[i] = f;

      std.sort.pdqContext(0, processed_array.len, struct {
        fields: []ProcessedField,

        fn greaterThan(self: @This(), lhs: usize, rhs: usize) bool {
          const ls = self.fields[lhs].merged.Signature;
          const rs = self.fields[rhs].merged.Signature;

          if (!std.meta.hasFn(self.fields[lhs].merged, "getDynamicSize")) return false;
          if (!std.meta.hasFn(self.fields[rhs].merged, "getDynamicSize")) return true;

          if (ls.D.alignment != rs.D.alignment) return ls.D.alignment > rs.D.alignment;
          if (ls.D.alignment != 1) return false;

          comptime var lst = @typeInfo(ls.T);
          comptime var rst = @typeInfo(rs.T);

          if ((lst == .optional or lst == .pointer) and (rst == .optional or rst == .pointer)) {
            if (lst == .optional) lst = @typeInfo(lst.optional.child);
            if (rst == .optional) rst = @typeInfo(rst.optional.child);
          } else if (lst == .optional or rst == .optional) {
            return lst != .optional;
          }

          if (lst == .pointer and rst == .pointer) {
            if (lst.pointer.size != rst.pointer.size) {
              const lsize = lst.pointer.size;
              const rsize = rst.pointer.size;
              if (lsize == .one) return true;
              if (rsize == .one) return false;

              if (lsize == .slice) return true;
              if (rsize == .slice) return false;

              return false;
            } else {
              return @alignOf(lst.pointer.child) > @alignOf(rst.pointer.child);
            }
          } else if (lst == .pointer or rst == .pointer) {
            if (lst == .pointer) return lst.pointer.size != .slice and @alignOf(lst.pointer.child) > @alignOf(rst.pointer.child);
            return rst.pointer.size == .slice or @alignOf(lst.pointer.child) > @alignOf(rst.pointer.child);
          }

          return false;
        }

        pub const lessThan = greaterThan;

        pub fn swap(self: @This(), lhs: usize, rhs: usize) void {
          const temp = self.fields[lhs];
          self.fields[lhs] = self.fields[rhs];
          self.fields[rhs] = temp;
        }
      }{ .fields = &processed_array });

      break :blk processed_array;
    };

    // we construct a struct with backing memory as array to get the optimal layout.
    const OptimalLayoutStruct: type = blk: {
      var fields_array: [fields.len]std.builtin.Type.StructField = undefined;
      for (fields, 0..) |f, i| fields_array[i] = f.sized();
      break :blk @Type(.{.@"struct" = .{
        .layout = .auto,
        .fields = &fields_array,
        .decls = &.{},
        .is_tuple = false,
      }});
    };

    // this is the type return by read
    const RetTypeStruct = blk: {
      if (false) break :blk T;

      var fields_array: [1 + si.fields.len]std.builtin.Type.StructField = undefined;
      fields_array[0] = .{ // This field will contain static/dynmic pair
        .name = "\x00offset\xff",
        .type = SD,
        .alignment = @alignOf(SD),
        .default_value_ptr = null,
        .is_comptime = false,
      };

      var i: usize = 1;
      for (fields, 0..) |f, j| {
        if (f.is_offset) continue;
        fields_array[i] = f.wrapped(j);
        i += 1;
      }
      break :blk @Type(.{.@"struct" = .{
        .layout = .auto,
        .fields = &fields_array,
        .decls = &.{},
        .is_tuple = false,
      }});
    };

    const first_dynamic_field = blk: {
      for (fields, 0..) |f, i| if (f.is_dynamic) break :blk i;
      break :blk fields.len;
    };

    const last_dynamic_field = blk: {
      for (0..fields.len) |i| if (fields[fields.len - 1 - i].is_dynamic) break :blk fields.len - 1 - i;
      break :blk fields.len;
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      var dwritten: context.options.offset_int = 0;
      comptime var first = true;

      inline for (fields) |f| {
        if (f.is_offset) continue;
        if (!f.is_dynamic) {
          std.debug.assert(0 == f.merged.write(&@field(val.*, f.original.name), static.from(@offsetOf(OptimalLayoutStruct, f.name)), undefined));
          continue;
        }

        if (first) {
          first = false;
        } else {
          dwritten = std.mem.alignForward(usize, dwritten, f.merged.Signature.alignment.toByteUnits());
        }

        const child_dynamic = dynamic.from(dwritten).assertAligned(.fromByteUnits(f.merged.Signature.D.alignment));
        const written = f.merged.write(&@field(val.*, f.original.name), static.from(@offsetOf(OptimalLayoutStruct, f.name)), child_dynamic);

        const name = "\x00offset\xff" ++ f.original.name;
        @FieldType(OptimalLayoutStruct, name).write(&dwritten, static.from(@offsetOf(OptimalLayoutStruct, name)), undefined);
        dwritten += written;
      }

      return dwritten;
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      std.debug.assert(std.mem.isAligned(size, Signature.D.alignment));
      var new_size: usize = size;

      inline for (fields) |f| {
        if (!f.is_dynamic) continue;
        new_size = std.mem.alignForward(usize, new_size, f.merged.Signature.D.alignment);
        new_size = f.merged.getDynamicSize(&@field(val.*, f.original.name), new_size);
      }

      return new_size;
    }

    pub fn read(static: S, dynamic: Signature.D) RetTypeStruct {
      var retval: RetTypeStruct = undefined;
      @field(retval, "\x00offset\xff") = .{ ._static = static, ._dynamic = dynamic };
      return retval;
    }
  };

  // If no fields are dynamic, it's just a direct copy.
  if (Retval.fields.len == si.fields.len) return GetDirectMergedT(context);
  if (si.layout == .@"packed") @compileError("Packed structs with dynamic fields are not yet supported");
  if (Retval.next_context.seen_recursive >= 0) return context.result_types[Retval.next_context.seen_recursive];
  return Retval;
}

pub fn GetOptionalMergedT(context: Context) type {
  const T = context.options.T;
  const oi = @typeInfo(T).optional;

  const Retval = opaque {
    const next_context = context.T(union {
      some: oi.child,
      none: void,
    });
    const Sub = next_context.merge();

    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = if (Sub.Signature.D.need_len) BytesLen(.@"1") else Bytes(.@"1"),
      .static_size = Sub.Signature.static_size,
      .alignment = context.align_hint orelse .fromByteUnits(@alignOf(T)),
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      const union_val: Sub = if (val.*) |payload_val| .{ .some = payload_val } else .{ .none = {} };
      const written = Sub.write(&union_val, static, dynamic);
      if (val.* == null) std.debug.assert(0 == written);
      return written;
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      const union_val: Sub = if (val.*) |payload_val| .{ .some = payload_val } else .{ .none = {} };
      return Sub.getDynamicSize(&union_val, size);
    }

    pub fn read(static: S, dynamic: Signature.D) ?FnReturnType(@TypeOf(@FieldType(Sub, "some").read)) {
      return switch (Sub.read(static, dynamic).get()) {
        .some => |some| some,
        .none => null,
      };
    }
  };

  if (!std.meta.hasFn(Retval.Child, "getDynamicSize")) return GetDirectMergedT(context);
}

pub fn GetErrorUnionMergedT(context: Context) type {
  const T = context.options.T;
  const ei = @typeInfo(T).error_union;

  return opaque {
    const next_context = context.T(union {
      ok: ei.payload,
      err: anyerror,
    });
    const Sub = next_context.merge();

    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = if (Sub.Signature.D.need_len) BytesLen(.@"1") else Bytes(.@"1"),
      .static_size = Sub.Signature.static_size,
      .alignment = context.align_hint orelse .fromByteUnits(@alignOf(T)),
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      const union_val: Sub = if (val.*) |payload_val| .{ .ok = payload_val } else |e| .{ .err = e };
      const written = Sub.write(&union_val, static, dynamic);
      if (val.* == null) std.debug.assert(0 == written);
      return written;
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      const union_val: Sub = if (val.*) |payload_val| .{ .ok = payload_val } else |e| .{ .err = e };
      return Sub.getDynamicSize(&union_val, size);
    }

    pub fn read(static: S, dynamic: Signature.D) ei.error_set!FnReturnType(@TypeOf(@FieldType(Sub, "ok").read)) {
      return switch (Sub.read(static, dynamic).get()) {
        .ok => |ok| ok,
        .err => |err| err,
      };
    }
  };
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

