const std = @import("std");
const builtin = @import("builtin");

const native_endian = builtin.cpu.arch.endian();

/// Given a function type, get the return type
fn FnReturnType(T: type) type {
  return switch (@typeInfo(T)) {
    .@"fn" => |info| info.return_type.?,
    else => @compileError("Expected function type, got " ++ @typeName(T)),
  };
}

/// This is used to recognize if types were rFneturned by ToSerializable.
/// This is done by assigning `pub const Signature = SerializableSignature;` inside an opaque
pub const SerializableSignature = struct {
  /// The underlying type that was transformed (to down)
  T: type,
  /// The transformed type going from bottom up. This may be (not always) same as T on a terminal node
  U: type,
  /// The type used for storing dynamic data, this is the type returned after calling `getDynamicData`
  DD: type,
  /// Static size (in bits if pack, in bytes if default/noalign)
  static_size: comptime_int,
  /// Always one in case noalign is chosen
  alignment: std.mem.Alignment,

  pub const IntegerTypeType = struct {
    /// Bitlen of the int type
    len: comptime_int,
    /// Static multiplier (in bits if pack, in bytes if default/noalign)
    multiplier: comptime_int,
  };

  pub const EmptyDD = struct {};
};

/// Control how serialization of the type is done
pub const ToSerializableOptions = struct {
  /// The type that is to be deserialized
  T: type,
  /// Control how value bytes are serialized
  serialization: SerializationOptions = .default,
  /// Type given to the `len` argument of slices
  slice_len_type: type = usize,
  /// If int is supplied, this does nothing at all. If enum supplied is non-exhaustive
  /// and smallest int needed to represent all of its fields is smaller then one used,
  /// the enum fields will be remapped to optimize for size
  /// keys.get will still give the original value as a result
  ///
  /// Recommended to keep on
  shrink_enum: bool = true,
  /// Split and reserialize array values according to serialization. This does nothing if it doesn't have to.
  /// This has no effect with serialization = .default or if array elements have no padding after serialization.
  reserialize_array: bool = true,
  /// Make all the sub structs `Serializable` as well with the same config if they are not already
  /// If this is 0, no recursion is done at all
  recurse: comptime_int = 0,
  /// Error if recurse = 0
  error_on_0_recurse: bool = false,
  /// Weather to dereference pointers or use them by value
  /// Max Number of times dereferencing is allowed.
  /// 0 means no dereferencing is done at all
  dereference: comptime_int = 0,
  /// Error if dereference = 0
  error_on_0_dereference: bool = false,
  /// What is the maximum number of expansion of slices that can be done
  /// for example in a recursive structure or nested slices
  ///
  /// eg.
  /// If we have [][]u8, and deslice = 1, we will write pointer+size of all the strings in this slice
  /// If we have [][]u8, and deslice = 2, we will write all the characters in this block
  deslice: comptime_int = 1,
  /// Error if deslice = 0
  error_on_0_deslice: bool = false,
  /// How many times can the nested struct be de-nested. Denesting includes dereferencing, and dearraying.
  /// This has no effect if the struct is non-recursive
  denest: comptime_int = 0,
  /// Optionals take less space when they are null but you can't change their value after initialization
  /// Has effect only if optional's size > child size (has no effect on pointers for example)
  dynamic_optionals: bool = false,
  /// Unions take less space when a smaller than maximum sized union is selected, you cant change their value after initialization
  /// This has no effect if the union is not tagged or has equal sized options
  dynamic_unions: bool = false,
  /// If set to true, serialize a Many / C pointer as a uint, otherwise throw a compileError
  serialize_many_pointer_as_usize: bool = true,

  pub const SerializationOptions = enum {
    ///stuffs together like in packed struct, 2 u22's take up 44 bits
    pack,
    /// remove alignment when packing, 2 u22's take up 2 * 24 = 48 bits
    noalign,
    /// do not remove padding, 2 u22's will take up 2 * 32 = 64 bits
    default,
  };
};

/// We take in a type and just use its byte representation to store into bits.
/// No dereferencing is done for pointers, and voids dont take up any space at all
fn GetDirectSerializableT(T: type, options: ToSerializableOptions, align_hint: ?std.mem.Alignment) type {
  return opaque {
    const I = std.meta.Int(.unsigned, Signature.static_size);
    pub const Signature = SerializableSignature{
      .T = T,
      .U = T,
      .DD = Signature.EmptyDD,
      .static_size = switch (options.serialization) {
        .default => @sizeOf(T),
        .noalign => std.math.divCeil(comptime_int, @bitSizeOf(T), 8),
        .pack => @bitSizeOf(T),
      },
      .alignment = if (options.serialization == .default) align_hint orelse .fromByteUnits(@alignOf(T)) else .@"1",
    };

    /// `bytes` should always have enough bytes/bits.
    /// This MUST write exactly `Signature.static_size` bits if Signature.serialization == .packed / bytes otherwise
    /// offset is always 0 unless packed is used
    pub fn writeStatic(val: *const T, bytes: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0) void {
      if (I == u0) return;
      switch (comptime options.serialization) {
        .default, .noalign => bytes[0..Signature.static_size].* = @as(I, @bitCast(val.*)),
        .pack => std.mem.writePackedInt(I, bytes, offset, @as(I, @bitCast(val.*)), native_endian),
      }
    }

    /// This type has no dynamic data
    pub fn getDynamicData(_: *const T) Signature.DD {
      return .{};
    }

    pub fn read(static: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0, _: Signature.DD) T {
      if (I == u0) return;
      return @bitCast(switch (options.serialization) {
        .default, .noalign => std.mem.readInt(I, static[0..Signature.static_size], native_endian),
        .pack => std.mem.readPackedInt(I, static, offset, native_endian),
      });
    }
  };
}

fn GetSerializablePointer(Child: type, options: ToSerializableOptions) type {
  _ = .{ Child, options };
  return opaque {

  };
}

fn GetSerializableSlice(Child: type, options: ToSerializableOptions) type {
  _ = .{ Child, options };
  return opaque {

  };
}

/// Shrink the enum type, if return type of this function is used, enum is guaranteed to not be shrunk (it is already shrunk)
/// You can get the original enum value using `@enumFromInt(@typeInfo(OriginalEnumType).@"enum".fields[@intFromEnum(val)])`
pub fn GetShrunkEnumType(T: type) type {
  const ei = @typeInfo(T).@"enum";
  const min_bits = std.math.log2_int_ceil(usize, ei.fields.len);
  const TagType = std.meta.Int(.unsigned, min_bits);

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

// const CanSerializeResult = enum {
//   /// type can definitely be serialized
//   yes,
//   /// Type may be serializable
//   maybe,
//   /// Type is non serializable
//   no,
//   /// Cant deserialize due to depth limitations
//   depth_exceeded,
// };
// pub fn canSerialize(T: type, options: ToSerializableOptions) CanSerializeResult {
//   switch (@typeInfo(T)) {
//     .type, .noreturn, .comptime_int, .comptime_float, .undefined, .null, .error_set, .@"fn", .frame, .@"anyframe", .enum_literal => .no,
//     .void, .bool, .int, .float, .vector => .yes,
//     .pointer => |pi| switch (pi) {
//       .one, .slice => .maybe,
//       .many, .c => if (options.serialize_many_pointer_as_usize) .yes else .no,
//     },
//     else => true
//   }
// }

/// We return an error instead of calling @compileError directly because we want to give the user a stacktrace
fn ToSerializableT(T: type, options: ToSerializableOptions, align_hint: ?std.mem.Alignment) anyerror!type {
  return switch (@typeInfo(T)) {
    .type, .noreturn, .comptime_int, .comptime_float, .undefined, .null, .error_set, .@"fn", .frame, .@"anyframe", .enum_literal => blk: {
      @compileLog("Type '" ++ @tagName(std.meta.activeTag(@typeInfo(T))) ++ "' is non serializable\n");
      break :blk error.NonSerializableType;
    },
    .void, .bool, .int, .float, .vector => GetDirectSerializableT(T, options),
    .pointer => |pi| if (options.dereference == 0) GetDirectSerializableT(T, options) else switch (pi.size) {
      .many, .c => if (options.serialize_many_pointer_as_usize) GetDirectSerializableT(T, options) else blk: {
        @compileLog(@tagName(pi.size) ++ " pointer cannot be serialized for type " ++ @typeName(T) ++ ", consider setting serialize_many_pointer_as_usize to true\n");
        break :blk error.NonSerializablePointerType;
      },
      .one => blk: {
        if (options.dereference == 0) {
          if (options.error_on_0_dereference) {
            @compileLog("Cannot dereference type " ++ @typeName(T) ++ " any further as options.dereference is 0\n");
            break :blk error.ErrorOn0Dereference;
          }
        }
        comptime var next_op = options;
        next_op.dereference -= 1;
        break :blk GetSerializablePointer(pi.child, next_op);
      },
      .slice => blk: {
        if (options.deslice == 0) {
          if (options.error_on_0_deslice) {
            @compileLog("Cannot deslice type " ++ @typeName(T) ++ " any further as options.dereference is 0\n");
            break :blk error.ErrorOn0Dereference;
          }
        }
        comptime var next_op = options;
        next_op.deslice -= 1;
        break :blk GetSerializableSlice(pi.child, next_op);
      },
    },
    .array => |ai| opaque {
      const U = ToSerializableOptions(ai.child, options, if (align_hint) |hint| .fromByteUnits(@min(@alignOf(ai.child), hint.toByteUnits())) else null);

      pub const Signature = SerializableSignature{
        .T = T,
        .U = [ai.len]U,
        .DD = [ai.len]U.Signature.DD,
        .static_size = switch (options.serialization) {
          .default => @sizeOf(T),
          .noalign => std.math.divCeil(comptime_int, @bitSizeOf(ai.child), 8) * ai.len,
          .pack => @bitSizeOf(ai.child) * ai.len,
        },
        .alignment = if (options.serialization == .default) .fromByteUnits(@alignOf(T)) else .@"1",
      };

      const I = std.meta.Int(.unsigned, Signature.static_size);

      /// `bytes` should always have enough bytes/bits.
      /// This MUST write exactly `Signature.static_size` bits if Signature.serialization == .packed / bytes otherwise
      /// offset is always 0 unless packed is used
      pub fn writeStatic(val: *const T, _bytes: []align(Signature.alignment.toByteUnits()) u8, _offset: if (options.serialization == .pack) u3 else u0) void {
        var bytes = _bytes;
        var offset = _offset;
        inline for (0..ai.len) |i| {
          U.writeStatic(&val[i], bytes, offset);
          switch (comptime options.serialization) {
            .default, .noalign => bytes = bytes[Signature.static_size..],
            .pack => {
              const new_offset = Signature.static_size + offset;
              bytes = bytes[new_offset >> 3];
              offset = new_offset & 0b111;
            }
          }
        }
      }

      /// This type has no dynamic data
      pub fn getDynamicData(val: *const T) Signature.DD {
        var retval: Signature.DD = undefined;
        inline for (0..ai.len) |i| @field(retval, std.fmt.comptimePrint(i)) = U.getDynamicData(&val[i]);
        return retval;
      }

      pub const ArrayIterator = struct {
        static: []align(Signature.alignment.toByteUnits()) u8,
        offset: if (options.serialization == .pack) u3 else u0 = 0,
        da: Signature.DD,

        pub fn get(self: @This(), i: std.math.IntFittingRange(0, ai.len)) U {
          return switch (options.serialization) {
            .default, .noalign => U.read(self.static[i * Signature.static_size..], self.offset, self.da),
            .pack => U.read(self.static[i * (Signature.static_size >> 3) + ((i * (Signature.static_size & 7)) >> 3)..], (i * (Signature.static_size & 7)) & 7, self.da),
          };
        }
      };

      /// If you are calling from the top level, `offset` will be 0
      pub fn read(static: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0, da: Signature.DD) ArrayIterator {
        return .{ .static = static, .offset = offset, .da = da, };
      }
    },
    .@"struct" => opaque {
    },
    .optional => opaque {},
    .error_union => opaque {},
    .@"enum" => |ei| opaque {
      const min_bits = std.math.log2_int_ceil(usize, ei.fields.len);
      /// If this is true, EnumType is the shrunk enum type, else it is same as Signature.T
      pub const IsShrunkEnum = options.shrink_enum and @bitSizeOf(T) > min_bits and !ei.is_exhaustive;
      const EnumType = if (IsShrunkEnum) GetShrunkEnumType(T) else T;
      const TagType = @typeInfo(Signature.U).@"enum".tag_type;
      const Direct = GetDirectSerializableT(Signature.U, options, align_hint);

      pub const Signature = SerializableSignature{
        .T = T,
        .U = EnumType,
        .DD = Direct.Signature.DD,
        .static_size = Direct.Signature.static_size,
        .alignment = Direct.Signature.alignment,
      };


      /// `bytes` should always have enough bytes/bits.
      /// This MUST write exactly `Signature.static_size` bits if Signature.serialization == .packed / bytes otherwise
      /// offset is always 0 unless packed is used
      pub fn writeStatic(val: *const T, bytes: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0) void {
        if (min_bits == 0) return;
        if (!IsShrunkEnum) return Direct.writeStatic(@ptrCast(val), bytes, offset);

        const OGTT = ei.tag_type;
        const array: []const OGTT = comptime blk: {
          var retval: []const OGTT = &.{};
          for (ei.fields, 0..) |f, i| retval[i] = f.value;
          break :blk retval;
        };

        for (0..ei.fields.len) |i| {
          if (array[i] == @intFromEnum(val.*)) {
            const int: TagType = @intCast(i);
            return Direct.writeStatic(&int, bytes, offset);
          }
        }
      }

      /// This type has no dynamic data
      pub const getDynamicData = Direct.getDynamicData;

      /// The return value can be Converted to original enum type using
      pub fn read(static: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0, _: Signature.DD) Signature.U {
        if (min_bits == 0) return @enumFromInt(0);
        return @enumFromInt(switch (options.serialization) {
          .default, .noalign => std.mem.readInt(TagType, static[0..Signature.static_size], native_endian),
          .pack => std.mem.readPackedInt(TagType, static, offset, native_endian),
        });
      }

      /// Convert the given value to original type, this is a no-op if enum is not a shrunk_enum
      pub fn toOriginalT(val: Signature.U) T {
        return if (!IsShrunkEnum) val else @enumFromInt(@typeInfo(T).@"enum".fields[@intFromEnum(val)]);
      }
    },
    .@"union" => {},
    .@"opaque" => if (@hasDecl(T, "Signature") and @TypeOf(@field(T, "Signature")) == SerializableSignature) T else blk: {
      @compileLog("A non-serializable opaque " ++ @typeName(T) ++ " was provided to `ToSerializableT`\n");
      break :blk error.NonSerializableOpaque;
    },
  };
}

/// Convert any type to a serializable type, any unsupported types present in the struct will result in 
/// Be careful with this option when using recursive structs
pub fn ToSerializable(options: ToSerializableOptions) type {
  return ToSerializableT(options.T, options) catch |e| @compileError(std.fmt.comptimePrint("Error: {!} while serializing {s}", .{e, @typeName(options.T)}));
}

