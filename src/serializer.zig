const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const meta = @import("meta.zig");

const FnReturnType = meta.FnReturnType;
const ToSerializableOptions = root.ToSerializableOptions;
const native_endian = builtin.cpu.arch.endian();

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

fn divCeil(comptime T: type, a: T, b: T) T {
  return std.math.divCeil(T, a, b) catch unreachable;
}

/// We take in a type and just use its byte representation to store into bits.
/// No dereferencing is done for pointers, and voids dont take up any space at all
pub fn GetDirectSerializableT(T: type, options: ToSerializableOptions, align_hint: ?std.mem.Alignment) type {
  return opaque {
    const I = std.meta.Int(.unsigned, Signature.static_size);
    const NoalignSize = divCeil(comptime_int, @bitSizeOf(T), 8);
    pub const Signature = SerializableSignature{
      .T = T,
      .U = T,
      .static_size = switch (options.serialization) {
        .default => @sizeOf(T),
        .noalign => NoalignSize,
        .pack => @bitSizeOf(T),
      },
      .alignment = if (options.serialization == .default) align_hint orelse .fromByteUnits(@alignOf(T)) else .@"1",
    };

    fn toI(val: T) I {
      return switch (@typeInfo(T)) {
        .@"enum" => @intFromEnum(val),
        .pointer => |pi| switch (pi.size) {
          .one, .c, .many => @intFromFloat(val),
          .slice => @bitCast(val),
        },
        else => @bitCast(val),
      };
    }

    fn fromI(val: I) T {
      return switch (@typeInfo(T)) {
        .@"enum" => @enumFromInt(val),
        .pointer => |pi| switch (pi.size) {
          .one, .c, .many => @ptrFromInt(val),
          .slice => @bitCast(val),
        },
        else => @bitCast(val),
      };
    }

    /// `static` should always have enough bytes/bits.
    /// This MUST write exactly `Signature.static_size` bits if Signature.serialization == .packed / bytes otherwise
    /// offset is always 0 unless packed is used
    pub fn write(val: *const T, static: []u8, offset: if (options.serialization == .pack) u3 else u0, _: []u8) void {
      if (@bitSizeOf(T) == 0) return;
      switch (comptime options.serialization) {
        .default => static[0..@sizeOf(T)].* = std.mem.toBytes(val.*),
        .noalign => static[0..NoalignSize].* = std.mem.toBytes(val.*)[0..NoalignSize].*,
        .pack => std.mem.writePackedInt(I, static, offset, toI(val.*), native_endian),
      }
    }

    pub const GS = struct {
      static: []u8,
      offset: if (options.serialization == .pack) u3 else u0 = 0,

      pub fn get(self: @This()) T {
        if (@bitSizeOf(T) == 0) return undefined;
        return switch (comptime options.serialization) {
          .default => {
            var retval: T = undefined;
            if (std.mem.asBytes(&retval).len != self.static.len) {
              std.debug.panic("differing lengths: {} != {} for {s} w ss = {d}\n", .{ std.mem.asBytes(&retval).len, self.static.len, @typeName(T), Signature.static_size });
            }
            @memcpy(std.mem.asBytes(&retval), self.static);
            return retval;
          },
          .noalign => {
            var retval: T = undefined;
            @memcpy(std.mem.asBytes(&retval)[0..NoalignSize], self.static[0..NoalignSize]);
            return retval;
          },
          .pack => fromI(std.mem.readPackedInt(I, self.static, self.offset, native_endian)),
        };
      }

      pub fn set(self: @This(), val: T) void {
        write(&val, self.static, self.offset, undefined);
      }

      pub fn sub(_: @This()) void {
        @compileError("cannot be called");
      }
    };

    pub fn read(static: []u8, offset: if (options.serialization == .pack) u3 else u0, _: []u8) GS {
      return .{ .static = static, .offset = offset };
    }
  };
}

/// We return an error instead of calling @compileError directly because we want to give the user a stacktrace
pub fn ToSerializableT(T: type, options: ToSerializableOptions, align_hint: ?std.mem.Alignment) anyerror!type {
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

          pub fn write(val: *const T, static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) FnReturnType(U.write) {
            return U.write(val.*, static, offset, dynamic);
          }

          pub const getDynamicSize = if (FnReturnType(U.write) == void) void else _getDynamicSize;
          pub fn _getDynamicSize(val: *const T) usize {
            return U.getDynamicSize(val.*);
          }

          pub const GS = U.GS;
          pub const read = U.read;
        };
      },
      .slice => if (options.deslice == 0) if (options.error_on_0_deslice) blk: {
        @compileLog("Cannot deslice type " ++ @typeName(T) ++ " any further as options.dereference is 0\n");
        break :blk error.ErrorOn0Deslice;
      } else GetDirectSerializableT(T, options, align_hint) else blk: {
        const next_options = next_options: {
          var retval = options;
          retval.deslice -= 1;
          retval.serialization = switch (options.serialization) {
            .default => .default,
            .noalign, .pack => .noalign,
          };
          break :next_options retval;
        };
        const U = try ToSerializableT(pi.child, next_options, null);
        const Sint = GetDirectSerializableT(options.dynamic_len_type, options, align_hint);
        const Dint = GetDirectSerializableT(options.dynamic_len_type, next_options, align_hint);

        break :blk opaque {
          const SubStatic = FnReturnType(pi.child) == void;
          pub const Signature = SerializableSignature{
            .T = T,
            .U = U,
            .static_size = Sint.Signature.static_size,
            .alignment = Sint.Signature.alignment,
          };

          pub fn write(val: *const T, _static: []u8, _offset: if (options.serialization == .pack) u3 else u0, _dynamic: []u8) options.dynamic_len_type {
            const val_len: options.dynamic_len_type = @intCast(val.*.len);
            Sint.write(&val_len, _static, _offset, _dynamic);
            if (val_len == 0) return 0;

            const dindex_offset_size = if (SubStatic) 0 else (val_len - 1) * Dint.Signature.static_size;
            const static = _dynamic[0..val_len * U.Signature.static_size + dindex_offset_size];
            const dynamic = _dynamic[val_len * U.Signature.static_size + dindex_offset_size..];

            var dwritten: options.dynamic_len_type = 0;
            for (val.*, 0..) |v, i| {
              const sindex_offset = if (SubStatic or i == 0) 0 else Dint.Signature.static_size * (i - 1);
              const soffset = dindex_offset_size + Dint.Signature.static_size * (i - 1);
              const len = U.write(&v, static[soffset..], 0, if (SubStatic) undefined else dynamic[dwritten..]);
              if (SubStatic) continue;
              if (i != 0) {
                Dint.write(&dwritten, static[sindex_offset..], 0, undefined);
              }
              dwritten += len;
            }
          }

          pub fn getDynamicSize(val: *const T) usize {
            if (val.*.len == 0) return 0;
            var retval: usize = U.Signature.static_size * val.*.len;
            if (!SubStatic) {
              retval += Dint.Signature.static_size * (val.*.len - 1);
              for (val.*) |v| retval += U.getDynamicSize(&v);
            }
            return retval;
          }

          pub const GS = struct {
            static: []u8,
            dynamic: if (SubStatic) void else []u8,
            len: options.dynamic_len_type,

            pub fn get(self: @This(), i: options.dynamic_len_type) U {
              std.debug.assert(self.len != 0);
              std.debug.assert(i < self.len);
              const dindex_offset_size = if (SubStatic) 0 else (self.len - 1) * Dint.Signature.static_size;
              const sindex_offset = if (SubStatic or i == 0) 0 else Dint.Signature.static_size * (i - 1);
              const soffset = dindex_offset_size + Dint.Signature.static_size * (i - 1);
              const doffset = if (SubStatic) {} else if (i == 0) 0 else Dint.read(self.static[sindex_offset..], 0, undefined);
              return U.read(self.static[soffset..], 0, if (SubStatic) undefined else self.dynamic[doffset..]);
            }

            pub fn set(self: @This(), val: T) void {
              write(&val, self.static, self.offset, self.dynamic);
            }

            pub fn sub(self: @This()) meta.WrapSub(Self, options) {
              return .{ ._static = self.static, ._offset = 0, ._dynamic = if (SubStatic) undefined else self.dynamic };
            }
          };
          const Self = @This();

          pub fn read(static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) GS {
            const val_len = Sint.read(static, offset, undefined).get();
            const dindex_offset_size = if (SubStatic) 0 else (val_len - 1) * Dint.Signature.static_size;
            return .{
              .static = dynamic[0..val_len * U.Signature.static_size + dindex_offset_size],
              .dynamic = if (SubStatic) undefined else dynamic[val_len * U.Signature.static_size + dindex_offset_size..],
              .len = val_len,
            };
          }
        };
      },
    },
    .array => |ai| blk: {
      if (ai.len == 0) break :blk GetDirectSerializableT(T, options, align_hint);
      const U = try ToSerializableT(ai.child, options, if (align_hint) |hint| .fromByteUnits(@min(@alignOf(ai.child), hint.toByteUnits())) else null);
      const IndexSize = switch (options.serialization) {
        .default => @sizeOf(options.dynamic_len_type),
        .noalign => divCeil(comptime_int, @bitSizeOf(options.dynamic_len_type), 8),
        .pack => @bitSizeOf(options.dynamic_len_type),
      };
      const StaticSize = switch (options.serialization) {
        .default => @sizeOf(T),
        .noalign => divCeil(comptime_int, @bitSizeOf(ai.child), 8) * ai.len,
        .pack => @bitSizeOf(ai.child) * ai.len,
      };

      const Sint = GetDirectSerializableT(options.dynamic_len_type, options, null);

      break :blk opaque {
        const I = std.meta.Int(.unsigned, Signature.static_size);
        const IsStatic = FnReturnType(U.read) == void;
        pub const Signature = SerializableSignature{
          .T = T,
          .U = U,
          .static_size = StaticSize + (ai.len - 1) * if (!IsStatic) IndexSize else 0,
          .alignment = if (options.serialization == .default) .fromByteUnits(@alignOf(T)) else .@"1",
        };

        pub fn write(val: *const T, static: [] u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) FnReturnType(U.write) {
          var dwritten: if (IsStatic) void else options.dynamic_len_type = 0;
          inline for (0..ai.len) |i| {
            const swritten_idx = if (IsStatic or i == 0) 0 else IndexSize * (i - 1);
            const swritten = swritten_idx + U.Signature.static_size * i;
            const len = U.write(&val[i], static[switch (options.serialization) {
              .default, .noalign => static[swritten..],
              .pack => static[swritten >> 3..],
            }..], switch (options.serialization) {
              .default, .noalign => 0,
              .pack => @intCast((swritten + offset) & 0b111),
            }, dynamic[dwritten..]);
            if (IsStatic) continue;
            if (i != 0) {
              Sint.write(&dwritten, static[switch (options.serialization) {
                .default, .noalign => static[swritten_idx..],
                .pack => static[swritten_idx >> 3..],
              }..], switch (options.serialization) {
                .default, .noalign => 0,
                .pack => @intCast((swritten_idx + offset) & 0b111),
              }, undefined);
            }
            dwritten += len;
          }
        }

        pub const getDynamicSize = if (IsStatic) void else _getDynamicSize;
        pub fn _getDynamicSize(val: *const T) usize {
          var retval: usize = 0;
          inline for (0..ai.len) |i| retval += U.getDynamicSize(&val[i]);
          return retval;
        }

        pub const GS = struct {
          static: []u8,
          dynamic: []u8,
          offset: if (options.serialization == .pack) u3 else u0 = 0,
          comptime len: options.dynamic_len_type = @intCast(ai.len),

          pub fn get(self: @This(), i: options.dynamic_len_type) U {
            const sindex_offset = if (IsStatic or i == 0) 0 else IndexSize * (i - 1);
            const soffset = sindex_offset + U.Signature.static_size * i;
            const doffset = if (IsStatic) {} else if (i == 0) 0 else Sint.read(self.static[switch (options.serialization) {
              .default, .noalign => sindex_offset,
              .pack => (sindex_offset + self.offset) >> 3,
            }..], switch (options.serialization) {
              .default, .noalign => 0,
              .pack => @intCast((sindex_offset + self.offset) & 0b111),
            }, undefined);
            return U.read(self.static[switch (options.serialization) {
              .default, .noalign => soffset,
              .pack => (soffset + self.offset) >> 3,
            }..], switch (options.serialization) {
              .default, .noalign => 0,
              .pack => @intCast((soffset + self.offset) & 0b111),
            }, if (IsStatic) undefined else self.dynamic[doffset..]);
          }

          pub fn set(self: @This(), val: T) void {
            write(&val, self.static, self.offset, self.dynamic);
          }

          pub fn sub(self: @This()) meta.WrapSub(Self, options) {
            return .{ ._static = self.static, ._offset = self.offset, ._dynamic = self.dynamic };
          }
        };
        const Self = @This();

        pub fn read(static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) GS {
          return .{ .static = static, .dynamic = dynamic, .offset = offset };
        }
      };
    },
    .@"struct" => |si| if (options.recurse == 0) if (options.error_on_0_recurse) blk: {
      @compileLog("Cannot deslice type " ++ @typeName(T) ++ " any further as options.recurse is 0\n");
      break :blk error.ErrorOn0Recurse;
    } else GetDirectSerializableT(T, options, align_hint) else blk: {
      const UFields: []const std.builtin.Type.StructField = fields: {
        var next_options = options;
        next_options.recurse -= 1;
        var fields_slice = si.fields;
        var fields_array: [fields_slice.len]std.builtin.Type.StructField = fields_slice[0..fields_slice.len].*;
        for (0..fields_array.len) |i| {
          switch (options.serialization) {
            .default => {},
            .noalign => fields_array[i].alignment = 1,
            .pack => fields_array[i].alignment = 0,
          }
          fields_array[i].type = try ToSerializableT(fields_array[i].type, next_options, switch (options.serialization) {
            .default => .fromByteUnits(@max(fields_array[i].alignment, 1)),
            else => null,
          });
        }

        const sortfn = struct {
          /// Rhs and Lhs are reversed because we want to sort in reverse order
          fn inner(_: void, rhs: std.builtin.Type.StructField, lhs: std.builtin.Type.StructField) bool {
            return switch (options.serialization) {
              .default => if (lhs.alignment < rhs.alignment) true
                else lhs.type.Signature.static_size < rhs.type.Signature.static_size,
              .noalign, .pack => if (lhs.type.Signature.static_size == 0) rhs.type.Signature.static_size != 0
                else if (@ctz(@as(usize, lhs.type.Signature.static_size)) < @ctz(@as(usize, rhs.type.Signature.static_size))) true
                else lhs.type.Signature.static_size < rhs.type.Signature.static_size,
            };
          }
        }.inner;

        std.sort.block(std.builtin.Type.StructField, &fields_array, {}, sortfn);
        fields_slice = &fields_array;
        var is_first = true;

        // Add offset int field for all but the first field, first field has u0 instead
        for (si.fields) |f| {
          if (std.meta.hasFn(f.type, "getDynamicSize")) {
            fields_slice = fields_slice ++ [1]std.builtin.Type.StructField{std.builtin.Type.StructField{
              .name = "\xffoff" ++ f.name,
              .type = GetDirectSerializableT(if (is_first) u0 else options.dynamic_len_type, next_options, null),
              .default_value_ptr = null,
              .is_comptime = false,
              .alignment = if (is_first) 0 else switch (options.serialization) {
                .default => @alignOf(options.dynamic_len_type),
                .noalign => 1,
                .pack => 0,
              },
            }};
            is_first = false;
          }
        }

        var fields_array_2: [fields_slice.len]std.builtin.Type.StructField = fields_slice[0..fields_slice.len].*;
        std.sort.block(std.builtin.Type.StructField, &fields_array_2, {}, sortfn);
        const fields_array_3: [fields_slice.len]std.builtin.Type.StructField = fields_array_2;
        break :fields &fields_array_3;
      };

      break :blk opaque {
        const IsStatic = blk: {
          for (UFields) |f| if (std.meta.hasFn(f.type, "getDynamicSize")) break :blk false;
          break :blk true;
        };

        pub const Signature = SerializableSignature{
          .T = T,
          .U = void,
          .static_size = switch (options.serialization) {
            .default, .noalign => @sizeOf(T),
            .pack => @bitSizeOf(T),
          },
          .alignment = if (options.serialization == .default) .fromByteUnits(@alignOf(T)) else .@"1",
        };

        fn getField(comptime name: []const u8) std.builtin.Type.StructField {
          for (UFields) |f| if (std.mem.eql(u8, f.name, name)) return f;
          unreachable;
        }

        /// Returns the number of dynamic bytes written
        pub fn write(val: *const T, static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) if (IsStatic) void else options.dynamic_len_type {
          comptime var swritten: usize = 0;
          var dwritten: if (IsStatic) void else options.dynamic_len_type = if (IsStatic) {} else 0;
          inline for (UFields) |f| {
            if (comptime blk: {
              if (!std.mem.startsWith(u8, f.name, "\xffoff")) break :blk false;
              const name = if (f.name.len > 4) f.name[4..] else "";
              if (!@hasField(T, name)) break :blk false;
              break :blk std.meta.hasFn(getField(name).type, "getDynamicSize");
            }) continue;
            const fval = @field(val.*, f.name); // Copy value because we wanna support packed structs!
            const len = f.type.write(&fval, static[switch (options.serialization) {
              .default, .noalign => swritten,
              .pack => (swritten + offset) >> 3,
            }..], switch (options.serialization) {
              .default, .noalign => 0,
              .pack => @intCast((swritten + offset) & 0b111),
            }, dynamic);
            swritten += f.type.Signature.static_size;
            if (comptime @TypeOf(len) == void) continue; // Only static fields return void

            const result = @FieldType(T, "\xffoff" ++ f.name).write(if (dwritten == 0) &@as(u0, 0) else &dwritten, static[switch (options.serialization) {
              .default, .noalign => swritten,
              .pack => (swritten + offset) >> 3,
            }..], switch (options.serialization) {
              .default, .noalign => 0,
              .pack => @intCast((swritten + offset) & 0b111),
            }, undefined);
            std.debug.assert(@TypeOf(result) == void);
            dwritten += len;
          }
          std.debug.assert(swritten == Signature.static_size);
          return dwritten;
        }

        pub const getDynamicSize = if (IsStatic) void else _getDynamicSize;
        pub fn _getDynamicSize(val: *const T) usize {
          var retval: usize = 0;
          inline for (UFields) |f| retval += f.type.getDynamicSize(&@field(val.*, f.name));
          return retval;
        }

        pub const GS = struct {
          static: []u8,
          dynamic: []u8,
          offset: if (options.serialization == .pack) u3 else u0 = 0,

          fn getStaticOffset(comptime name: []const u8) comptime_int {
            comptime var soffset: usize = 0;
            inline for (UFields) |f| {
              if (!comptime std.mem.eql(u8, f.name, name)) {
                soffset += f.type.Signature.static_size;
              } else {
                return soffset;
              }
            }
            unreachable;
          }

          fn readStaticField(self: @This(), comptime name: []const u8) FnReturnType(@TypeOf(getField(name).type.read)) {
            const soffset: usize = getStaticOffset(name);
            return getField(name).type.read(self.static[switch (options.serialization) {
              .default, .noalign => soffset,
              .pack => (soffset + self.offset) >> 3,
            }..], switch (options.serialization) {
              .default, .noalign => 0,
              .pack => @intCast((soffset + self.offset) & 0b111),
            }, undefined);
          }

          pub fn get(self: @This(), comptime name: []const u8) FnReturnType(@TypeOf(getField(name).type.read)) {
            const ft = getField(name).type;
            if (!@hasField(T, "\xffoff" ++ name) or !std.meta.hasFn(ft, "getDynamicSize")) return self.readStaticField(name);
            const soffset: usize = self.getStaticOffset(name);
            const offset = self.readStaticField("\xffoff" ++ name).get();
            return ft.read(self.static[switch (options.serialization) {
              .default, .noalign => soffset,
              .pack => (soffset + self.offset) >> 3,
            }..], switch (options.serialization) {
              .default, .noalign => 0,
              .pack => @intCast((soffset + self.offset) & 0b111),
            }, self.dynamic[offset..]);
          }

          /// Asserts that the new value's dynamic size is <= the initial dynamic size
          pub fn set(self: @This(), val: T) void {
            write(&val, self.static, self.offset, self.dynamic);
          }

          pub fn sub(self: @This()) meta.WrapSub(Self, options) {
            return .{ ._static = self.static, ._offset = self.offset, ._dynamic = self.dynamic };
          }
        };
        const Self = @This();

        pub fn read(static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) GS {
          return .{ .static = static, .dynamic = dynamic, .offset = offset, };
        }
      };
    },
    .optional => |oi| blk: {
      const U = try ToSerializableT(union(enum) { none: void, some: oi.child }, options, align_hint);
      const Underlying = @FieldType(U.Signature.U, "some");
      break :blk opaque {
        pub const Signature = SerializableSignature{
          .T = T,
          .U = U,
          .static_size = U.Signature.static_size,
          .alignment = U.Signature.alignment,
        };

        pub fn write(val: *const T, static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) FnReturnType(U.write) {
          const u = @unionInit(Signature.U.Signature.T, if (val.*) "some" else "none", if (val.*) |v| v else {});
          U.write(&u, static, offset, dynamic);
        }

        pub const getDynamicSize = if (FnReturnType(U.write) == void) void else _getDynamicSize;
        pub fn _getDynamicSize(val: *const T) usize {
          return if (val.*) |v| Underlying.getDynamicSize(&v) else 0;
        }

        pub const GS = struct {
          underlying: U.GS,

          pub fn get(self: @This()) ?Underlying {
            return switch (self.underlying.get()) {
              .none => null,
              .some => |v| v,
            };
          }

          pub fn set(self: @This(), val: T) void {
            write(&val, self.underlying.static, self.underlying.offset, self.underlying.dynamic);
          }

          pub fn sub(self: @This()) meta.WrapSub(Self, options) {
            return .{ ._static = self.underlying.static, ._offset = self.underlying.offset, ._dynamic = self.underlying.dynamic };
          }
        };
        const Self = @This();

        pub fn read(static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) GS {
          return .{ .underlying = .{ .static = static, .dynamic = dynamic, .offset = offset } };
        }
      };
    },
    .error_union => |ei| blk: {
      const U = try ToSerializableT(union(enum) { err: ei.error_set, ok: ei.payload }, options, align_hint);
      const Underlying = @FieldType(U.Signature.U, "ok");
      break :blk opaque {
        pub const Signature = SerializableSignature{
          .T = T,
          .U = U,
          .static_size = U.Signature.static_size,
          .alignment = U.Signature.alignment,
        };

        pub fn write(val: *const T, static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) FnReturnType(U.write) {
          const u = @unionInit(Signature.U.Signature.T, if (std.meta.isError(val.*)) "err" else "ok", val.* catch |e| e);
          U.write(&u, static, offset, dynamic);
        }

        pub const getDynamicSize = if (FnReturnType(U.write) == void) void else _getDynamicSize;
        pub fn _getDynamicSize(val: *const T) usize {
          return if (!std.meta.isError(val.*)) Underlying.getDynamicSize(&(val.* catch unreachable)) else 0;
        }

        pub const GS = struct {
          underlying: U.GS,

          pub fn get(self: @This()) ei.error_set!Underlying {
            return switch (self.underlying.get()) {
              .err => |e| e,
              .ok => |v| v,
            };
          }

          pub fn set(self: @This(), val: T) void {
            write(&val, self.underlying.static, self.underlying.offset, self.underlying.dynamic);
          }

          pub fn sub(self: @This()) meta.WrapSub(Self, options) {
            return .{ ._static = self.underlying.static, ._offset = self.underlying.offset, ._dynamic = self.underlying.dynamic };
          }
        };
        const Self = @This();

        pub fn read(static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) GS {
          return .{ .underlying = .{ .static = static, .dynamic = dynamic, .offset = offset } };
        }
      };
    },
    .@"enum" => |ei| if (ei.is_exhaustive or !options.shrink_enum or meta.GetShrunkEnumType(T, options.serialization) == T) blk: {
      break :blk GetDirectSerializableT(T, options, align_hint);
    } else opaque {
      const TagType = @typeInfo(Signature.U).@"enum".tag_type;
      const min_bits = @bitSizeOf(TagType);
      const Direct = GetDirectSerializableT(Signature.U, options, align_hint);

      pub const Signature = SerializableSignature{
        .T = T,
        .U = meta.GetShrunkEnumType(T, options.serialization),
        .static_size = Direct.Signature.static_size,
        .alignment = Direct.Signature.alignment,
      };

      pub fn write(val: *const T, static: []u8, offset: if (options.serialization == .pack) u3 else u0, _: []u8) void {
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
            return Direct.writeStatic(&int, static, offset);
          }
        }
      }

      pub const GS = struct {
        underlying: Direct.GS,

        pub fn get(self: @This()) T {
          return @enumFromInt(@typeInfo(T).@"enum".fields[@intFromEnum(self.underlying.get())].value);
        }

        pub fn set(self: @This(), val: T) void {
          write(&val, self.underlying.static, self.underlying.offset, undefined);
        }

        pub fn sub(self: @This()) meta.WrapSub(Self, options) {
          return .{ ._static = self.underlying.static, ._offset = self.underlying.offset, ._dynamic = undefined };
        }
      };
      const Self = @This();

      pub fn read(static: []u8, offset: if (options.serialization == .pack) u3 else u0, _: []u8) GS {
        return .{ .underlying = .{ .static = static, .offset = offset } };
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
        .fields = fields: {
          var fields_array: [ui.fields.len]std.builtin.Type.UnionField = ui.fields[0..ui.fields.len].*;
          var new_options = options;
          new_options.recurse -= 1;
          for (0..fields_array.len) |i| {
            switch (options.serialization) {
              .default => {},
              .noalign => fields_array[i].alignment = 1,
              .pack => fields_array[i].alignment = 0,
            }
            fields_array[i].type = try ToSerializableT(fields_array[i].type, new_options, switch (options.serialization) {
              .default => .fromByteUnits(@max(fields_array[i].alignment, 1)),
              else => null,
            });
          }
          break :fields &fields_array;
        },
        .decls = &.{},
      };

      break :blk opaque {
        const SubMax = blk: {
          var max = 0;
          for (UInfo.fields) |f| max = @max(max, f.type.Signature.static_size);
          break :blk max;
        };

        pub const IsStatic = blk: {
          for (UInfo.fields) |f| if (std.meta.hasFn(f.type, "getDynamicSize")) break :blk false;
          break :blk true;
        };

        pub const Signature = SerializableSignature{
          .T = T,
          .U = @Type(.{ .@"union" = UInfo }),
          .static_size = SubMax + switch (options.serialization) {
            .default => @sizeOf(TagType),
            .noalign => divCeil(comptime_int, @bitSizeOf(TagType), 8),
            .pack => @bitSizeOf(TagType),
          },
          .alignment = if (options.serialization == .default) .fromByteUnits(@alignOf(T)) else .@"1",
        };

        const SizedInt = std.meta.Int(.unsigned, Signature.static_size);
        const TagInt = std.meta.Tag(TagType);

        pub fn write(val: *const T, static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) if (IsStatic) void else options.dynamic_len_type {
          const active_tag = std.meta.activeTag(val.*);
          inline for (UInfo.fields) |f| {
            const ftag = comptime std.meta.stringToEnum(TagType, f.name);
            if (ftag == active_tag) {
              switch (options.serialization) {
                .default => {
                  static[SubMax..][0..@sizeOf(TagInt)].* = std.mem.toBytes(active_tag);
                },
                .noalign => {
                  static[SubMax..][0..divCeil(comptime_int, @bitSizeOf(TagInt), 8)].* = std.mem.toBytes(active_tag);
                },
                .pack => {
                  const tag_offset = SubMax + offset;
                  const _bytes = static[tag_offset >> 3..];
                  const _offset: u3 = @intCast(tag_offset & 0b111);
                  std.mem.writePackedInt(TagInt, _bytes, _offset, @bitCast(active_tag), native_endian);
                }
              }
              const len = f.type.write(&@field(val, f.name), static[0..SubMax], offset, dynamic);
              return if (IsStatic) len else if (@TypeOf(len) == void) 0 else len;
            }
          }
          unreachable;
        }

        pub const getDynamicSize = if (IsStatic) void else _getDynamicSize;
        fn _getDynamicSize(val: *const T) usize {
          const active_tag = std.meta.activeTag(val.*);
          inline for (UInfo.fields) |f| {
            const ftag = comptime std.meta.stringToEnum(TagType, f.name);
            if (ftag == active_tag) return f.type.getDynamicSize(&@field(val, f.name));
          }
          unreachable;
        }

        pub const GS = struct {
          static: []u8,
          dynamic: []u8,
          offset: if (options.serialization == .pack) u3 else u0 = 0,

          pub fn activeTag(self: @This()) TagType {
            const static = self.static;
            var retval: TagType = undefined;
            switch (options.serialization) {
              .default => retval = @bitCast(static[SubMax..][0..@sizeOf(TagInt)]),
              .noalign => std.mem.asBytes(&retval)[0..divCeil(comptime_int, @bitSizeOf(TagInt), 8)].* =
                @bitCast(static[SubMax..][0..divCeil(comptime_int, @bitSizeOf(TagInt), 8)]),
              .pack => {
                const tag_offset = SubMax + self.offset;
                retval = std.mem.readPackedInt(SizedInt, static[tag_offset >> 3..], @intCast(tag_offset & 0b111), native_endian);
              },
            }
            return @enumFromInt(retval);
          }

          pub fn get(self: @This()) Signature.U {
            const active_tag = self.activeTag();
            inline for (UInfo.fields) |f| {
              const ftag = comptime std.meta.stringToEnum(TagType, f.name);
              if (ftag == active_tag) return @unionInit(Signature.U, f.name, f.type.read(self.static[0..SubMax], self.offset, self.dynamic));
            }
            unreachable;
          }

          pub fn set(self: @This(), val: T) void {
            write(&val, self.static, self.offset, self.dynamic);
          }

          pub fn sub(self: @This()) meta.WrapSub(Self, options) {
            return .{ ._static = self.static, ._offset = self.offset, ._dynamic = self.dynamic };
          }
        };
        const Self = @This();

        pub fn read(static: []u8, offset: if (options.serialization == .pack) u3 else u0, dynamic: []u8) GS {
          return .{ .static = static, .dynamic = dynamic, .offset = offset };
        }
      };
    },
    .@"opaque" => if (@hasDecl(T, "Signature") and @TypeOf(@field(T, "Signature")) == SerializableSignature) T else blk: {
      @compileLog("A non-serializable opaque " ++ @typeName(T) ++ " was provided to `ToSerializableT`\n");
      break :blk error.NonSerializableOpaque;
    },
  };
}

test {
  std.testing.refAllDeclsRecursive(@This());
}

const testing = std.testing;

fn expectEqual(expected: anytype, actual: anytype) !void {
  if (@TypeOf(expected) == @TypeOf(actual)) return try testing.expectEqual(expected, actual);
  switch (@typeInfo(@TypeOf(expected))) {
    .type, .noreturn, .comptime_float, .comptime_int, .undefined, .null, .error_set, .@"fn", .frame, .@"anyframe", .vector, .enum_literal =>
      @compileError(std.fmt.comptimePrint("Unreachable: {s}", .{@typeName(@TypeOf(expected))})),
    .void, .bool, .int, .float, .@"enum" => try expectEqual(expected, actual.get()),
    .array => |ai| inline for (0..ai.len) |i| try expectEqual(expected[i], actual.get(i)),
    .pointer => |pi| switch (pi.size) {
      .one => try expectEqual(expected.*, actual),
      .slice => for (0..pi.child.len) |i| try expectEqual(expected[i], actual.get(i)),
      .c, .many => try expectEqual(expected, actual.get()),
    },
    .@"struct" => |si| inline for (si.fields) |f| try expectEqual(@field(expected, f.name), actual.get(f.name)),
    .optional => if (expected) |e| try expectEqual(e, actual.get().some) else try expectEqual(null, actual.get().none),
    .error_union => try expectEqual(expected catch |e| try expectEqual(e, actual.get().err), actual.get().ok),
    .@"union" => |ui| {
      try expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
      inline for (std.meta.fields(expected)) |f| {
        if (std.meta.activeTag(expected) == std.meta.stringToEnum(ui.tag_type.?, f.name)) {
          return expectEqual(@field(expected, f.name), @field(actual, f.name));
        }
      }
      unreachable;
    },
    .@"opaque" => unreachable, // try expectEqual(expected._static, actual._static)
  }
}

fn _testSerializationDeserialization(comptime options: ToSerializableOptions, value: options.T) !void {
  const SerializableT = root.ToSerializable(options).Underlying;

  const static_size_bytes = comptime if (options.serialization == .pack) divCeil(usize, SerializableT.Signature.static_size, 8)
    else SerializableT.Signature.static_size;
  var static_buffer: [static_size_bytes]u8 = undefined;

  const dynamic_size = if (std.meta.hasFn(SerializableT, "getDynamicSize")) SerializableT.getDynamicSize(&value) else 0;
  var dynamic_buffer: [1024]u8 = undefined; // Large enough for tests

  if (dynamic_size > dynamic_buffer.len) {
    std.log.err("dynamic buffer too small for test. need {d}, have {d}", .{ dynamic_size, dynamic_buffer.len });
    return error.NoSpaceLeft;
  }

  const written_dynamic_size = SerializableT.write(&value, &static_buffer, 0, &dynamic_buffer);
  if (@TypeOf(written_dynamic_size) != void) {
    try testing.expectEqual(dynamic_size, written_dynamic_size);
  }

  const reader = SerializableT.read(&static_buffer, 0, &dynamic_buffer);
  try expectEqual(value, reader);
}

fn testSerialization(value: anytype) !void {
  const T = @TypeOf(value);
  inline for ([_]ToSerializableOptions{
    .{ .T = T, .serialization = .default, .shrink_enum = false },
    .{ .T = T, .serialization = .noalign, .shrink_enum = false },
    .{ .T = T, .serialization = .pack, .shrink_enum = false },
    .{ .T = T, .serialization = .default, .shrink_enum = true },
    .{ .T = T, .serialization = .noalign, .shrink_enum = true },
    .{ .T = T, .serialization = .pack, .shrink_enum = true },
  }) |o| try _testSerializationDeserialization(o, value);
}

test "primitive types" {
  try testSerialization(@as(u32, 42));
  try testSerialization(@as(f64, 123.456));
  try testSerialization(@as(bool, true));
  try testSerialization(@as(void, {}));
}

test "packable primitives" {
  try testSerialization(@as(u3,  5));
  try testSerialization(@as(i5, -3));
}

test "simple enum" {
  const Color = enum { red, green, blue };
  try testSerialization(Color.green);
}

test "shrunk enum" {
  const ShrunkEnum = enum(u32) { a = 0, b = 1000, c = 2000 };
  try testSerialization(ShrunkEnum.b);
  try testSerialization(ShrunkEnum.c);
}

test "simple struct" {
  const Point = struct { x: i32, y: i32 };
  try testSerialization(Point{ .x = -10, .y = 20 });
}

