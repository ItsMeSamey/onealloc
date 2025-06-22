const std = @import("std");

pub fn expectEqual(expected: anytype, actual: anytype) error{TestExpectedEqual}!void {
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

