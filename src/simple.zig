const std = @import("std");
const builtin = @import("builtin");
const meta = @import("meta.zig");

const Bytes = meta.Bytes;
const MergedSignature = meta.MergedSignature;
pub const Context = meta.GetContext(ToMergedOptions);

/// Options to control how merging of a type is performed
pub const ToMergedOptions = struct {
  /// The type that is to be merged
  T: type,
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
  /// Serialize unknown pointers (C / Many / opaque pointers) as usize
  serialize_unknown_pointer_as_usize: bool = false,
  /// Only allow for safe conversions (eg: compileError on trying to merge dynamic union, dynamic error union and dynamic optional)
  error_on_unsafe_conversion: bool = false,

  /// the level of logging that is enabled
  log_level: meta.LogLevel = .none,
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
  };
}

/// Convert a supplid pointer type to writable opaque
pub fn GetPointerMergedT(context: Context) type {
  const T = context.options.T;
  if (!context.options.dereference) return GetDirectMergedT(context);

  const is_optional = @typeInfo(T) == .optional;
  const pi = @typeInfo(if (is_optional) @typeInfo(T).optional.child else T).pointer;
  std.debug.assert(pi.size == .one);

  const Pointer = GetDirectMergedT(context);

  const Retval = opaque {
    const next_context = context.realign(.fromByteUnits(pi.alignment)).see(T, @This());
    const Child = next_context.T(pi.child).merge();

    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(if (is_optional) .@"1" else Child.Signature.alignment),
      .static_size = Pointer.Signature.static_size,
      .alignment = context.align_hint orelse .fromByteUnits(@alignOf(T)),
    };

    pub fn write(val: *const T, static: S, _dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Pointer.Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(_dynamic.ptr), Signature.D.alignment));

      if (is_optional and val.* == null) {
        std.debug.assert(0 == Pointer.write(&@as(T, null), static, undefined));
        return 0;
      }
      const dynamic = if (is_optional) _dynamic.alignForward(Child.Signature.alignment) else _dynamic;
      const dptr: T = @ptrCast(@alignCast(dynamic.ptr));
      std.debug.assert(0 == Pointer.write(&dptr, static, undefined));

      const child_static = dynamic.till(Child.Signature.static_size);
      // Align 1 if child is static, so no issue here, static and dynamic children an be written by same logic
      const child_dynamic = dynamic.from(Child.Signature.static_size).alignForward(.fromByteUnits(Child.Signature.D.alignment));
      const written = Child.write(if (is_optional) val.*.? else val.*, child_static, child_dynamic);

      if (std.meta.hasFn(Child, "getDynamicSize") and builtin.mode == .Debug) {
        std.debug.assert(written == Child.getDynamicSize(if (is_optional) val.*.? else val.*, @intFromPtr(child_dynamic.ptr)) - @intFromPtr(child_dynamic.ptr));
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

    pub fn repointer(static: S, _dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Pointer.Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(_dynamic.ptr), Signature.D.alignment));

      if (is_optional and @as(*T, @ptrCast(static.ptr)).* == null) return 0;
      const dynamic = if (is_optional) _dynamic.alignForward(Child.Signature.alignment) else _dynamic;
      const dptr: T = @ptrCast(@alignCast(dynamic.ptr));
      std.debug.assert(0 == Pointer.write(&dptr, static, undefined));
      if (!std.meta.hasFn(Child, "repointer")) {
        return Child.Signature.static_size + @intFromPtr(dynamic.ptr) - @intFromPtr(_dynamic.ptr);
      }

      const child_static = dynamic.till(Child.Signature.static_size);
      // Align 1 if child is static, so no issue here, static and dynamic children an be written by same logic
      const child_dynamic = dynamic.from(Child.Signature.static_size).alignForward(.fromByteUnits(Child.Signature.D.alignment));
      const written = Child.repointer(child_static, child_dynamic);

      if (std.meta.hasFn(Child, "getDynamicSize") and builtin.mode == .Debug) {
        const val = @as(*T, @ptrCast(static.ptr)).*;
        std.debug.assert(written == Child.getDynamicSize(if (is_optional) val.? else val, @intFromPtr(child_dynamic.ptr)) - @intFromPtr(child_dynamic.ptr));
      }

      return written + @intFromPtr(child_dynamic.ptr) - @intFromPtr(_dynamic.ptr);
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
  const Slice = GetDirectMergedT(context);

  const Retval = opaque {
    const next_context = context.realign(.fromByteUnits(pi.alignment)).see(T, @This());
    const next_options = blk: {
      var retval = context.options;
      if (next_context.seen_recursive == -1) retval.deslice -= 1;
      break :blk retval;
    };
    const Child = next_context.reop(next_options).T(pi.child).merge();
    const SubStatic = !std.meta.hasFn(Child, "getDynamicSize");
    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(if (is_optional) .@"1" else Child.Signature.alignment),
      .static_size = Slice.Signature.static_size,
      .alignment = Slice.Signature.alignment,
    };

    pub fn write(val: *const T, static: S, _dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(_dynamic.ptr), Signature.D.alignment));
      const dynamic = if (is_optional) _dynamic.alignForward(Child.Signature.alignment) else _dynamic;

      var header_to_write = val.*;
      if (!is_optional or val.* != null) header_to_write.ptr = @ptrCast(dynamic.ptr);
      std.debug.assert(0 == Slice.write(&header_to_write, static, undefined));
      if (is_optional and val.* == null) return 0;
      const slice = if (is_optional) val.*.? else val.*;

      const len = slice.len;
      if (Child.Signature.static_size == 0 or len == 0) return 0;

      var child_static = dynamic.till(Child.Signature.static_size * len);
      var child_dynamic = dynamic.from(Child.Signature.static_size * len).alignForward(.fromByteUnits(Child.Signature.D.alignment));

      for (slice) |*item| {
        if (!SubStatic) child_dynamic = child_dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
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

pub fn GetArrayMergedT(context: Context) type {
  const T = context.options.T;
  @setEvalBranchQuota(1000_000);
  const ai = @typeInfo(T).array;
  // No need to .see(T) here as the child will handle this anyway and if the array type is repeated, the child will be too.
  const Child = context.T(ai.child).merge();

  // If the child has no dynamic data, the entire array is static.
  // We can treat it as a direct memory copy.
  if (!std.meta.hasFn(Child, "getDynamicSize")) return GetDirectMergedT(context);

  return opaque {
    const S = Bytes(Signature.alignment);

    pub const Signature = MergedSignature{
      .T = T,
      .D = Child.Signature.D,
      .static_size = Child.Signature.static_size * ai.len,
      .alignment = Child.Signature.alignment,
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(dynamic.ptr), Signature.D.alignment));

      var child_static = static.till(Signature.static_size);
      var child_dynamic = dynamic;

      inline for (val) |*item| {
        child_dynamic = child_dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.write(item, child_static, child_dynamic);

        if (builtin.mode == .Debug) {
          std.debug.assert(written == Child.getDynamicSize(item, @intFromPtr(child_dynamic.ptr)) - @intFromPtr(child_dynamic.ptr));
        }

        child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);
        child_dynamic = child_dynamic.from(written);
      }

      return @intFromPtr(child_dynamic.ptr) - @intFromPtr(dynamic.ptr);
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

    pub fn repointer(static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(dynamic.ptr), Signature.D.alignment));

      var child_static = static.till(Signature.static_size);
      var child_dynamic = dynamic;

      inline for (0..ai.len) |i| {
        child_dynamic = child_dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.repointer(child_static, child_dynamic);

        if (builtin.mode == .Debug) {
          const val: *T = @ptrCast(static.ptr);
          std.debug.assert(written == Child.getDynamicSize(&val[i], @intFromPtr(child_dynamic.ptr)) - @intFromPtr(child_dynamic.ptr));
        }

        child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);
        child_dynamic = child_dynamic.from(written);
      }

      return @intFromPtr(child_dynamic.ptr) - @intFromPtr(dynamic.ptr);
    }
  };
}

pub fn GetStructMergedT(context: Context) type {
  const T = context.options.T;
  @setEvalBranchQuota(1000_000);
  if (!context.options.recurse) return GetDirectMergedT(context);

  const si = @typeInfo(T).@"struct";
  const ProcessedField = struct {
    original: std.builtin.Type.StructField,
    merged: type,
    static_offset: comptime_int,
  };

  const Retval = opaque {
    const next_context = context.see(T, @This());

    const fields = blk: {
      var pfields: [si.fields.len]ProcessedField = undefined;

      for (si.fields, 0..) |f, i| {
        pfields[i] = .{
          .original = f,
          .merged = next_context.realign(if (si.layout == .@"packed") .@"1" else .fromByteUnits(f.alignment)).T(f.type).merge(),
          .static_offset = @offsetOf(T, f.name),
        };
      }

      std.sort.pdqContext(0, pfields.len, struct {
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
      }{ .fields = &pfields });

      break :blk pfields;
    };

    const FirstNonStaticT = blk: {
      for (fields, 0..) |f, i| if (std.meta.hasFn(f.merged, "getDynamicSize")) break :blk i;
      break :blk fields.len;
    };

    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(.fromByteUnits(fields[FirstNonStaticT].merged.Signature.D.alignment)),
      .static_size = @sizeOf(T),
      .alignment = context.align_hint orelse .fromByteUnits(@alignOf(T)),
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(dynamic.ptr), Signature.D.alignment));

      var dynamic_offset: usize = 0;
      inline for (fields) |f| {
        const child_static = static.from(f.static_offset).assertAligned(f.merged.Signature.alignment);

        if (!std.meta.hasFn(f.merged, "getDynamicSize")) {
          const written = f.merged.write(&@field(val.*, f.original.name), child_static, undefined);
          std.debug.assert(written == 0);
        } else {
          const misaligned_dynamic = dynamic.from(dynamic_offset);
          const aligned_dynamic = misaligned_dynamic.alignForward(.fromByteUnits(f.merged.Signature.D.alignment));
          const written = f.merged.write(&@field(val.*, f.original.name), child_static, aligned_dynamic);

          if (builtin.mode == .Debug) {
            std.debug.assert(written == f.merged.getDynamicSize(&@field(val.*, f.original.name), @intFromPtr(aligned_dynamic.ptr)) - @intFromPtr(aligned_dynamic.ptr));
          }

          dynamic_offset += written + @intFromPtr(aligned_dynamic.ptr) - @intFromPtr(misaligned_dynamic.ptr);
        }
      }

      return dynamic_offset;
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      std.debug.assert(std.mem.isAligned(size, Signature.D.alignment));
      var new_size: usize = size;

      inline for (fields) |f| {
        if (!std.meta.hasFn(f.merged, "getDynamicSize")) continue;
        new_size = std.mem.alignForward(usize, new_size, f.merged.Signature.D.alignment);
        new_size = f.merged.getDynamicSize(&@field(val.*, f.original.name), new_size);
      }

      return new_size;
    }

    pub fn repointer(static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(dynamic.ptr), Signature.D.alignment));

      var dynamic_offset: usize = 0;
      inline for (fields) |f| {
        const child_static = static.from(f.static_offset).assertAligned(f.merged.Signature.alignment);

        if (std.meta.hasFn(f.merged, "getDynamicSize")) {
          const misaligned_dynamic = dynamic.from(dynamic_offset);
          const aligned_dynamic = misaligned_dynamic.alignForward(.fromByteUnits(f.merged.Signature.D.alignment));
          const written = f.merged.repointer(child_static, aligned_dynamic);

          if (builtin.mode == .Debug) {
            const val: *T = @ptrCast(static.ptr);
            std.debug.assert(written == f.merged.getDynamicSize(&@field(val.*, f.original.name), @intFromPtr(aligned_dynamic.ptr)) - @intFromPtr(aligned_dynamic.ptr));
          }

          dynamic_offset += written + @intFromPtr(aligned_dynamic.ptr) - @intFromPtr(misaligned_dynamic.ptr);
        }
      }

      return dynamic_offset;
    }
  };

  if (Retval.next_context.seen_recursive >= 0) return context.result_types[Retval.next_context.seen_recursive];
  if (Retval.FirstNonStaticT == Retval.fields.len) return GetDirectMergedT(context);
  if (si.layout == .@"packed") @compileError("Packed structs with dynamic data are not supported");
  return Retval;
}

pub fn GetOptionalMergedT(context: Context) type {
  const T = context.options.T;
  const oi = @typeInfo(T).optional;
  const Child = context.T(oi.child).merge();
  if (!std.meta.hasFn(Child, "getDynamicSize")) return GetDirectMergedT(context);

  if (context.options.error_on_unsafe_conversion) {
    @compileError("Cannot merge unsafe optional type " ++ @typeName(T));
  }

  const Tag = context.T(bool).merge();

  const alignment = context.align_hint orelse .fromByteUnits(@alignOf(T));
  return opaque {
    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(.@"1"),
      .static_size = @sizeOf(T),
      .alignment = alignment,
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      const tag_static = static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);
      const child_static = static.till(Child.Signature.static_size);

      if (val.*) |*payload_val| {
        std.debug.assert(0 == Tag.write(&@as(bool, true), tag_static, undefined));
        const aligned_dynamic = dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.write(payload_val, child_static, aligned_dynamic);

        if (builtin.mode == .Debug) {
          std.debug.assert(written == Child.getDynamicSize(payload_val, @intFromPtr(aligned_dynamic.ptr)) - @intFromPtr(aligned_dynamic.ptr));
        }

        return written + @intFromPtr(aligned_dynamic.ptr) - @intFromPtr(dynamic.ptr);
      } else {
        std.debug.assert(0 == Tag.write(&@as(bool, false), tag_static, undefined));
        return 0;
      }
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      if (val.*) |*payload_val| {
        const new_size = std.mem.alignForward(usize, size, Child.Signature.D.alignment);
        return Child.getDynamicSize(payload_val, new_size);
      } else {
        return size;
      }
    }

    pub fn repointer(static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      const child_static = static.till(Child.Signature.static_size);

      const val: *T = @ptrCast(static.ptr);
      if (val.*) |*payload_val| {
        const aligned_dynamic = dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.repointer(child_static, aligned_dynamic);

        if (builtin.mode == .Debug) {
          std.debug.assert(written == Child.getDynamicSize(payload_val, @intFromPtr(aligned_dynamic.ptr)) - @intFromPtr(aligned_dynamic.ptr));
        }

        return written + @intFromPtr(aligned_dynamic.ptr) - @intFromPtr(dynamic.ptr);
      }
      return 0;
    }
  };
}

pub fn GetErrorUnionMergedT(context: Context) type {
  const T = context.options.T;
  const ei = @typeInfo(T).error_union;
  const Payload = ei.payload;
  const ErrorSet = ei.error_set;
  const ErrorInt = std.meta.Int(.unsigned, @bitSizeOf(ErrorSet));

  const Child = context.T(Payload).merge();
  if (!std.meta.hasFn(Child, "getDynamicSize")) return GetDirectMergedT(context);

  if (context.options.error_on_unsafe_conversion) {
    @compileError("Cannot merge unsafe error union type " ++ @typeName(T));
  }

  const Err = context.T(ErrorInt).merge();

  const ErrSize = Err.Signature.static_size;
  const PayloadSize = Child.Signature.static_size;
  const PayloadBeforeError = PayloadSize >= ErrSize;
  const UnionSize = if (PayloadSize < ErrSize) 2 * ErrSize
    else if (PayloadSize <= 16) 2 * PayloadSize
    else PayloadSize + 16;

  return opaque {
    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(.@"1"),
      .static_size = UnionSize,
      .alignment = std.mem.Alignment.max(Child.Signature.alignment, Err.Signature.alignment),
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));

      const payload_buffer = if (PayloadBeforeError) static.till(PayloadSize) else static.from(ErrSize);
      const error_buffer = if (PayloadBeforeError) static.from(PayloadSize) else static.till(ErrSize);

      if (val.*) |*payload_val| {
        std.debug.assert(0 == Err.write(&@as(ErrorInt, 0), error_buffer, undefined));
        const aligned_dynamic = dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.write(payload_val, payload_buffer, aligned_dynamic);

        if (builtin.mode == .Debug) {
          std.debug.assert(written == Child.getDynamicSize(payload_val, @intFromPtr(aligned_dynamic.ptr)) - @intFromPtr(aligned_dynamic.ptr));
        }

        return written + @intFromPtr(aligned_dynamic.ptr) - @intFromPtr(dynamic.ptr);
      } else |err| {
        const error_int: ErrorInt = @intFromError(err);
        std.debug.assert(0 == Err.write(&error_int, error_buffer, undefined));
        return 0;
      }
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      if (val.*) |*payload_val| {
        const new_size = std.mem.alignForward(usize, size, Child.Signature.D.alignment);
        return Child.getDynamicSize(payload_val, new_size);
      } else {
        return size;
      }
    }

    pub fn repointer(static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));

      const payload_buffer = if (PayloadBeforeError) static.till(PayloadSize) else static.from(ErrSize);
      const val: *T = @ptrCast(static.ptr);

      if (val.*) |*payload_val| {
        const aligned_dynamic = dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.repointer(payload_buffer, aligned_dynamic);

        if (builtin.mode == .Debug) {
          std.debug.assert(written == Child.getDynamicSize(payload_val, @intFromPtr(aligned_dynamic.ptr)) - @intFromPtr(aligned_dynamic.ptr));
        }

        return written + @intFromPtr(aligned_dynamic.ptr) - @intFromPtr(dynamic.ptr);
      }
    }
  };
}

pub fn GetUnionMergedT(context: Context) type {
  const T = context.options.T;
  if (!context.options.recurse) return GetDirectMergedT(context);

  const ui = @typeInfo(T).@"union";
  const TagType = ui.tag_type orelse std.meta.FieldEnum(T);
  const Retval = opaque {
    const next_context = context.see(T, @This());

    const ProcessedField = struct {
      original: std.builtin.Type.UnionField,
      merged: type,
    };

    const fields = blk: {
      var pfields: [ui.fields.len]ProcessedField = undefined;
      for (ui.fields, 0..) |f, i| {
        if (f.alignment < @alignOf(f.type)) {
          @compileError("Underaligned union fields cause memory corruption!\n"); // https://github.com/ziglang/zig/issues/19404, https://github.com/ziglang/zig/issues/21343
        }
        pfields[i] = .{
          .original = f,
          .merged = next_context.realign(.fromByteUnits(f.alignment)).T(f.type).merge(),
        };
      }
      break :blk pfields;
    };

    const Tag = context.realign(null).T(TagType).merge();
    const max_child_static_size = blk: {
      var max_size: usize = 0;
      for (fields) |f| max_size = @max(max_size, f.merged.Signature.static_size);
      break :blk max_size;
    };

    const max_child_static_alignment = blk: {
      var max_align: u29 = 1;
      for (fields) |f| max_align = @max(max_align, f.merged.Signature.alignment.toByteUnits());
      break :blk max_align;
    };

    const alignment: std.mem.Alignment = context.align_hint orelse .fromByteUnits(@alignOf(T));
    const tag_first = Tag.Signature.alignment.toByteUnits() > max_child_static_alignment;

    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(.@"1"),
      .static_size = @sizeOf(T),
      .alignment = alignment,
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      const active_tag = std.meta.activeTag(val.*);
      if (tag_first) {
        std.debug.assert(0 == Tag.write(&active_tag, static.till(Tag.Signature.static_size), undefined));
      } else {
        std.debug.assert(0 == Tag.write(&active_tag, static.from(max_child_static_size), undefined));
      }
      // we dont need to align static again since if the tag is first,
      // it had greater alignment and hence static data is aligned already

      inline for (fields) |f| {
        const field_as_tag = comptime std.meta.stringToEnum(TagType, f.original.name);
        if (field_as_tag == active_tag) {
          const child_static = if (tag_first) static.from(max_child_static_size).assertAligned(f.merged.Signature.alignment)
            else static.till(f.merged.Signature.static_size).assertAligned(f.merged.Signature.alignment);

          if (!std.meta.hasFn(f.merged, "getDynamicSize")) {
            return f.merged.write(&@field(val.*, f.original.name), child_static, undefined);
          } else {
            const aligned_dynamic = dynamic.alignForward(.fromByteUnits(f.merged.Signature.D.alignment));
            const written = f.merged.write(&@field(val.*, f.original.name), child_static, aligned_dynamic);

            if (builtin.mode == .Debug) {
              std.debug.assert(written == f.merged.getDynamicSize(&@field(val.*, f.original.name), @intFromPtr(aligned_dynamic.ptr)) - @intFromPtr(aligned_dynamic.ptr));
            }

            return written + @intFromPtr(aligned_dynamic.ptr) - @intFromPtr(dynamic.ptr);
          }
        }
      }
      unreachable; // Should never heppen
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      std.debug.assert(std.mem.isAligned(size, Signature.D.alignment));
      const active_tag = std.meta.activeTag(val.*);

      inline for (fields) |f| {
        const field_as_tag = comptime std.meta.stringToEnum(TagType, f.original.name);
        if (field_as_tag == active_tag) {
          if (!std.meta.hasFn(f.merged, "getDynamicSize")) return size;
          const new_size = std.mem.alignForward(usize, size, f.merged.Signature.D.alignment);
          return f.merged.getDynamicSize(&@field(val.*, f.original.name), new_size);
        }
      }
      unreachable;
    }

    pub fn repointer(static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      const val: *T = @ptrCast(static.ptr);
      const active_tag = std.meta.activeTag(val.*);
      // we dont need to align static again since if the tag is first,
      // it had greater alignment and hence static data is aligned already

      inline for (fields) |f| {
        const field_as_tag = comptime std.meta.stringToEnum(TagType, f.original.name);
        if (field_as_tag == active_tag) {
          const child_static = if (tag_first) static.from(max_child_static_size).assertAligned(f.merged.Signature.alignment)
            else static.till(f.merged.Signature.static_size).assertAligned(f.merged.Signature.alignment);

          if (std.meta.hasFn(f.merged, "getDynamicSize")) {
            const aligned_dynamic = dynamic.alignForward(.fromByteUnits(f.merged.Signature.D.alignment));
            const written = f.merged.repointer(child_static, aligned_dynamic);

            if (builtin.mode == .Debug) {
              std.debug.assert(written == f.merged.getDynamicSize(&@field(val.*, f.original.name), @intFromPtr(aligned_dynamic.ptr)) - @intFromPtr(aligned_dynamic.ptr));
            }

            return written + @intFromPtr(aligned_dynamic.ptr) - @intFromPtr(dynamic.ptr);
          } else {
            return 0;
          }
        }
      }
      unreachable; // Should never heppen
    }
  };

  if (Retval.next_context.seen_recursive >= 0) return context.result_types[Retval.next_context.seen_recursive];

  if (comptime blk: {
    for (Retval.fields) |f| {
      if (std.meta.hasFn(f.merged, "getDynamicSize")) {
        break :blk false;
      }
    }
    break :blk true;
  }) return GetDirectMergedT(context);

  if (ui.tag_type == null) {
    @compileError("Cannot merge untagged union " ++ @typeName(T));
  }

  if (context.options.error_on_unsafe_conversion) {
    @compileError("Cannot merge unsafe union type " ++ @typeName(T));
  }

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

// ========================================
//                 Testing                 
// ========================================

const testing = std.testing;
const expectEqual = @import("testing.zig").expectEqual;

fn _testMergingDemerging(value: anytype, comptime options: ToMergedOptions) !void {
  const MergedT = Context.init(options, ToMergedT);
  const static_size = MergedT.Signature.static_size;
  var buffer: [static_size + 4096]u8 = undefined;

  const total_size = if (std.meta.hasFn(MergedT, "getDynamicSize")) MergedT.getDynamicSize(&value, static_size) else static_size;
  if (total_size > buffer.len) {
    std.log.err("buffer too small for test. need {d}, have {d}", .{ total_size, buffer.len });
    return error.NoSpaceLeft;
  }

  const dynamic_from = std.mem.alignForward(usize, static_size, MergedT.Signature.D.alignment);
  const written_dynamic_size = MergedT.write(&value, .initAssert(buffer[0..static_size]), .initAssert(buffer[dynamic_from..]));
  try std.testing.expectEqual(total_size - dynamic_from, written_dynamic_size);

  try expectEqual(&value, @as(*@TypeOf(value), @ptrCast(@alignCast(&buffer))));

  const copy = try testing.allocator.alignedAlloc(u8, MergedT.Signature.alignment.toByteUnits(), total_size);
  defer testing.allocator.free(copy);
  @memcpy(copy, buffer[0..total_size]);
  @memset(buffer[0..total_size], 0);

  // repointer only is non static
  if (std.meta.hasFn(MergedT, "getDynamicSize")) {
    const repointered_size = MergedT.repointer(.initAssert(copy[0..static_size]), .initAssert(copy[dynamic_from..]));
    try std.testing.expectEqual(written_dynamic_size, repointered_size);
  }

  // verify
  try expectEqual(&value, @as(*@TypeOf(value), @ptrCast(copy)));
}

fn testMerging(value: anytype) !void {
  try _testMergingDemerging(value, .{ .T = @TypeOf(value) });
}

test "primitives" {
  try testMerging(@as(u32, 42));
  try testMerging(@as(f64, 123.456));
  try testMerging(@as(bool, true));
  try testMerging(@as(void, {}));
}

test "pointers" {
  var x: u64 = 12345;
  try testMerging(&x);
  try _testMergingDemerging(&x, .{ .T = *u64, .dereference = false });
}

test "slices" {
  // primitive
  try testMerging(@as([]const u8, "hello zig"));

  // struct
  const Point = struct { x: u8, y: u8 };
  try testMerging(@as([]const Point, &.{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } }));

  // nested
  try testMerging(@as([]const []const u8, &.{"hello", "world", "zig", "rocks"}));

  // empty
  try testMerging(@as([]const u8, &.{}));
  try testMerging(@as([]const []const u8, &.{}));
  try testMerging(@as([]const []const u8, &.{"", "a", ""}));
}

test "arrays" {
  // primitive
  try testMerging([4]u8{ 1, 2, 3, 4 });

  // struct array
  const Point = struct { x: u8, y: u8 };
  try testMerging([2]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } });

  // nested arrays
  try testMerging([2][2]u8{ .{ 1, 2 }, .{ 3, 4 } });

  // empty
  try testMerging([0]u8{});
}

test "structs" {
  // Simple
  const Point = struct { x: i32, y: i32 };
  try testMerging(Point{ .x = -10, .y = 20 });

  // Nested
  const Line = struct { p1: Point, p2: Point };
  try testMerging(Line{ .p1 = .{ .x = 1, .y = 2 }, .p2 = .{ .x = 3, .y = 4 } });
}

test "enums" {
  // Simple
  const Color = enum { red, green, blue };
  try testMerging(Color.green);
}

test "optional" {
  // value
  var x: ?i32 = 42;
  try testMerging(x);
  x = null;
  try testMerging(x);

  // pointer
  var y: i32 = 123;
  var opt_ptr: ?*i32 = &y;
  try testMerging(opt_ptr);

  opt_ptr = null;
  try testMerging(opt_ptr);
}

test "error_unions" {
  const MyError = error{Oops};
  var eu: MyError!u32 = 123;
  try testMerging(eu);
  eu = MyError.Oops;
  try testMerging(eu);
}

test "unions" {
  const Payload = union(enum) {
    a: u32,
    b: bool,
    c: void,
  };
  try testMerging(Payload{ .a = 99 });
  try testMerging(Payload{ .b = false });
  try testMerging(Payload{ .c = {} });
}

test "complex struct" {
  const Nested = struct {
    c: u4,
    d: bool,
  };

  const KitchenSink = struct {
    a: i32,
    b: []const u8,
    c: [2]Nested,
    d: ?*const i32,
    e: f32,
  };

  var value = KitchenSink{
    .a = -1,
    .b = "dynamic slice",
    .c = .{ .{ .c = 1, .d = true }, .{ .c = 2, .d = false } },
    .d = &@as(i32, 42),
    .e = 3.14,
  };

  try testMerging(value);

  value.b = "";
  try testMerging(value);

  value.d = null;
  try testMerging(value);
}

test "slice of complex structs" {
  const Item = struct {
    id: u64,
    name: []const u8,
    is_active: bool,
  };

  const items = [_]Item{
    .{ .id = 1, .name = "first", .is_active = true },
    .{ .id = 2, .name = "second", .is_active = false },
    .{ .id = 3, .name = "", .is_active = true },
  };

  try testMerging(items[0..]);
}

test "complex composition" {
  const Complex1 = struct {
    a: u32,
    b: u32,
    c: u32,
  };

  const Complex2 = struct {
    a: Complex1,
    b: []const Complex1,
  };

  const SuperComplex = struct {
    a: Complex1,
    b: Complex2,
    c: []const union(enum) {
      a: Complex1,
      b: Complex2,
    },
  };

  const value = SuperComplex{
    .a = .{ .a = 1, .b = 2, .c = 3 },
    .b = .{
      .a = .{ .a = 4, .b = 5, .c = 6 },
      .b = &.{.{ .a = 7, .b = 8, .c = 9 }},
    },
    .c = &.{
      .{ .a = .{ .a = 10, .b = 11, .c = 12 } },
      .{ .b = .{ .a = .{ .a = 13, .b = 14, .c = 15 }, .b = &.{.{ .a = 16, .b = 17, .c = 18 }} } },
    },
  };

  try testMerging(value);
}

test "multiple dynamic fields" {
  const MultiDynamic = struct {
    a: []const u8,
    b: i32,
    c: []const u8,
  };

  var value = MultiDynamic{
    .a = "hello",
    .b = 12345,
    .c = "world",
  };
  try testMerging(value);

  value.a = "";
  try testMerging(value);
}

test "complex array" {
  const Struct = struct {
    a: u8,
    b: u32,
  };
  const value = [2]Struct{
    .{ .a = 1, .b = 100 },
    .{ .a = 2, .b = 200 },
  };

  try testMerging(value);
}

test "packed struct with mixed alignment fields" {
  const MixedPack = packed struct {
    a: u2,
    b: u8,
    c: u32,
    d: bool,
  };

  const value = MixedPack{
    .a = 3,
    .b = 't',
    .c = 1234567,
    .d = true,
  };

  try testMerging(value);
}

test "struct with zero-sized fields" {
  const ZST_1 = struct {
    a: u32,
    b: void,
    c: [0]u8,
    d: []const u8,
    e: bool,
  };
  try testMerging(ZST_1{
    .a = 123,
    .b = {},
    .c = .{},
    .d = "non-zst",
    .e = false,
  });

  const ZST_2 = struct {
    a: u32,
    zst1: void,
    zst_array: [0]u64,
    dynamic_zst_slice: []const void,
    zst_union: union(enum) {
      z: void,
      d: u64,
    },
    e: bool,
  };

  var value_2 = ZST_2{
    .a = 123,
    .zst1 = {},
    .zst_array = .{},
    .dynamic_zst_slice = &.{ {}, {}, {} },
    .zst_union = .{ .z = {} },
    .e = true,
  };

  try testMerging(value_2);

  value_2.zst_union = .{ .d = 999 };
  try testMerging(value_2);
}

test "array of unions with dynamic fields" {
  const Message = union(enum) {
    text: []const u8,
    code: u32,
    err: void,
  };

  const messages = [3]Message{
    .{ .text = "hello" },
    .{ .code = 404 },
    .{ .text = "world" },
  };

  try testMerging(messages);
}

test "pointer and optional abuse" {
  const Point = struct { x: i32, y: i32 };
  const PointerAbuse = struct {
    a: ?*const Point,
    b: *const ?Point,
    c: ?*const ?Point,
    d: []const ?*const ?Point,
  };

  const p1: Point = .{ .x = 1, .y = 1 };
  const p2: ?Point = .{ .x = 2, .y = 2 };
  const p3: ?Point = null;

  const value = PointerAbuse{
    .a = &p1,
    .b = &p2,
    .c = &p2,
    .d = &.{ &p2, null, &p3 },
  };

  try testMerging(value);
}

test "deeply nested struct with one dynamic field at the end" {
  const Level4 = struct {
    data: []const u8,
  };
  const Level3 = struct {
    l4: Level4,
  };
  const Level2 = struct {
    l3: Level3,
    val: u64,
  };
  const Level1 = struct {
    l2: Level2,
  };

  const value = Level1{
    .l2 = .{
      .l3 = .{
        .l4 = .{
          .data = "we need to go deeper",
        },
      },
      .val = 99,
    },
  };
  try testMerging(value);
}

test "slice of structs with dynamic fields" {
  const LogEntry = struct {
    timestamp: u64,
    message: []const u8,
  };
  const entries = [_]LogEntry{
    .{ .timestamp = 1, .message = "first entry" },
    .{ .timestamp = 2, .message = "" },
    .{ .timestamp = 3, .message = "third entry has a much longer message to test buffer allocation" },
  };

  try testMerging(entries[0..]);
}

test "struct with multiple, non-contiguous dynamic fields" {
  const UserProfile = struct {
    username: []const u8,
    user_id: u64,
    bio: []const u8,
    karma: i32,
    avatar_url: []const u8,
  };

  const user = UserProfile{
    .username = "zigger",
    .user_id = 1234,
    .bio = "Loves comptime and robust software.",
    .karma = 9999,
    .avatar_url = "http://ziglang.org/logo.svg",
  };

  try testMerging(user);
}

test "union with multiple dynamic fields" {
  const Packet = union(enum) {
    message: []const u8,
    points: []const struct { x: f32, y: f32 },
    code: u32,
  };

  try testMerging(Packet{ .message = "hello world" });
  try testMerging(Packet{ .points = &.{.{ .x = 1.0, .y = 2.0 }, .{ .x = 3.0, .y = 4.0}} });
  try testMerging(Packet{ .code = 404 });
}

test "advanced zero-sized type handling" {
  const ZstContainer = struct {
    zst1: void,
    zst2: [0]u8,
    data: []const u8, // This is the only thing that should take space
  };
  try testMerging(ZstContainer{ .zst1 = {}, .zst2 = .{}, .data = "hello" });

  const ZstSliceContainer = struct {
    id: u32,
    zst_slice: []const void,
  };

  try testMerging(ZstSliceContainer{ .id = 99, .zst_slice = &.{ {}, {}, {} } });
}

test "deep optional and pointer nesting" {
  const DeepOptional = struct {
    val: ??*const u32,
  };

  const x: u32 = 123;

  // Fully valued
  try testMerging(DeepOptional{ .val = &x });

  // Inner pointer is null
  try testMerging(DeepOptional{ .val = @as(?*const u32, null) });

  // Outer optional is null
  try testMerging(DeepOptional{ .val = @as(??*const u32, null) });
}

test "recursion limit with dereference" {
  const Node = struct {
    payload: u32,
    next: ?*const @This(),
  };

  const n3 = Node{ .payload = 3, .next = null };
  const n2 = Node{ .payload = 2, .next = &n3 };
  const n1 = Node{ .payload = 1, .next = &n2 };

  // This should only serialize n1 and the pointer to n2. 
  // The `write` for n2 will hit the dereference limit and treat it as a direct (raw pointer) value.
  try _testMergingDemerging(n1, .{ .T = Node, .allow_recursive_rereferencing = true });
}

test "recursive type merging" {
  const Node = struct {
    payload: u32,
    next: ?*const @This(),
  };

  const n4 = Node{ .payload = 4, .next = undefined };
  const n3 = Node{ .payload = 3, .next = &n4 };
  const n2 = Node{ .payload = 2, .next = &n3 };
  const n1 = Node{ .payload = 1, .next = &n2 };

  try _testMergingDemerging(n1, .{ .T = Node, .allow_recursive_rereferencing = true  });
}

test "mutual recursion" {
  const Namespace = struct {
    const NodeA = struct {
      name: []const u8,
      b: ?*const NodeB,
    };
    const NodeB = struct {
      value: u32,
      a: ?*const NodeA,
    };
  };

  const NodeA = Namespace.NodeA;
  const NodeB = Namespace.NodeB;

  // Create a linked list: a1 -> b1 -> a2 -> null
  const a2 = NodeA{ .name = "a2", .b = null };
  const b1 = NodeB{ .value = 100, .a = &a2 };
  const a1 = NodeA{ .name = "a1", .b = &b1 };

  try _testMergingDemerging(a1, .{ .T = NodeA, .allow_recursive_rereferencing = true });
}

test "deeply nested, mutually recursive structures with no data cycles" {
  const Namespace = struct {
    const MegaStructureA = struct {
      id: u32,
      description: []const u8,
      next: ?*const @This(), // Direct recursion: A -> A
      child_b: *const NodeB, // Mutual recursion: A -> B
    };

    const NodeB = struct {
      value: f64,
      relatives: [2]?*const @This(), // Direct recursion: B -> [2]B
      next_a: ?*const MegaStructureA, // Mutual recursion: B -> A
      leaf: ?*const LeafNode, // Points to a simple terminal node
    };

    const LeafNode = struct {
      data: []const u8,
    };
  };

  const MegaStructureA = Namespace.MegaStructureA;
  const NodeB = Namespace.NodeB;
  const LeafNode = Namespace.LeafNode;

  const leaf1 = LeafNode{ .data = "Leaf Node One" };
  const leaf2 = LeafNode{ .data = "Leaf Node Two" };

  const b_leaf_1 = NodeB{
    .value = 1.1,
    .next_a = null,
    .relatives = .{ null, null },
    .leaf = &leaf1,
  };
  const b_leaf_2 = NodeB{
    .value = 2.2,
    .next_a = null,
    .relatives = .{ null, null },
    .leaf = &leaf2,
  };

  const a_intermediate = MegaStructureA{
    .id = 100,
    .description = "Intermediate A",
    .next = null, // Terminates this A-chain
    .child_b = &b_leaf_1,
  };

  const b_middle = NodeB{
    .value = 3.3,
    .next_a = &a_intermediate,
    .relatives = .{ &b_leaf_1, &b_leaf_2 },
    .leaf = null,
  };

  const a_before_root = MegaStructureA{
    .id = 200,
    .description = "Almost Root A",
    .next = null,
    .child_b = &b_leaf_2,
  };

  const root_node = MegaStructureA{
    .id = 1,
    .description = "The Root",
    .next = &a_before_root,
    .child_b = &b_middle,
  };

  try _testMergingDemerging(root_node, .{ .T = MegaStructureA, .allow_recursive_rereferencing = true });
}

// ========================================
//                 Wrapper                 
// ========================================


/// A generic wrapper that manages the memory for a merged object.
pub fn WrapConverted(MergedT: type) type {
  const T = MergedT.Signature.T;
  return struct {
    pub const Underlying = MergedT;
    memory: []align(MergedT.Signature.alignment.toByteUnits()) u8,

    /// Returns the total size that would be required to store this value
    /// Expects there to be no data cycles
    pub fn getSize(value: *const T) usize {
      const static_size = MergedT.Signature.static_size;
      return if (@hasDecl(MergedT, "getDynamicSize")) MergedT.getDynamicSize(value, static_size) else static_size;
    }

    /// Allocates memory and merges the initial value into a self-managed buffer.
    /// The Wrapper instance owns the memory and must be de-initialized with `deinit`.
    /// Expects there to be no data cycles
    pub fn init(allocator: std.mem.Allocator, value: *const T) !@This() {
      const memory = try allocator.alignedAlloc(u8, MergedT.Signature.alignment.toByteUnits(), getSize(value));
      var retval: @This() = .{ .memory = memory };
      retval.setAssert(value);
      return retval;
    }

    /// Frees the memory owned by the Wrapper.
    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
      allocator.free(self.memory);
    }

    /// Returns a mutable pointer to the merged data, allowing modification.
    /// The pointer is valid as long as the Wrapper is not de-initialized.
    pub fn get(self: *const @This()) *T {
      return @as(*T, @ptrCast(self.memory.ptr));
    }

    /// Creates a new, independent Wrapper containing a deep copy of the data.
    pub fn clone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
      return try @This().init(allocator, self.get());
    }

    /// Set a new value into the wrapper. Invalidates any references to the old value
    /// Expects there to be no data cycles
    pub fn set(self: *@This(), allocator: std.mem.Allocator, value: *const T) !void {
      const memory = try allocator.realloc(self.memory, getSize(value));
      self.memory = memory;
      return self.setAssert(value);
    }

    /// Set a new value into the wrapper, asserting that underlying allocation can hold it. Invalidates any references to the old value
    /// Expects there to be no data cycles
    pub fn setAssert(self: *@This(), value: *const T) void {
      if (builtin.mode == .Debug) { // debug.assert alone may does not be optimized out
        std.debug.assert(getSize(value) <= self.memory.len);
      }
      const dynamic_buffer = MergedT.Signature.D.init(self.memory[MergedT.Signature.static_size..]).alignForward(.fromByteUnits(MergedT.Signature.D.alignment));
      const written = MergedT.write(value, .initAssert(self.memory[0..MergedT.Signature.static_size]), dynamic_buffer);

      if (builtin.mode == .Debug) {
        std.debug.assert(written + @intFromPtr(dynamic_buffer.ptr) - @intFromPtr(self.memory.ptr) == getSize(value));
      }
    }

    /// Updates the internal pointers within the merged data structure. This is necessary
    /// if the underlying `memory` buffer is moved (e.g., after a memcpy).
    pub fn repointer(self: *@This()) void {
      if (!std.meta.hasFn(MergedT, "getDynamicSize")) return; // Static data, no updation needed

      const static_size = MergedT.Signature.static_size;
      if (static_size == 0) return;

      const dynamic_from = std.mem.alignForward(usize, static_size, MergedT.Signature.D.alignment);
      const written = MergedT.repointer(.initAssert(self.memory[0..static_size]), .initAssert(self.memory[dynamic_from..]));

      if (builtin.mode == .Debug) {
        std.debug.assert(written + dynamic_from == getSize(self.get()));
      }
    }
  };
}

pub fn Wrapper(options: ToMergedOptions) type {
  return WrapConverted(Context.init(options, ToMergedT));
}

// ========================================
//            Wrapper Tests
// ========================================

test "Wrapper init, get, and deinit" {
  const Point = struct { x: i32, y: []const u8 };
  var wrapped_point = try Wrapper(.{ .T = Point }).init(testing.allocator, &.{ .x = 42, .y = "hello" });
  defer wrapped_point.deinit(testing.allocator);

  const p = wrapped_point.get();
  try expectEqual(@as(i32, 42), p.x);
  try std.testing.expectEqualSlices(u8, "hello", p.y);
}

test "Wrapper clone" {
  const Data = struct { id: u32, items: []const u32 };
  var wrapped1 = try Wrapper(.{ .T = Data }).init(testing.allocator, &.{ .id = 1, .items = &.{ 10, 20, 30 } });
  defer wrapped1.deinit(testing.allocator);

  var wrapped2 = try wrapped1.clone(testing.allocator);
  defer wrapped2.deinit(testing.allocator);

  try testing.expect(wrapped1.memory.ptr != wrapped2.memory.ptr);

  const d1 = wrapped1.get();
  const d2 = wrapped2.get();
  try expectEqual(d1.id, d2.id);
  try std.testing.expectEqualSlices(u32, d1.items, d2.items);

  wrapped1.get().id = 99;
  try expectEqual(@as(u32, 99), wrapped1.get().id);
  try expectEqual(@as(u32, 1), wrapped2.get().id);
}

test "Wrapper set" {
  const Data = struct { id: u32, items: []const u32 };
  var wrapped = try Wrapper(.{ .T = Data }).init(testing.allocator, &.{ .id = 1, .items = &.{10} });
  defer wrapped.deinit(testing.allocator);

  // Set to a larger value
  try wrapped.set(testing.allocator, &.{ .id = 2, .items = &.{ 20, 30, 40 } });
  var d = wrapped.get();
  try expectEqual(@as(u32, 2), d.id);
  try std.testing.expectEqualSlices(u32, &.{ 20, 30, 40 }, d.items);
  
  // Set to a smaller value
  try wrapped.set(testing.allocator, &.{ .id = 3, .items = &.{50} });
  d = wrapped.get();
  try expectEqual(@as(u32, 3), d.id);
  try std.testing.expectEqualSlices(u32, &.{50}, d.items);
}

test "Wrapper repointer" {
  const LogEntry = struct {
    timestamp: u64,
    message: []const u8,
  };

  var wrapped = try Wrapper(.{ .T = LogEntry }).init(
    testing.allocator,
    &.{ .timestamp = 12345, .message = "initial message" },
  );
  defer wrapped.deinit(testing.allocator);

  // Manually move the memory to a new buffer (like reading from a file etc.)
  const new_buffer = try testing.allocator.alignedAlloc(u8, @alignOf(@TypeOf(wrapped.memory)), wrapped.memory.len);
  @memcpy(new_buffer, wrapped.memory);
  
  // free the old memory and update the wrapper's memory slice
  testing.allocator.free(wrapped.memory);
  wrapped.memory = new_buffer;

  // internal pointers are now invalid
  wrapped.repointer();

  // Verify that data is correct and pointers are valid
  const entry = wrapped.get();
  try testing.expectEqual(@as(u64, 12345), entry.timestamp);
  try testing.expectEqualSlices(u8, "initial message", entry.message);

  // ensure the slice pointer points inside the *new* buffer
  const memory_start = @intFromPtr(wrapped.memory.ptr);
  const memory_end = memory_start + wrapped.memory.len;
  const slice_start = @intFromPtr(entry.message.ptr);
  const slice_end = slice_start + entry.message.len;
  try testing.expect(slice_start >= memory_start and slice_end <= memory_end);
}

