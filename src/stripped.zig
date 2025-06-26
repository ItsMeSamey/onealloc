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

