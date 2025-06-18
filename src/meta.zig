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
  /// Static size (in bits if pack, in bytes if default/noalign)
  static_size: comptime_int,
  /// Always .@"1" unless .default is used
  alignment: std.mem.Alignment,

  pub const IntegerTypeType = struct {
    /// Bitlen of the int type
    len: comptime_int,
    /// Static multiplier (in bits if pack, in bytes if default/noalign)
    multiplier: comptime_int,
  };
};

pub const GetterSignature = struct {};

/// Control how serialization of the type is done
pub const ToSerializableOptions = struct {
  /// The type that is to be deserialized
  T: type,
  /// Control how value bytes are serialized
  serialization: SerializationOptions = .default,
  /// It is highly recommended to keep this on unless you have a REALLY good reason to turn it off
  sort_fields: bool = true,
  /// If int is supplied, this does nothing at all. If enum supplied is non-exhaustive
  /// and smallest int needed to represent all of its fields is smaller then one used,
  /// the enum fields will be remapped to optimize for size
  /// keys.get will still give the original value as a result
  ///
  /// NOTE: You should ideally use, `GetShrunkEnumType` function when declaring structs themselves
  ///   because this has a runtime cost
  shrink_enum: bool = true,
  /// If set to true, serialize a Many / C / anyopaque pointer as a uint, otherwise throw a compileError
  serialize_unknown_pointer_as_usize: bool = true,
  /// Type given to the `len` argument of slices.
  /// NOTE: It is useless to change this unless you are using non-default serialization as well
  ///   Your choice will still be respected though
  slice_len_type: type = usize,
  /// Make all the sub structs `Serializable` as well with the same config if they are not already
  /// If this is 0, Sub structs / unions / error!unions / ?optional (even ?*optional_pointer) won't be analyzed,
  ///   Their serializer will write just their raw bytes and nothing else
  /// A reasonably large number is chosen as a default
  recurse: comptime_int = 1024,
  /// Error if recurse = 0
  error_on_0_recurse: bool = true,
  /// Weather to dereference pointers or use them by value
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

/// We take in a type and just use its byte representation to store into bits.
/// No dereferencing is done for pointers, and voids dont take up any space at all
fn GetDirectSerializableT(T: type, options: ToSerializableOptions, align_hint: ?std.mem.Alignment) type {
  return opaque {
    const I = std.meta.Int(.unsigned, Signature.static_size);
    pub const IsSameOld = true;
    pub const Signature = SerializableSignature{
      .T = T,
      .U = T,
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
    pub fn writeStatic(val: *const T, bytes: []u8, offset: if (options.serialization == .pack) u3 else u0) void {
      if (I == u0) return;
      switch (comptime options.serialization) {
        .default, .noalign => bytes[0..Signature.static_size].* = std.mem.toBytes(@as(I, @bitCast(val.*)))[0..Signature.static_size].*,
        .pack => std.mem.writePackedInt(I, bytes, offset, @as(I, @bitCast(val.*)), native_endian),
      }
    }

    pub fn read(static: []const u8, offset: if (options.serialization == .pack) u3 else u0, _: []const u8) Signature.U {
      if (I == u0) return @bitCast(undefined);
      return @bitCast(switch (comptime options.serialization) {
        .default, .noalign => std.mem.readInt(I, static[0..Signature.static_size], native_endian),
        .pack => std.mem.readPackedInt(I, static, offset, native_endian),
      });
    }
  };
}

fn GetSortedFields(fields: anytype, options: ToSerializableOptions) !@TypeOf(fields) {
  const FieldType = std.meta.Child(@TypeOf(fields));
  var fields_array: [fields.len]FieldType = fields[0..fields.len].*;
  for (fields_array) |*f| {
    f.type = try ToSerializableT(f.type, init: {
      var retval = options;
      retval.recurse -= 1;
      break :init retval;
    }, f.alignment);

    switch (options.serialization) {
      .default => {},
      .noalign => f.alignment = 1,
      .pack => f.alignment = 0,
    }
  }

  if (!options.sort_fields) return &fields_array;

  std.sort.block(std.builtin.Type.StructField, &fields_array, void, struct{
    /// Rhs and Lhs are reversed because we want to sort in reverse order
    fn inner(_: void, rhs: std.builtin.Type.StructField, lhs: std.builtin.Type.StructField) bool {
      return switch (options.serialization) {
        .default => if (lhs.alignment < rhs.alignment) true
          else lhs.type.Signature.static_size < rhs.type.Signature.static_size,
        .noalign, .pack => if (lhs.type.Signature.static_size == 0) rhs.type.Signature.static_size != 0
          else if (@ctz(lhs.type.Signature.static_size) < @ctz(rhs.type.Signature.static_size)) true
          else lhs.type.Signature.static_size < rhs.type.Signature.static_size,
      };
    }
  }.inner);

  return &fields_array;
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

/// We return an error instead of calling @compileError directly because we want to give the user a stacktrace
fn ToSerializableT(T: type, options: ToSerializableOptions, align_hint: ?std.mem.Alignment) anyerror!type {
  return switch (@typeInfo(T)) {
    .type, .noreturn, .comptime_int, .comptime_float, .undefined, .null, .error_set, .@"fn", .frame, .@"anyframe", .enum_literal => blk: {
      @compileLog("Type '" ++ @tagName(std.meta.activeTag(@typeInfo(T))) ++ "' is non serializable\n");
      break :blk error.NonSerializableType;
    },
    .void, .bool, .int, .float, .vector => GetDirectSerializableT(T, options, align_hint),
    .pointer => |pi| if (options.dereference == 0) GetDirectSerializableT(T, options, align_hint) else switch (pi.size) {
      .many, .c => if (options.serialize_unknown_pointer_as_usize) GetDirectSerializableT(T, options, align_hint) else blk: {
        @compileLog(@tagName(pi.size) ++ " pointer cannot be serialized for type " ++ @typeName(T) ++ ", consider setting serialize_many_pointer_as_usize to true\n");
        break :blk error.NonSerializablePointerType;
      },
      .one => if (options.dereference == 0) if (options.error_on_0_dereference) blk: {
        @compileLog("Cannot dereference type " ++ @typeName(T) ++ " any further as options.dereference is 0\n");
        break :blk error.ErrorOn0Dereference;
      } else GetDirectSerializableT(T, options, align_hint) else blk: {
        const U = try ToSerializableT(pi.child, next_options: {
          var retval = options;
          retval.dereference -= 1;
          break :next_options retval;
        }, null);

        break :blk opaque {
          pub const Signature = SerializableSignature{
            .T = T,
            .U = U.Signature.U,
            .static_size = U.Signature.static_size,
            .alignment = if (options.serialization == .default) .fromByteUnits(@alignOf(T)) else .@"1",
          };

          pub const IsSameOld = U.IsSameOld;

          pub fn writeStatic(val: *const T, bytes: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0) void {
            return U.writeStatic(val.*, bytes, offset);
          }

          pub fn getDynamicSize(val: *const T) usize {
            return U.getDynamicSize(val.*);
          }

          pub fn writeDynamic(val: *const T, bytes: []u8) usize {
            return U.writeDynamic(val.*, bytes);
          }

          pub const readDynamicSize = U.readDynamicSize;
          pub const read = U.read;
        };
      },
      .slice => if (options.deslice == 0) if (options.error_on_0_deslice) blk: {
        @compileLog("Cannot deslice type " ++ @typeName(T) ++ " any further as options.dereference is 0\n");
        break :blk error.ErrorOn0Deslice;
      } else GetDirectSerializableT(T, options, align_hint) else blk: {
        const U = try ToSerializableT(pi.child, next_options: {
          var retval = options;
          retval.deslice -= 1;
          break :next_options retval;
        }, null);

        break :blk opaque {
          pub const Signature = SerializableSignature{
            .T = T,
            .U = U,
            .static_size = switch (options.serialization) {
              .default, .noalign => @sizeOf(options.slice_len_type),
              .pack => @bitSizeOf(options.slice_len_type)
            },
            .alignment = if (options.serialization == .default) .fromByteUnits(@alignOf(T)) else .@"1",
          };

          pub const IsSameOld = U.IsSameOld;

          pub fn writeStatic(val: *const T, bytes: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0) void {
            switch (options.serialization) {
              .default, .noalign => bytes[0..@sizeOf(options.slice_len_type)].* = std.mem.toBytes(@as(options.slice_len_type, @intCast(val.len)))[0..@sizeOf(options.slice_len_type)].*,
              .pack => std.mem.writePackedInt(options.slice_len_type, bytes, offset, @as(options.slice_len_type, @intCast(val.len)), native_endian),
            }
          }

          pub fn getDynamicSize(val: *const T) usize {
            var retval: usize = U.Signature.static_size * val.*.len;
            for (val.*) |v| retval += U.getDynamicSize(&v);
            return retval;
          }

          pub fn writeDynamic(val: *const T, bytes: []u8) usize {
            var written: usize = 0;
            for (val.*) |v| {
              U.writeStatic(&v, bytes[written..], 0);
              written += U.Signature.static_size;
            }
            for (val.*) |v| written += U.writeDynamic(&v, bytes[written..]);
            return written;
          }

          pub fn readDynamicSize(static: []const u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []const u8) usize {
            @compileError("TODO: Implement");
          }

          pub const Slice = struct {
            static: []const u8,
            dynamic: []const u8,
            offset: if (options.serialization == .pack) u3 else u0 = 0,

            pub const Getter = GetterSignature{};

            pub fn get(self: @This(), i: options.slice_len_type) U {
              @compileError("TODO: Implement");
              // return switch (options.serialization) {
              //   .default, .noalign => U.read(self.static[i * Signature.static_size..], self.offset, self.da),
              //   .pack => U.read(self.static[i * (Signature.static_size >> 3) + ((i * (Signature.static_size & 7)) >> 3)..], (i * (Signature.static_size & 7)) & 7, self.da),
              // };
            }
          };

          pub fn read(static: []const u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []const u8) Slice {
            return .{ .static = static, .dynamic = dynamic, .offset = offset, };
          }
        };
      },
    },
    .array => |ai| blk: {
      const U = try ToSerializableT(ai.child, options, if (align_hint) |hint| .fromByteUnits(@min(@alignOf(ai.child), hint.toByteUnits())) else null);

      break :blk opaque {
      pub const IsSameOld = if (@hasDecl(U, "IsSameOld") and !U.IsSameOld) false else true;

      pub const Signature = SerializableSignature{
        .T = T,
        .U = U,
        .static_size = switch (options.serialization) {
          .default => @sizeOf(T),
          .noalign => std.math.divCeil(comptime_int, @bitSizeOf(ai.child), 8) * ai.len,
          .pack => @bitSizeOf(ai.child) * ai.len,
        },
        .alignment = if (options.serialization == .default) .fromByteUnits(@alignOf(T)) else .@"1",
      };

      const I = std.meta.Int(.unsigned, Signature.static_size);
      pub fn writeStatic(val: *const T, _bytes: [] u8, _offset: if (options.serialization == .pack) u3 else u0) void {
        var bytes = _bytes;
        var offset = _offset;
        inline for (0..ai.len) |i| {
          U.writeStatic(&val[i], bytes, offset);
          switch (comptime options.serialization) {
            .default, .noalign => bytes = bytes[U.Signature.static_size..],
            .pack => {
              const new_offset = U.Signature.static_size + offset;
              bytes = bytes[new_offset >> 3..];
              offset = new_offset & 0b111;
            }
          }
        }
      }

      pub fn getDynamicSize(val: *const T) usize {
        var retval: usize = 0;
        inline for (0..ai.len) |i| retval += U.getDynamicSize(&val[i]);
        return retval;
      }

      pub fn writeDynamic(val: *const T, bytes: []u8) usize {
        var written: usize = 0;
        inline for (0..ai.len) |i| written += U.writeDynamic(&val[i], bytes[written..]);
        return written;
      }

      pub fn readDynamicSize(static: []const u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []const u8) usize {
        @compileError("TODO: Implement");
      }

      pub const Array = struct {
        static: []const u8,
        dynamic: []const u8,
        offset: if (options.serialization == .pack) u3 else u0 = 0,

        pub const Getter = GetterSignature{};

        pub fn get(self: @This(), i: options.slice_len_type) U {
          @compileError("TODO: Implement");
          // return switch (options.serialization) {
          //   .default, .noalign => U.read(self.static[i * Signature.static_size..], self.offset, self.da),
          //   .pack => U.read(self.static[i * (Signature.static_size >> 3) + ((i * (Signature.static_size & 7)) >> 3)..], (i * (Signature.static_size & 7)) & 7, self.da),
          // };
        }
      };

      pub fn read(static: []const u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []const u8) Array {
        return .{ .static = static, .dynamic = dynamic, .offset = offset };
      }
      };
    },
    .@"struct" => |si| if (options.recurse == 0) if (options.error_on_0_recurse) blk: {
      @compileLog("Cannot deslice type " ++ @typeName(T) ++ " any further as options.recurse is 0\n");
      break :blk error.ErrorOn0Recurse;
    } else GetDirectSerializableT(T, options, align_hint) else blk: {
      const UInfo: std.builtin.Type.Struct = .{
        .layout = switch (options.serialization) {
          .default, .noalign => .auto,
          .pack => .@"packed",
        },
        .fields = try GetSortedFields(si.fields, options),
        .decls = &.{},
        .is_tuple = si.is_tuple,
      };

      break :blk opaque {
        pub const IsSameOld = options.serialization == .default and blk: {
          for (UInfo.fields, si.fields) |f, s| {
            if (f.name != s.name or @hasDecl(f.type, "IsSameOld") and !f.type.IsSameOld) break :blk false;
          }
          break :blk true;
        };

        pub const Signature = SerializableSignature{
          .T = T,
          .U = @Type(.{ .@"struct" = UInfo }),
          .static_size = switch (options.serialization) {
            .default, .noalign => @sizeOf(T),
            .pack => @bitSizeOf(T),
          },
          .alignment = if (options.serialization == .default) .fromByteUnits(@alignOf(T)) else .@"1",
        };

        pub fn writeStatic(val: *const T, _bytes: []align(Signature.alignment.toByteUnits()) u8, _offset: if (options.serialization == .pack) u3 else u0) void {
          var bytes = _bytes;
          var offset = _offset;
          inline for (UInfo.fields) |f| {
            f.type.writeStatic(&@field(val.*, f.name), bytes, offset);
            switch (options.serialization) {
              .default, .noalign => bytes = bytes[f.type.Signature.static_size..],
              .pack => {
                const new_offset = Signature.static_size + offset;
                bytes = bytes[new_offset >> 3..];
                offset = new_offset & 0b111;
              }
            }
          }
        }

        pub fn getDynamicSize(val: *const T) usize {
          var retval: usize = 0;
          inline for (UInfo.fields) |f| retval += f.type.getDynamicSize(&@field(val.*, f.name));
          return retval;
        }

        pub fn writeDynamic(val: *const T, bytes: []u8) usize {
          var written: usize = 0;
          for (UInfo.fields) |f| written = f.type.writeDynamic(&@field(val.*, f.name), bytes[written..]);
          return written;
        }

        pub const Struct = struct {
          static: []const u8,
          dynamic: []const u8,
          offset: if (options.serialization == .pack) u3 else u0 = 0,

          pub const Getter = GetterSignature{};

          pub fn get(self: @This(), comptime name: []const u8) FnReturnType(@FieldType(Signature.U, name).read) {
            comptime var offset: usize = 0;
            inline for (UInfo.fields) |f| {
              comptime {
                if (!std.mem.eql(u8, f.name, name)) {
                  offset += f.type.Signature.static_size;
                  continue;
                }
              }
              return switch (options.serialization) {
                .default, .noalign => f.type.read(self.static[offset..], self.offset, self.dynamic),
                .pack => f.type.read(self.static[(offset >> 3) + (((offset&7) + self.offset) >> 3)..], @intCast((self.offset + (offset&7)) & 7), self.dynamic),
              };
            }
            unreachable;
          }
        };

        pub fn read(static: []const u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []const u8) Struct {
          return .{ .static = static, .dynamic = dynamic, .offset = offset, };
        }
      };
    },
    .optional => |oi| blk: {
      const U = try ToSerializableT(union(enum) { None: void, Some: oi.child }, options, align_hint);
      const Underlying = @FieldType(U.Signature.U, "some");
      break :blk opaque {
        pub const Signature = SerializableSignature{
          .T = T,
          .U = U,
          .static_size = U.Signature.static_size,
          .alignment = U.Signature.alignment,
        };
        pub const IsSameOld = U.IsSameOld;

        pub fn writeStatic(val: *const T, bytes: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0) void {
          const u = @unionInit(Signature.U.Signature.T, if (val.*) "some" else "none", if (val.*) |v| v else {});
          U.writeStatic(&u, bytes, offset);
        }

        pub fn getDynamicSize(val: *const T) usize {
          return if (val.*) |v| Underlying.getDynamicSize(&v) else 0;
        }

        pub fn writeDynamic(val: *const T, bytes: []u8) usize {
          return if (val.*) |v| Underlying.writeDynamic(&v, bytes) else 0;
        }

        pub const readDynamicSize = U.readDynamicSize;

        pub fn read(static: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []const u8) ?Underlying {
          return switch (U.read(static, offset, dynamic)) {
            .None => null,
            .Some => |v| v,
          };
        }
      };
    },
    .error_union => |ei| blk: {
      const U = try ToSerializableT(union(enum) { Err: ei.error_set, Some: ei.payload }, options, align_hint);
      const Underlying = @FieldType(U.Signature.U, "ok");
      break :blk opaque {
        pub const Signature = SerializableSignature{
          .T = T,
          .U = U,
          .static_size = U.Signature.static_size,
          .alignment = U.Signature.alignment,
        };
        pub const IsSameOld = U.IsSameOld;

        pub fn writeStatic(val: *const T, bytes: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0) void {
          const u = @unionInit(Signature.U.Signature.T, if (std.meta.isError(val.*)) "Err" else "Ok", val.* catch |e| e);
          U.writeStatic(&u, bytes, offset);
        }

        pub fn getDynamicSize(val: *const T) usize {
          return if (!std.meta.isError(val.*)) Underlying.getDynamicSize(&(val.* catch unreachable)) else 0;
        }

        pub fn writeDynamic(val: *const T, bytes: []u8) usize {
          return if (!std.meta.isError(val.*)) Underlying.writeDynamic(&(val.* catch unreachable), bytes) else 0;
        }

        pub const readDynamicSize = U.readDynamicSize;

        pub fn read(static: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []const u8) ei.error_set!U.Signature.U {
          return switch (U.read(static, offset, dynamic)) {
            .Err => |e| e,
            .Some => |v| v,
          };
        }
      };
    },
    .@"enum" => |ei| if (ei.is_exhaustive or (options.shrink_enum and @bitSizeOf(T) == std.math.log2_int_ceil(usize, ei.fields.len))) blk: {
      break :blk GetDirectSerializableT(T, options, align_hint);
    } else opaque {
      pub const IsSameOld = false;
      const TagType = @typeInfo(Signature.U).@"enum".tag_type;
      const min_bits = @bitSizeOf(TagType);
      const Direct = GetDirectSerializableT(Signature.U, options, align_hint);

      pub const Signature = SerializableSignature{
        .T = T,
        .U = GetShrunkEnumType(T),
        .static_size = Direct.Signature.static_size,
        .alignment = Direct.Signature.alignment,
      };

      pub fn writeStatic(val: *const T, bytes: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0) void {
        if (min_bits == 0) return;

        const OGTT = ei.tag_type; // Original TagType
        // This generates better assembly (or so std.meta.intToEnum says)
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

      pub fn read(static: []const u8, offset: if (options.serialization == .pack) u3 else u0, _: []const u8) Signature.U {
        if (min_bits == 0) return @enumFromInt(0);
        return @enumFromInt(switch (options.serialization) {
          .default, .noalign => std.mem.readInt(TagType, static[0..Signature.static_size], native_endian),
          .pack => std.mem.readPackedInt(TagType, static, offset, native_endian),
        });
      }

      /// Convert the given value to original type
      pub fn toOriginalT(val: Signature.U) T {
        return @enumFromInt(@typeInfo(T).@"enum".fields[@intFromEnum(val)]);
      }
    },
    .@"union" => |ui| if (ui.tag_type == null) blk: {
      @compileLog("Cannot serialize untagged union " ++ @typeName(T) ++ " as it has no tag type\n");
      break :blk error.UntaggedUnion;
    } else if (options.recurse == 0) if (options.error_on_0_recurse) blk: {
      @compileLog("Cannot deslice type " ++ @typeName(T) ++ " any further as options.recurse is 0\n");
      break :blk error.ErrorOn0Recurse;
    } else GetDirectSerializableT(T, options, align_hint) else blk: {
      // WARNING: We store tag after the union data, this is what zig seems to do as well but is likely not guaranteed.
      const TagType = ui.tag_type.?;
      const UInfo: std.builtin.Type.Union = .{
        .layout = switch (options.serialization) {
          .default, .noalign => .auto,
          .pack => .@"packed",
        },
        .tag_type = TagType,
        .fields = try GetSortedFields(ui.fields, options),
        .decls = &.{},
      };

      break :blk opaque {
        pub const IsSameOld = options.serialization == .default and blk: {
          for (UInfo.fields, ui.fields) |f, s| {
            if (f.name != s.name or @hasDecl(f.type, "IsSameOld") and !f.type.IsSameOld) break :blk false;
          }
          break :blk true;
        };

        const SubMax = blk: {
          var max = 0;
          for (UInfo.fields) |f| max = @max(max, f.type.Signature.static_size);
          break :blk max;
        };

        pub const Signature = SerializableSignature{
          .T = T,
          .U = @Type(.{ .@"union" = UInfo }),
          .static_size = switch (options.serialization) {
            .default => if (IsSameOld) @sizeOf(T),
            else => SubMax + (if (options.serialization == .noalign) std.math.divCeil(comptime_int, @bitSizeOf(TagType), 8) else @bitSizeOf(TagType)),
          },
          .alignment = if (options.serialization == .default) .fromByteUnits(@alignOf(T)) else .@"1",
        };

        const SizedInt = std.meta.Int(.unsigned, Signature.static_size);
        const TagInt = std.meta.Tag(TagType);

        pub fn writeStatic(val: *const T, bytes: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0) void {
          const active_tag = std.meta.activeTag(val.*);
          inline for (UInfo.fields) |f| {
            const ftag = comptime std.meta.stringToEnum(TagType, f.name);
            if (ftag == active_tag) {
              f.type.writeStatic(&@field(val, f.name), bytes[0..SubMax], offset);
              return switch (options.serialization) {
                .default => {
                  bytes[SubMax..][0..@sizeOf(TagInt)].* = std.mem.toBytes(active_tag);
                },
                .noalign => {
                  bytes[SubMax..][0..std.math.divCeil(comptime_int, @bitSizeOf(TagInt), 8)].* = std.mem.toBytes(active_tag);
                },
                .pack => {
                  const tag_offset = SubMax + offset;
                  const _bytes = bytes[tag_offset >> 3..];
                  const _offset = tag_offset & 0b111;
                  std.mem.writePackedInt(TagInt, _bytes, _offset, @bitCast(f.type.Signature.static_size), native_endian);
                }
              };
            }
          }
          unreachable;
        }

        pub fn getDynamicSize(val: *const T) usize {
          const active_tag = std.meta.activeTag(val.*);
          inline for (UInfo.fields) |f| {
            const ftag = comptime std.meta.stringToEnum(TagType, f.name);
            if (ftag == active_tag) return f.type.getDynamicSize(&@field(val, f.name));
          }
          unreachable;
        }

        pub fn writeDynamic(val: *const T, bytes: []u8) usize {
          const active_tag = std.meta.activeTag(val.*);
          inline for (UInfo.fields) |f| {
            const ftag = comptime std.meta.stringToEnum(TagType, f.name);
            if (ftag == active_tag) return f.type.writeDynamic(&@field(val, f.name), bytes);
          }
          unreachable;
        }

        pub fn read(static: []align(Signature.alignment.toByteUnits()) u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []const u8) Signature.U {
          const active_tag: TagType = @enumFromInt(switch (options.serialization) {
            .default => @as(TagInt, @bitCast(static[SubMax..][0..@sizeOf(TagInt)])),
            .noalign => @as(TagInt, @bitCast(static[SubMax..][0..std.math.divCeil(comptime_int, @bitSizeOf(TagInt), 8)])),
            .pack => blk: {
              const tag_offset = SubMax + offset;
              const _static = static[tag_offset >> 3..];
              const _offset = tag_offset & 0b111;
              break :blk std.mem.readPackedInt(SizedInt, _static, _offset, native_endian);
            },
          });
          inline for (UInfo.fields) |f| {
            const ftag = comptime std.meta.stringToEnum(TagType, f.name);
            if (ftag == active_tag) return @unionInit(Signature.U, f.name, f.type.read(static[0..SubMax], offset, dynamic));
          }
          unreachable;
        }
      };
    },
    .@"opaque" => if (@hasDecl(T, "Signature") and @TypeOf(@field(T, "Signature")) == SerializableSignature) T else blk: {
      @compileLog("A non-serializable opaque " ++ @typeName(T) ++ " was provided to `ToSerializableT`\n");
      break :blk error.NonSerializableOpaque;
    },
  };
}

/// Convert any type to a serializable type, any unsupported types present in the struct will result in a compile error.
/// Be careful with options when using recursive structs, You will likely need to turn off (or atleast limit) options.dereference
pub fn ToSerializable(options: ToSerializableOptions) type {
  return ToSerializableT(options.T, options, null) catch |e|
    @compileError(std.fmt.comptimePrint("Error: {!} while serializing {s}", .{e, @typeName(options.T)}));
}

