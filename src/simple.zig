const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const meta = @import("meta.zig");

const FnReturnType = meta.FnReturnType;
const native_endian = builtin.cpu.arch.endian();

pub const ToMergedOptions = struct {
  /// The type that is to be merged
  T: type,
  /// Recurse into structs and unions
  recurse: comptime_int = 1024,
  /// Error if recurse = 0
  error_on_0_recurse: bool = true,
  /// Whether to dereference pointers or use them by value
  /// Max Number of times dereferencing is allowed.
  /// 0 means no dereferencing is done at all
  dereference: comptime_int = 1024,
  /// Error if dereference = 0
  error_on_0_dereference: bool = true,
  /// What is the maximum number of expansion of slices that can be done
  /// for example in a recursive structure or nested slices
  ///
  /// eg.
  /// If we have [][]u8, and deslice = 1, we will write pointer+size of all the strings in this slice
  /// If we have [][]u8, and deslice = 2, we will write all the characters in this block
  deslice: comptime_int = 1024,
  /// Error if deslice = 0
  error_on_0_deslice: bool = true,
  /// Flatten the self reference pointers in the struct instead of treating them as pointers.
  /// This effectively creates an array of size n for that type.
  /// You should understand its implications before you enable this.
  flatten_self_references: comptime_int = 0,
  /// Allow for recursive re-referencing, eg A has *B, B has *A
  recursive_rereferencing: enum {
    /// Do not allow for recursive re-referencing, will throw compile error if other than top level type references itself
    disallow,
    /// Count A -> B -> A -> B or A -> B -> C -> A -> B -> C as a single flattening, only count top most type
    top_only,
    /// Count A -> B -> C -> A -> B -> C as a 3 flattenings, count reoccurence of all types
    all,
  } = .disallow,
};

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

const Context = struct {
  align_hint: ?std.mem.Alignment,
  seen_types: []const type,
  /// How many more times will are we tried to see already seen type before we have to treat it as raw.
  times_left: usize,
  options: ToMergedOptions,

  pub fn realign(self: @This(), align_hint: ?std.mem.Alignment) @This() {
    return .{
      .align_hint = align_hint,
      .seen_types = self.seen_types,
      .times_left = self.times_left,
      .options = self.options,
    };
  }

  pub fn see(self: @This(), T: type) @This() {
    const at = self.seenAt(T);
    return .{
      .align_hint = self.align_hint,
      .seen_types = self.seen_types ++ [1]type{T},
      .times_left = if (at == .none) self.times_left else switch (self.options.recursive_rereferencing) {
        .disallow => blk: {
          if (at == .sub) {
            @compileError("Recursive re-referencing is disallowed for type " ++ @typeName(T) ++ " as it is not on the top level");
          } else break :blk self.times_left;
        },
        .top_only => if (at == .top) self.times_left - 1 else self.times_left,
        .all => self.times_left - 1,
      },
      .options = self.options,
    };
  }

  fn getChild(T: type) type {
    comptime var t = T;
    while (switch (@typeInfo(t)) {
      .pointer, .optional, .array, .vector => true,
      else => false,
    }) t = std.meta.Child(t);
    return t;
  }

  pub fn seenAt(self: @This(), T: type) enum {none, top, sub} {
    const child = getChild(T);
    if (child == getChild(self.seen_types[self.seen_types.len - 1])) return .none;
    if (child == getChild(self.seen_types[0])) return .top;
    for (1 .. self.seen_types.len) |i| {
      if (child == getChild(self.seen_types[i])) return .sub;
    }
    return .none;
  }

  pub fn reop(self: @This(), options: ToMergedOptions) @This() {
    return .{
      .align_hint = self.align_hint,
      .seen_types = self.seen_types,
      .times_left = self.times_left,
      .options = options,
    };
  }
};

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

    pub fn convertForward(other: anytype) @This() {
      const retval: @This() = .{ .ptr = other.ptr, ._len = other._len };
      return retval.alignForward(.fromByteUnits(other.alignment));
    }
  };
}

/// We take in a type and just use its byte representation to store into bits.
/// Zero-sized types ares supported and take up no space at all
pub fn GetDirectMergedT(T: type, context: Context) type {
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
pub fn GetOnePointerMergedT(T: type, context: Context) type {
  if (context.options.dereference == 0) {
    if (context.options.error_on_0_dereference) {
      @compileError("Cannot dereference type " ++ @typeName(T) ++ " any further as options.dereference is 0");
    } else {
      return GetDirectMergedT(T, context);
    }
  }

  const is_optional = if (@typeInfo(T) == .optional) true else false;
  const pi = @typeInfo(if (is_optional) @typeInfo(T).optional.child else T).pointer;
  std.debug.assert(pi.size == .one);

  var next_options = context.options;
  next_options.dereference -= 1;
  const next_context = context.reop(next_options).see(T);
  if (next_context.times_left == -1) return GetDirectMergedT(T, context);

  const Pointer = GetDirectMergedT(T, context);
  const Child = ToMergedT(pi.child, next_context.realign(.fromByteUnits(pi.alignment)));

  return opaque {
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

      // TODO: Add a function to fix portability issues with pointers
      if (is_optional and val.* == null) return Pointer.write(&@as(T, null), static, undefined);

      const dptr: T = @ptrFromInt(@intFromPtr(_dynamic.ptr));
      std.debug.assert(0 == Pointer.write(&dptr, static, undefined));

      const dynamic = if (is_optional) _dynamic.alignForward(Child.Signature.alignment) else _dynamic;
      const child_static =  dynamic.till(Child.Signature.static_size);
      const child_dynamic = dynamic.from(Child.Signature.static_size).alignForward(.fromByteUnits(Child.Signature.D.alignment));
      const written = Child.write(if (is_optional) val.*.? else val.*, child_static, child_dynamic);

      return Child.Signature.static_size + written;
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      std.debug.assert(std.mem.isAligned(size, Signature.D.alignment));
      if (is_optional and val.* == null) return size;

      var new_size = size + Child.Signature.static_size;
      if (std.meta.hasFn(Child, "getDynamicSize")) {
        new_size = std.mem.alignForward(usize, new_size, Child.Signature.D.alignment);
        new_size = Child.getDynamicSize(if (is_optional) val.*.? else val.*, new_size);
      }

      return new_size;
    }
  };
}

pub fn GetSliceMergedT(T: type, context: Context) type {
  if (context.options.deslice == 0) {
    if (context.options.error_on_0_deslice) {
      @compileError("Cannot deslice type " ++ @typeName(T) ++ " any further as options.deslice is 0");
    }
    return GetDirectMergedT(T, context);
  }

  const pi = @typeInfo(T).pointer;
  std.debug.assert(pi.size == .slice);

  var next_options = context.options;
  next_options.deslice -= 1;
  const next_context = context.reop(next_options).see(T);
  if (next_context.times_left == -1) return GetDirectMergedT(T, context);

  const Slice = GetDirectMergedT(T, context);
  const Child = ToMergedT(pi.child, next_context.realign(.fromByteUnits(pi.alignment)));
  const SubStatic = !std.meta.hasFn(Child, "getDynamicSize");

  return opaque {
    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(Child.Signature.alignment),
      .static_size = Slice.Signature.static_size,
      .alignment = Slice.Signature.alignment,
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(dynamic.ptr), Signature.D.alignment));

      var header_to_write = val.*;
      header_to_write.ptr = @ptrCast(dynamic.ptr);
      std.debug.assert(0 == Slice.write(&header_to_write, static, undefined));

      const len = val.*.len;
      if (len == 0) return 0;

      var child_static = dynamic.till(Child.Signature.static_size * len);
      var child_dynamic = dynamic.from(Child.Signature.static_size * len).alignForward(.fromByteUnits(Child.Signature.D.alignment));

      for (val.*) |*item| {
        if (!SubStatic) child_dynamic = child_dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.write(item, child_static, if (SubStatic) undefined else child_dynamic);
        child_static = child_static.from(Child.Signature.static_size).assertAligned(Child.Signature.alignment);
        if (!SubStatic) child_dynamic = child_dynamic.from(written);
      }

      return @intFromPtr(child_dynamic.ptr) - @intFromPtr(dynamic.ptr);
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      std.debug.assert(std.mem.isAligned(size, Signature.D.alignment));
      var new_size = size + Child.Signature.static_size * val.*.len;

      if (!SubStatic) {
        for (val.*) |*item| {
          new_size = std.mem.alignForward(usize, new_size, Child.Signature.D.alignment);
          new_size = Child.getDynamicSize(item, new_size);
        }
      }

      return new_size;
    }
  };
}

pub fn GetArrayMergedT(T: type, context: Context) type {
  @setEvalBranchQuota(1000_000);
  const ai = @typeInfo(T).array;
  // No need to .see(T) here as the child will handle this anyway and if the array type is repeated, the child will be too.
  const Child = ToMergedT(ai.child, context.realign(null));

  // If the child has no dynamic data, the entire array is static.
  // We can treat it as a direct memory copy.
  if (!std.meta.hasFn(Child, "getDynamicSize")) return GetDirectMergedT(T, context);

  return opaque {
    const S = Bytes(Signature.alignment);

    pub const Signature = MergedSignature{
      .T = T,
      .D = Child.Signature.D,
      .static_size = Child.Signature.static_size * ai.len,
      .alignment = context.align_hint orelse .fromByteUnits(@alignOf(T)),
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      std.debug.assert(std.mem.isAligned(@intFromPtr(dynamic.ptr), Signature.D.alignment));

      var child_static = static.till(Signature.static_size);
      var child_dynamic = dynamic;

      inline for (val) |*item| {
        child_dynamic = child_dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.write(item, child_static, child_dynamic);
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
  };
}

pub fn GetStructMergedT(T: type, context: Context) type {
  @setEvalBranchQuota(1000_000);
  if (context.options.recurse == 0) {
    if (context.options.error_on_0_recurse) {
      @compileError("Cannot recurse into type " ++ @typeName(T) ++ " any further as options.recurse is 0");
    }
    return GetDirectMergedT(T, context);
  }

  const si = @typeInfo(T).@"struct";
  var next_options = context.options;
  next_options.recurse -= 1;
  const next_context = context.reop(next_options).see(T);
  if (next_context.times_left == -1) return GetDirectMergedT(T, context);

  const ProcessedField = struct {
    original: std.builtin.Type.StructField,
    merged: type,
    static_offset: usize,
  };

  const fields = comptime blk: {
    var pfields: [si.fields.len]ProcessedField = undefined;

    for (si.fields, 0..) |f, i| {
      const MergedChild = ToMergedT(f.type, next_context.realign(if (si.layout == .@"packed") .@"1" else .fromByteUnits(f.alignment)));
      pfields[i] = .{
        .original = f,
        .merged = MergedChild,
        .static_offset = @offsetOf(T, f.name),
      };
    }
    break :blk pfields;
  };

  const FirstNonStaticT = comptime blk: {
    for (si.fields, 0..) |f, i| if (std.meta.hasFn(f.type, "getDynamicSize")) break :blk i;
    break :blk si.fields.len;
  };

  if (FirstNonStaticT == si.fields.len) return GetDirectMergedT(T, context);
  if (si.layout == .@"packed") @compileError("Packed structs with dynamic data are not supported");

  return opaque {
    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(fields[FirstNonStaticT].merged.Signature.D.alignment),
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
          dynamic_offset += written + @intFromPtr(misaligned_dynamic.ptr) - @intFromPtr(aligned_dynamic.ptr);
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
  };
}

pub fn GetOptionalMergedT(T: type, context: Context) type {
  const oi = @typeInfo(T).optional;
  if (@typeInfo(oi.child) == .pointer) return GetOnePointerMergedT(T, context);

  const Child = ToMergedT(oi.child, context);
  if (!std.meta.hasFn(Child, "getDynamicSize")) return GetDirectMergedT(T, context);
  const Tag = ToMergedT(bool, context);

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
      const tag_static = static.from(Child.Signature.static_size);
      const child_static = static.till(Child.Signature.static_size);

      if (val.*) |*payload_val| {
        std.debug.assert(0 == Tag.write(&@as(bool, true), tag_static, undefined));
        const aligned_dynamic = dynamic.alignForward(.fromByteUnits(Child.Signature.D.alignment));
        const written = Child.write(payload_val, child_static, aligned_dynamic);
        return written + @intFromPtr(aligned_dynamic.ptr) - @intFromPtr(dynamic.ptr);
      } else {
        std.debug.assert(0 == Tag.write(&@as(bool, false), tag_static, undefined));
        return 0;
      }
    }

    pub fn getDynamicSize(val: *const T, size: usize) usize {
      if (val.*) |*payload_val| {
        size = std.mem.alignForward(usize, size, Tag.Signature.alignment.toByteUnits());
        return Child.getDynamicSize(payload_val, size);
      } else {
        return size;
      }
    }
  };
}

pub fn GetErrorUnionMergedT(T: type, context: Context) type {
  const ei = @typeInfo(T).error_union;
  const Payload = ei.payload;
  const ErrorSet = ei.error_set;
  const ErrorInt = std.meta.Int(.unsigned, @bitSizeOf(ErrorSet));

  const Child = ToMergedT(Payload, context);
  if (!std.meta.hasFn(Child, "getDynamicSize")) return GetDirectMergedT(T, context);
  const Err = ToMergedT(ErrorInt, context);

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
  };
}

pub fn GetUnionMergedT(T: type, context: Context) type {
  if (context.options.recurse == 0) {
    if (context.options.error_on_0_recurse) {
      @compileError("Cannot recurse into type " ++ @typeName(T) ++ " any further as options.recurse is 0");
    }
    return GetDirectMergedT(T, context);
  }

  const ui = @typeInfo(T).@"union";
  if (ui.tag_type == null) {
    @compileError("Cannot merge untagged union " ++ @typeName(T));
  }

  var next_options = context.options;
  next_options.recurse -= 1;
  const next_context = context.reop(next_options).see(T);
  if (next_context.times_left == -1) return GetDirectMergedT(T, context);

  const ProcessedField = struct {
    original: std.builtin.Type.UnionField,
    merged: type,
  };

  const fields = comptime blk: {
    var pfields: [ui.fields.len]ProcessedField = undefined;
    for (ui.fields, 0..) |f, i| {
      if (f.alignment < @alignOf(f.type)) {
        @compileError("Underaligned union fields cause memory corruption!\n"); // https://github.com/ziglang/zig/issues/19404, https://github.com/ziglang/zig/issues/21343
      }
      pfields[i] = .{
        .original = f,
        .merged = ToMergedT(f.type, next_context.realign(.fromByteUnits(f.alignment))),
      };
    }
    break :blk pfields;
  };

  if (comptime blk: {
    for (fields) |f| {
      if (std.meta.hasFn(f.merged, "getDynamicSize")) {
        break :blk false;
      }
    }
    break :blk true;
  }) return GetDirectMergedT(T, context);

  const Tag = ToMergedT(ui.tag_type.?, context.realign(null));
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

  return opaque {
    const S = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .D = Bytes(.@"1"),
      .static_size = std.mem.alignForward(usize, max_child_static_size + Tag.Signature.static_size, alignment.toByteUnits()),
      .alignment = alignment,
    };

    pub fn write(val: *const T, static: S, dynamic: Signature.D) usize {
      std.debug.assert(std.mem.isAligned(@intFromPtr(static.ptr), Signature.alignment.toByteUnits()));
      const active_tag = std.meta.activeTag(val.*);
      if (tag_first) {
        std.debug.assert(0 == Tag.write(&active_tag, static.till(max_child_static_size), undefined));
      } else {
        std.debug.assert(0 == Tag.write(&active_tag, static.from(max_child_static_size), undefined));
      }
      // we dont need to align static again since if the tag is first,
      // it had greater alignment and hence static data is aligned already

      inline for (fields) |f| {
        const field_as_tag = comptime std.meta.stringToEnum(ui.tag_type.?, f.original.name);
        if (field_as_tag == active_tag) {
          const child_static = if (tag_first) static.from(max_child_static_size).assertAligned(f.merged.Signature.alignment)
            else static.till(f.merged.Signature.static_size).assertAligned(f.merged.Signature.alignment);

          if (!std.meta.hasFn(f.merged, "getDynamicSize")) {
            return f.merged.write(&@field(val.*, f.original.name), child_static, undefined);
          } else {
            const aligned_dynamic = dynamic.alignForward(.fromByteUnits(f.merged.Signature.D.alignment));
            const written = f.merged.write(&@field(val.*, f.original.name), child_static, aligned_dynamic);
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
        const field_as_tag = comptime std.meta.stringToEnum(ui.tag_type.?, f.original.name);
        if (field_as_tag == active_tag) {
          if (!std.meta.hasFn(f.merged, "getDynamicSize")) return size;
          const new_size = std.mem.alignForward(usize, size, f.merged.Signature.D.alignment);
          return f.merged.getDynamicSize(&@field(val.*, f.original.name), new_size);
        }
      }
      unreachable;
    }
  };
}

pub fn ToMergedT(T: type, context: Context) type {
  @setEvalBranchQuota(1000_000);
  return switch (@typeInfo(T)) {
    .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal => {
      @compileError("Type '" ++ @tagName(std.meta.activeTag(@typeInfo(T))) ++ "' is not mergeable\n");
    },
    .void, .bool, .int, .float, .vector, .error_set, .null => GetDirectMergedT(T, context),
    .pointer => |pi| switch (pi.size) {
      .many, .c => if (context.options.serialize_unknown_pointer_as_usize) GetDirectMergedT(T, context) else {
        @compileError(@tagName(pi.size) ++ " pointer cannot be serialized for type " ++ @typeName(T) ++ ", consider setting serialize_many_pointer_as_usize to true\n");
      },
      .one => GetOnePointerMergedT(T, context),
      .slice => GetSliceMergedT(T, context),
    },
    .array => GetArrayMergedT(T, context),
    .@"struct" => GetStructMergedT(T, context),
    .optional => GetOptionalMergedT(T, context),
    .error_union => GetErrorUnionMergedT(T, context),
    .@"enum" => GetDirectMergedT(T, context),
    .@"union" => GetUnionMergedT(T, context),
    .@"opaque" => if (@hasDecl(T, "Signature") and @hasField(T.Signature, "T") and @FieldType(T.Signature, "T") == type) T else {
      @compileError("A non-mergeable opaque " ++ @typeName(T) ++ " was provided to `ToMergedT`\n");
    },
  };
}

// ========================================
//                 Testing
// ========================================

const testing = std.testing;

fn expectEqual(expected: anytype, actual: anytype) !void {
  const print = std.debug.print;

  switch (@typeInfo(@TypeOf(actual))) {
    .noreturn, .@"opaque", .frame, .@"anyframe", => @compileError("value of type " ++ @typeName(@TypeOf(actual)) ++ " encountered"),

    .void => return,

    .type => {
      if (actual != expected) {
        print("expected type {s}, found type {s}\n", .{ @typeName(expected), @typeName(actual) });
        return error.TestExpectedEqual;
      }
    },

    .bool, .int, .float, .comptime_float, .comptime_int, .enum_literal, .@"enum", .@"fn", .error_set => {
      if (actual != expected) {
        print("expected {}, found {}\n", .{ expected, actual });
        return error.TestExpectedEqual;
      }
    },

    .pointer => |pointer| {
      switch (pointer.size) {
        .one, .many, .c => {
          if (actual == expected) return;
          return expectEqual(actual.*, expected.*);
        },
        .slice => {
          if (actual.len != expected.len) {
            print("expected slice len {}, found {}\n", .{ expected.len, actual.len });
            return error.TestExpectedEqual;
          }
          if (actual.ptr == expected.ptr) return;
          for (actual, expected, 0..) |va, ve, i| {
            expectEqual(va, ve) catch |e| {
              print("index {d} incorrect. expected {any}, found {any}\n", .{ i, expected[i], actual[i] });
              return e;
            };
          }
        },
      }
    },

    .array => |array| {
      inline for (0..array.len) |i| {
        expectEqual(expected[i], actual[i]) catch |e| {
          print("index {d} incorrect. expected {any}, found {any}\n", .{ i, expected[i], actual[i] });
          return e;
        };
      }
    },

    .vector => |info| {
      var i: usize = 0;
      while (i < info.len) : (i += 1) {
        if (!std.meta.eql(expected[i], actual[i])) {
          print("index {d} incorrect. expected {any}, found {any}\n", .{ i, expected[i], actual[i] });
          return error.TestExpectedEqual;
        }
      }
    },

    .@"struct" => |structType| {
      inline for (structType.fields) |field| {
        try expectEqual(@field(expected, field.name), @field(actual, field.name));
      }
    },

    .@"union" => |union_info| {
      if (union_info.tag_type == null) @compileError("Unable to compare untagged union values for type " ++ @typeName(@TypeOf(actual)));
      const Tag = std.meta.Tag(@TypeOf(expected));
      const expectedTag = @as(Tag, expected);
      const actualTag = @as(Tag, actual);

      try expectEqual(expectedTag, actualTag);

      switch (expected) {
        inline else => |val, tag| try expectEqual(val, @field(actual, @tagName(tag))),
      }
    },

    .optional => {
      if (expected) |expected_payload| {
        if (actual) |actual_payload| {
          try expectEqual(expected_payload, actual_payload);
        } else {
          print("expected {any}, found null\n", .{expected_payload});
          return error.TestExpectedEqual;
        }
      } else {
        if (actual) |actual_payload| {
          print("expected null, found {any}\n", .{actual_payload});
          return error.TestExpectedEqual;
        }
      }
    },

    .error_union => {
      if (expected) |expected_payload| {
        if (actual) |actual_payload| {
          try expectEqual(expected_payload, actual_payload);
        } else |actual_err| {
          print("expected {any}, found {}\n", .{ expected_payload, actual_err });
          return error.TestExpectedEqual;
        }
      } else |expected_err| {
        if (actual) |actual_payload| {
          print("expected {}, found {any}\n", .{ expected_err, actual_payload });
          return error.TestExpectedEqual;
        } else |actual_err| {
          try expectEqual(expected_err, actual_err);
        }
      }
    },

    else => @compileError("Unsupported type in expectEqual: " ++ @typeName(@TypeOf(expected))),
  }
}

fn _testMergingDemerging(value: anytype, comptime options: ToMergedOptions) !void {
  const T = @TypeOf(value);
  const MergedT = ToMergedT(T, .{
    .align_hint = null,
    .seen_types = &.{T},
    .times_left = options.flatten_self_references,
    .options = options,
  });

  const static_size = MergedT.Signature.static_size;
  var static_buffer: [static_size]u8 = undefined;

  const dynamic_size = if (std.meta.hasFn(MergedT, "getDynamicSize")) MergedT.getDynamicSize(&value, 0) else 0;
  var dynamic_buffer: [4096]u8 = undefined;
  if (dynamic_size > dynamic_buffer.len) {
    std.log.err("dynamic buffer too small for test. need {d}, have {d}", .{ dynamic_size, dynamic_buffer.len });
    return error.NoSpaceLeft;
  }

  const written_dynamic_size = MergedT.write(&value, .initAssert(&static_buffer), .initAssert(&dynamic_buffer));

  std.debug.assert(written_dynamic_size == dynamic_size);
  try expectEqual(&value, @as(*@TypeOf(value), @ptrFromInt(@intFromPtr(&static_buffer))));
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
  try _testMergingDemerging(&x, .{ .T = *u64, .dereference = 0, .error_on_0_dereference = false });
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

// test "recursion limit with dereference" {
//   const Node = struct {
//     payload: u32,
//     next: ?*const @This(),
//   };
//
//   const n3 = Node{ .payload = 3, .next = null };
//   const n2 = Node{ .payload = 2, .next = &n3 };
//   const n1 = Node{ .payload = 1, .next = &n2 };
//
//   // This should only serialize n1 and the pointer to n2. 
//   // The `write` for n2 will hit the dereference limit and treat it as a direct (raw pointer) value.
//   try _testMergingDemerging(n1, .{ .T = Node, .dereference = 1 });
// }
//
// test "recursive type merging" {
//   const Node = struct {
//     payload: u32,
//     next: ?*const @This(),
//   };
//
//   const n4 = Node{ .payload = 4, .next = undefined };
//   const n3 = Node{ .payload = 3, .next = &n4 };
//   const n2 = Node{ .payload = 2, .next = &n3 };
//   const n1 = Node{ .payload = 1, .next = &n2 };
//
//   try _testMergingDemerging(n1, .{ .T = Node, .flatten_self_references = 4 });
// }
//
// test "mutual recursion with flatten_self_references" {
//   const Namespace = struct {
//     const NodeA = struct {
//       name: []const u8,
//       b: ?*const NodeB,
//     };
//     const NodeB = struct {
//       value: u32,
//       a: ?*const NodeA,
//     };
//   };
//
//   const NodeA = Namespace.NodeA;
//   const NodeB = Namespace.NodeB;
//
//   // Create a linked list: a1 -> b1 -> a2 -> null
//   const a2 = NodeA{ .name = "a2", .b = null };
//   const b1 = NodeB{ .value = 100, .a = &a2 };
//   const a1 = NodeA{ .name = "a1", .b = &b1 };
//
//   // Default behavior, does not flatten.
//   try _testMergingDemerging(a1, .{ .T = NodeA });
//
//   // Flatten the recursion once.
//   try _testMergingDemerging(a1, .{ .T = NodeA, .flatten_self_references = 1, .recursive_rereferencing = .top_only });
// }

