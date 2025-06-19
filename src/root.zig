const std = @import("std");
pub const meta = @import("meta.zig");
pub const serializer = @import("serializer.zig");

/// Control how serialization of the type is done
pub const ToSerializableOptions = struct {
  /// The type that is to be deserialized
  T: type,
  /// Control how value bytes are serialized
  serialization: SerializationOptions = .default,
  /// If int is supplied, this does nothing at all if enum supplied is non-exhaustive
  /// and smallest int needed to represent all of its fields is smaller then one used,
  /// the enum fields will be remapped to optimize for size
  /// keys.get will still give the original value as a result
  ///
  /// WARNING: This internally generates a mapping from Enum's integer value to index in the enum's fields
  ///   which adds a linear time complexity on every enum assignment
  ///   You should ideally use, `GetShrunkEnumType(enumtype)` instead of original enumtype for optimality
  shrink_enum: bool = false,
  /// If set to true, serialize a Many / C / anyopaque pointer as a uint, otherwise throw a compileError
  serialize_unknown_pointer_as_usize: bool = false,
  /// Type given to the `len` argument of slices.
  /// NOTE: It is useless to change this unless you are using non-default serialization as well
  ///   Your choice will still be respected though
  dynamic_len_type: type = usize,
  /// Make all the sub structs `Serializable` as well with the same config if they are not already
  /// If this is 0, Sub structs / unions / error!unions / ?optional (even ?*optional_pointer) won't be analyzed,
  ///   Their serializer will write just their raw bytes and nothing else
  /// A reasonably large number is chosen as a default
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

  pub const SerializationOptions = enum {
    ///stuffs together like in packed struct, 2 u22's take up 44 bits
    pack,
    /// remove alignment when packing, 2 u22's take up 2 * 24 = 48 bits
    noalign,
    /// do not remove padding, 2 u22's will take up 2 * 32 = 64 bits
    default,
  };
};

/// Convert any type to a serializable type, any unsupported types present in the struct will result in a compile error.
/// Be careful with options when using recursive structs, You will likely need to turn off (or atleast limit) options.dereference
pub fn ToSerializable(options: ToSerializableOptions) type {
  return serializer.ToSerializableT(options.T, options, null) catch |e|
    @compileError(std.fmt.comptimePrint("Error: {!} while serializing {s}", .{e, @typeName(options.T)}));
}

