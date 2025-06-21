const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const meta = @import("meta.zig");

const FnReturnType = meta.FnReturnType;
const native_endian = builtin.cpu.arch.endian();

pub const ToMergedOptions = struct {
  /// The type that is to be merged
  T: type,

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
  /// This effectively creates an array of size n for that type
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
pub fn Bytes(comptime align_hint: std.mem.Alignment) type {
  return struct {
    ptr: [*]align(alignment) u8,
    /// We only use this in debug mode
    _len: if (builtin.mode == .Debug) usize else void,

    const alignment = align_hint.toByteUnits();

    pub fn init(v: []align(alignment) u8) @This() {
      return .{ .ptr = v.ptr, ._len = if (builtin.mode == .Debug) v.len else {} };
    }

    pub fn from(self: @This(), index: usize) @This() {
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
  };
}

/// We take in a type and just use its byte representation to store into bits.
/// Zero-sized types ares supported and take up no space at all
pub fn GetDirectMergedT(T: type, context: Context) type {
  return opaque {
    pub const Signature = MergedSignature{
      .T = T,
      .static_size = @sizeOf(T),
      .alignment = context.align_hint orelse .fromByteUnits(@alignOf(T)),
    };
    const B = Bytes(Signature.alignment);

    pub fn write(val: *const T, static: B, _: void) void {
      if (@bitSizeOf(T) == 0) return;
      @memcpy(static.slice(Signature.static_size), std.mem.asBytes(val.*));
    }

    pub fn read(static: B, _: void) *T {
      return @ptrCast(static.ptr);
    }
  };
}

pub fn GetOnePointerMergedT(T: type, context: Context) !type {
  const pi = @typeInfo(T).pointer;
  std.debug.assert(pi.size == .one);

  var next_options = context.options;
  next_options.dereference -= 1;
  const next_context = context.reop(next_options).see(T);
  if (next_context.times_left == -1) return GetDirectMergedT(T, context);

  const Child = try ToMergedT(pi.child, next_context);

  return opaque {
    const B = Bytes(Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .static_size = Child.Signature.static_size,
      .alignment = context.align_hint orelse .fromByteUnits(@alignOf(T)),
    };

    pub fn write(val: *const T, static: B, dynamic: B) FnReturnType(@TypeOf(Child.write)) {
      return Child.write(val.*, static, dynamic);
    }

    pub const getDynamicSize = if (std.meta.hasFn(Child, "getDynamicSize")) _getDynamicSize else void;
    pub fn _getDynamicSize(val: *const T) usize { return Child.getDynamicSize(val.*); }

    pub const GS = Child.GS;
    pub const read = Child.read;
  };
}

pub fn GetSliceMergedT(T: type, context: Context) !type {
  const pi = @typeInfo(T).pointer;
  std.debug.assert(pi.size == .one);

  var next_options = context.options;
  next_options.deslice -= 1;
  const next_context = context.reop(next_options).realign(.fromByteUnits(pi.alignment)).see(T);
  if (next_context.times_left == -1) return GetDirectMergedT(T, context);
  
  const Static = GetDirectMergedT(T, context);
  const Child = try ToMergedT(pi.child, next_context);
  const SubStatic = !std.meta.hasFn(Child, "getDynamicSize");

  return opaque {
    const S = Bytes(Signature.alignment);
    const D = Bytes(Child.Signature.alignment);
    pub const Signature = MergedSignature{
      .T = T,
      .static_size = Static.Signature.static_size,
      .alignment = Static.Signature.alignment,
    };

    pub fn write(val: *const T, _static: S, _dynamic: D) usize {
      const len = val.*.len;
      var to_write = val.*;
      to_write.ptr = @ptrCast(_dynamic.ptr);
      Static.write(&to_write, _static, undefined);
      if (len == 0) return 0;

      var offset: usize = 0;
      var dwritten: if (SubStatic) void else usize = if (SubStatic) {} else 0;
      const static = _dynamic.till(Child.Signature.static_size * len);
      const dynamic = _dynamic.from(Child.Signature.static_size * len);
      for (0..len) |i| {
        const written = Child.write(&val.*[i], static.from(offset), if (SubStatic) undefined else dynamic.from(dwritten));
        offset += Child.Signature.static_size;
        if (comptime !SubStatic) dwritten += written;
      }

      return offset + if (SubStatic) 0 else dwritten;
    }

    pub fn getDynamicSize(val: *const T) usize {
      if (val.*.len == 0) return 0;
      var retval: usize = Child.Signature.static_size * val.*.len;
      if (!SubStatic) {
        for (val.*) |v| retval += Child.getDynamicSize(&v);
      }
      return retval;
    }

    pub fn read(static: S, _: D) *T {
      return @ptrCast(static.ptr);
    }
  };
}

