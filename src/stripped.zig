const std = @import("std");
const builtin = @import("builtin");
const meta = @import("meta.zig");
const simple = @import("simple.zig");

const Bytes = meta.Bytes;
pub const Context = meta.GetContext(ToMergedOptions);

pub const MergedSignature = simple.MergedSignature;

/// Options to control how the merging of a type is performed.
pub const ToMergedOptions = struct {
  /// The type that is to be merged.
  T: type,
  /// Recurse into structs and unions.
  recurse: bool = true,
  /// Whether to dereference pointers or use them by value.
  dereference: bool = true,
  /// What is the maximum number of times a slice can be de-sliced.
  deslice: comptime_int = 1024,
  /// Allow for recursive re-referencing (e.g., `*Node` inside `Node`).
  /// When this is false and the type is recursive, compilation will error.
  allow_recursive_rereferencing: bool = false,
};

pub const GetDirectMergedT = simple.GetDirectMergedT;
pub const GetErrorUnionMergedT = simple.GetErrorUnionMergedT;
pub const GetOptionalMergedT = simple.GetOptionalMergedT;
pub const GetUnionMergedT = simple.GetUnionMergedT;

pub fn GetOnePointerMergedT(context: Context) type {
}

pub fn GetSliceMergedT(context: Context) type {
}

pub fn GetArrayMergedT(context: Context) type {
}

pub fn GetStructMergedT(context: Context) type {
}

pub fn ToMergedT(context: Context) type {
  const T = context.options.T;
  @setEvalBranchQuota(1000_000);
  return switch (@typeInfo(T)) {
    .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal, .@"opaque" => {
      @compileError("Type '" ++ @tagName(std.meta.activeTag(@typeInfo(T))) ++ "' is not mergeable\n");
    },
    .void, .bool, .int, .float, .vector, .error_set, .null => GetDirectMergedT(context),
    .pointer => |pi| switch (pi.size) {
      .many, .c => if (context.options.serialize_unknown_pointer_as_usize) GetDirectMergedT(context) else {
        @compileError(@tagName(pi.size) ++ " pointer cannot be serialized for type " ++ @typeName(T) ++ ", consider setting serialize_many_pointer_as_usize to true\n");
      },
      .one => switch (@typeInfo(pi.child)) {
        .@"opaque" => if (@hasDecl(pi.child, "Signature") and @hasField(pi.child.Signature, "T") and @FieldType(pi.child.Signature, "T") == type) T else {
          @compileError("A non-mergeable opaque " ++ @typeName(pi.child) ++ " was provided to `ToMergedT`\n");
        },
        else => GetOnePointerMergedT(context),
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
        .one => GetOnePointerMergedT(context),
        .slice => GetSliceMergedT(context),
      },
      else => GetOptionalMergedT(context),
    },
    .error_union => GetErrorUnionMergedT(context),
    .@"enum" => GetDirectMergedT(context),
    .@"union" => GetUnionMergedT(context),
  };
}

