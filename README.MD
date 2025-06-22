# OneAlloc: Allocate Everything All At Once

A simple library to convert complex data structures with pointers and slices into a single, contiguous memory allocation.

This is ideal for when data locality is critical, such as preparing data for IPC, caching, etc. The merged data block contains raw pointers, making it suitable for in-process memory management but **not for on-disk serialization or transport between processes.**

```zig
const std = @import("std");
const onealloc = @import("onealloc");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    // Define a complex type with dynamic data.
    const User = struct {
        id: u64,
        name: []const u8,
        roles: []const []const u8,
    };

    // The Wrapper manages the single memory allocation.
    const UserWrapper = onealloc.SimpleWrapper(.{ .T = User });
    
    var user_data = User{
        .id = 1234,
        .name = "Me",
        .roles = &.{ "admin", "dev" },
    };

    // Initialize the wrapper, which allocates and merges the data.
    var user = try UserWrapper.init(gpa, &user_data);
    defer user.deinit(gpa);

    // Get a pointer to the merged data.
    const p = user.get();
    std.debug.print("User ID: {d}, Name: {s}\n", .{ p.id, p.name });

    // The data is fully self-contained in one memory block.
    std.debug.print("Total size of single allocation: {d} bytes\n", .{user.memory.len});
}
```

# Table of Contents
* [Why OneAlloc?](#why-onealloc)
* [Installation](#installation)
* [The Wrapper](#the-wrapper)
  - [Initialization & Cleanup](#initialization--cleanup)
  - [Accessing Data](#accessing-data)
  - [Updating Data](#updating-data)
* [Configuration (ToMergedOptions)](#configuration-tomergedoptions)
* [How It Works: Memory Layout](#how-it-works-memory-layout)
* [Handling Recursion](#handling-recursion)

# Why OneAlloc?
Structs containing several slices / pointers can lead to poor performance due to scattered memory access patterns, which is bad for CPU caching. It also makes managing the lifetime of the object complex.

OneAlloc solves this by introspecting a given type at compile-time and creating a specialized opaque that lays out the entire object, including all its pointed-to data, into a **single contiguous block of memory.**

# Installation
1) Add OneAlloc as a dependency in your `build.zig.zon`.

```bash
zig fetch --save "git+https://github.com/ItsMeSamey/onealloc#main"
```

2) In your `build.zig`, add the `onealloc` module as a dependency to your program:

```zig
const onealloc_dep = b.dependency("onealloc", .{
    .target = target,
    .optimize = optimize,
});

// For your executable from b.addExecutable(...)
exe.root_module.addImport("onealloc", onealloc_dep.module("onealloc"));
```

# The Wrapper
The primary way to use the library is through the `onealloc.SimpleWrapper(options)` generic struct. It provides a high-level, safe API for managing the merged memory block.

```zig
// Define the type and options for the wrapper
const MyTypeWrapper = onealloc.SimpleWrapper(.{ .T = MyType });

// Now use it like any other type
var my_wrapped_object = try MyTypeWrapper.init(allocator, &my_value);
defer my_wrapped_object.deinit(allocator);
```

## Initialization & Cleanup
The `SimpleWrapper` owns the memory block and must be managed carefully.

#### `init(allocator, *const T) !SimpleWrapper`
Allocates a single block of memory of the exact required size and merges the `value` into it. Returns the `SimpleWrapper` instance.

#### `deinit(allocator)`
Frees the memory block owned by the wrapper. Must be called to prevent memory leaks.

#### `getSize(*const T) usize`
A static method that calculates the total memory size (static + dynamic) required to for a given value.

```zig
const size = UserWrapper.getSize(&user_data);
const memory = try allocator.alignedAlloc(u8, UserWrapper.MergedT.Signature.alignment.toByteUnits(), size);
// ... you could then initialize a wrapper with this memory manually.
```

## Accessing Data

#### `get() *T`
Returns a pointer to the merged data. This pointer is valid until `deinit()` or `set()` is called. The data is mutable through this pointer but resizing of slices is not possible.

```zig
var user = try UserWrapper.init(allocator, &user_data);
defer user.deinit(allocator);

// Get a mutable pointer and change a field.
user.get().id = 5678;

try testing.expect(user.get().id == 5678);
```

## Updating Data

#### `set(allocator, *const T) !void`
Overwrites the data in the wrapper with a new value. This may reallocate the entire memory block if the new value requires a different amount of dynamic space. All previous pointers obtained from `get()` are invalidated.

#### `setAssert(*const T)`
Same as `set`, but asserts that the existing allocation is large enough to hold the new value.

#### `clone(allocator) !SimpleWrapper`
Creates a new, completely independent `Wrapper` instance with a deep copy of the original's data.

```zig
var wrapped1 = try UserWrapper.init(allocator, &user_data);
var wrapped2 = try wrapped1.clone(allocator);
defer wrapped1.deinit(allocator);
defer wrapped2.deinit(allocator);

// wrapped2 is a deep copy, not a reference
try testing.expect(wrapped1.memory.ptr != wrapped2.memory.ptr);
```

# Configuration (ToMergedOptions)
You control the merging process by passing a `ToMergedOptions` struct to `onealloc.SimpleWrapper()`.

*   `.T: type` (Required)
    The struct, union, or other type that you want to merge.

*   `.dereference: bool = true`
    If `true`, the library will traverse through single-item pointers (`*T`, `?*T`) and merge the data they point to. If `false`, pointers are treated as raw values (`usize`) and their data is not merged.

*   `.recurse: bool = true`
    If `true`, the library will traverse into the fields of nested structs and unions. If `false`, nested structs/unions are treated as opaque blocks of data.

*   `.deslice: comptime_int = 1024`
    Controls how many levels of nested slices or pointers are expanded. For example, given `[][]const u8`:
    *   `deslice = 1`: The top-level slice is merged, containing pointers to the inner `[]const u8` strings.
    *   `deslice = 2`: The top-level slice is merged, and all the inner strings are also merged into the dynamic block.

*   `.allow_recursive_rereferencing: bool = false`
    Set this to `true` to handle recursive data structures, like linked lists or graphs. See [Handling Recursion](#handling-recursion).

# How It Works: Memory Layout
OneAlloc divides the single memory block into two sections:

`[ Static Buffer | Dynamic Buffer ]`

*   **Static Buffer:** This part has a fixed size determined at compile-time based on the type `T`. It holds all the fixed-size fields (`u32`, `bool`, etc.) and the "headers" for dynamic types (i.e., the `ptr` and `len` of a slice).
*   **Dynamic Buffer:** This immediately follows the static buffer. It holds all the variable-sized data that the static part's pointers and slices point to. For example, the characters of a `[]const u8` would be stored here.

The pointers within the static buffer are updated to point to their corresponding data within the dynamic buffer, making the entire block self-contained.

# Handling Recursion
By default, the library will throw a compile error if it detects a recursive type definition.
To handle types like linked lists, you must set the `.allow_recursive_rereferencing` option to `true`.

> [!Warning]
> Data cycles are not currently supported. 
> eg. cyclic linked list would crash the application due to stack overflow

```zig
const Node = struct {
    payload: u32,
    next: ?*const @This(), // Recursive field
};

// This requires the option to be enabled.
const NodeWrapper = onealloc.SimpleWrapper(.{
    .T = Node,
    .allow_recursive_rereferencing = true,
});

const n2 = Node{ .payload = 2, .next = null };
const n1 = Node{ .payload = 1, .next = &n2 };

var wrapped_node = try NodeWrapper.init(allocator, &n1);
defer wrapped_node.deinit(allocator);

// The entire linked list is now in one memory block.
const p = wrapped_node.get();
try testing.expect(p.payload == 1);
try testing.expect(p.next.?.payload == 2);
try testing.expect(p.next.?.next == null);
```

OR

```zig
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

const List = onealloc.SimpleWrapper(.{ .T = NodeA, .allow_recursive_rereferencing = true });

// List with doubley recursive types merged into a contiguous allocation
const copy = SimpleWrapper.init(allocator, a1);
```
