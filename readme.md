# OneAlloc: Allocate Everything All At Once

A simple library to convert complex data structures with pointers and slices into a single, contiguous memory allocation.

It is ideal for scenarios where data locality is critical, such as preparing data for IPC, caching, etc. It also provides helpers to make data.

Merged memory is **portable** and self-contained. It may be used for:
*   On-disk serialization.
*   Inter-process communication (IPC).
*   Network transport.

Do note that there are many options that make memory NOT self-contained, but this is not the case by default.

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

    // The Wrapper manages the allocation for the User type.
    const UserWrapper = onealloc.SimpleWrapper(.{ .T = User });
    
    var user_data = User{
        .id = 1234,
        .name = "Me",
        .roles = &.{ "admin", "dev" },
    };

    // Initialize the wrapper, which allocates and merges the data.
    var user = try UserWrapper.init(gpa, &user_data);
    defer user.deinit(gpa);

    // Get a pointer to the merged, self-contained data.
    const p = user.get();
    std.debug.print("User ID: {d}, Name: {s}\n", .{ p.id, p.name });

    // The data is now fully self-contained in a single memory block.
    std.debug.print("Total size of single allocation: {d} bytes\n", .{user.memory.len});
}
```

# ⚠️ Critical Usage Warning

This is **Still in Development**. The API is subject to change and this library probably has many bugs.
Feel free to play around with it, but do NOT use it in any serious projects and report any issues you encounter.

---

# Table of Contents
* [Why OneAlloc?](#why-onealloc)
* [Installation](#installation)
* [The `Wrapper`](#the-wrapper)
  - [Initialization & Cleanup](#initialization--cleanup)
  - [Accessing Data](#accessing-data)
  - [Updating Data](#updating-data)
* [Configuration (`SimpleOptions`)](#configuration-simpleoptions)
* [How It Works: Memory Layout](#how-it-works-memory-layout)
* [Handling Recursion](#handling-recursion)
* [Limitations & Caveats](#limitations--caveats)

# Why OneAlloc?
Structs containing several slices / pointers can lead to poor performance due to scattered memory access patterns, which is bad to CPU caching.
It also makes managing the lifetime of the object simpler.

OneAlloc solves this by introspecting a given type at compile-time and creating a specialized opaque type that lays out the entire object, including all its pointed-to data into a **single contiguous block of memory.**

# Installation
1.  Add OneAlloc as a dependency in your `build.zig.zon`.

    ```sh
    zig fetch --save "git+https://github.com/ItsMeSamey/onealloc#main"
    ```

2.  In your `build.zig`, add the `onealloc` module as a dependency to your program:

    ```zig
    const onealloc_dep = b.dependency("onealloc", .{
        .target = target,
        .optimize = optimize,
    });

    // For your executable from b.addExecutable(...)
    exe.root_module.addImport("onealloc", onealloc_dep.module("onealloc"));
    ```

# The `Wrapper`
The primary way to use the library is through the `onealloc.SimpleWrapper(options)` generic struct. It provides a high-level API for managing the merged memory block.

```zig
// Define the type and options for the wrapper
const MyTypeWrapper = onealloc.SimpleWrapper(.{ .T = MyType });

// Now use it like any other type
var my_wrapped_object = try MyTypeWrapper.init(allocator, &my_value);
defer my_wrapped_object.deinit(allocator);
```

## Initialization & Cleanup
The `SimpleWrapper` owns the memory block and its lifetime must be managed carefully.

#### `init(allocator, *const T) !SimpleWrapper`
Allocates a single block of memory of the exact required size and merges the `value` into it. Returns the `SimpleWrapper` instance.

#### `deinit(allocator)`
Frees the memory block owned by the wrapper. Must be called to prevent memory leaks.

#### `getSize(*const T) usize` (static)
A static method that calculates the total memory size (static + dynamic) required to store a given value.

```zig
const size = UserWrapper.getSize(&user_data);
std.debug.print("Calculated size: {d}\n", .{size});
const memory = try allocator.alignedAlloc(u8, UserWrapper.Underlying.Signature.alignment.toByteUnits(), size);
// ... you could then initialize a wrapper with this memory manually.
```

## Accessing Data

#### `get() *T`
Returns a mutable pointer to the merged data. This pointer is valid until `deinit()` or `set()` is called.
The data can be mutated through this pointer, but resizing slices is not possible as it would invalidate the memory layout.

```zig
var user = try UserWrapper.init(allocator, &user_data);
defer user.deinit(allocator);

// Get a mutable pointer and change a field.
user.get().id = 5678;

try testing.expect(user.get().id == 5678);
```

## Updating Data

#### `set(allocator, *const T) !void`
Overwrites the data in the wrapper with a new value.
This may reallocate the entire memory block if the new value requires a different amount of dynamic space.
All previous pointers obtained from `get()` are invalidated.

#### `setAssert(*const T) void`
Same as `set`, but asserts that the existing allocation is large enough to hold the new value, avoiding a potential reallocation.

#### `clone(allocator) !SimpleWrapper`
Creates a new `Wrapper` instance with a deep copy of the original's data.

```zig
var wrapped1 = try UserWrapper.init(allocator, &user_data);
var wrapped2 = try wrapped1.clone(allocator);
defer wrapped1.deinit(allocator);
defer wrapped2.deinit(allocator);

// wrapped2 is a deep copy, not a reference
try testing.expect(wrapped1.memory.ptr != wrapped2.memory.ptr);
```

# Configuration (`SimpleOptions`)
You control the merging process by passing a `SimpleOptions` struct to `onealloc.SimpleWrapper()`.

*   `.T: type` (Required)
    The struct, union, or other type that you want to merge.

*   `.dereference: bool` (Default: `true`)
    If `true`, the library will traverse through single-item pointers (`*T`, `?*T`) and merge the data they point to. If `false`, pointers are copied by value without being followed.

*   `.recurse: bool = true`
    If `true`, the library will traverse into the fields of nested structs and unions. If `false`, nested structs/unions are treated as blocks of data and copied directly.

*   `.deslice: comptime_int = 1024`
    Controls how many levels of nested slices are recursively merged.
    For a `[][]const u8`:
    *   `deslice = 1`: The outer slice's is merged, and it points to a dynamic block containing the inner slices (pointers and lengths).
    *   `deslice = 2`: Both the outer and inner slices are fully merged. The dynamic block contains the character data of all inner strings.

*   `.allow_recursive_rereferencing: bool = false`
    Set this to `true` to handle recursive data structures like linked lists or graphs. See [Handling Recursion](#handling-recursion).

# How It Works: Memory Layout
OneAlloc divides the single memory block into two sections:

`[ Static Buffer | Dynamic Buffer ]`

*   **Static Buffer:** This part has a fixed size determined at compile-time based on the type `T`. It holds all fixed-size fields (`u32`, `bool`, etc.) and the "headers" for dynamic types (i.e., the `ptr` and `len` of a slice).
*   **Dynamic Buffer:** This immediately follows the static buffer. It holds all the variable-sized data that the static part's pointers and slices now point to. For example, the characters of a `[]const u8` are stored here.

The pointers within the static buffer are updated to point to their corresponding data within the dynamic buffer, making the entire block self-contained.

# Handling Recursion
By default, the library will throw a compile error if it detects a recursive type definition.
To handle types like linked lists, you must set the `.allow_recursive_rereferencing` option to `true`.

> [!WARNING]
> **Data cycles are not supported.**
> An attempt to merge a data structure with a cycle (e.g., a circular linked list) will result in a stack overflow at runtime.

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

A more complex example involving mutual recursion:
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

// ...
const ListWrapper = onealloc.SimpleWrapper(.{ 
    .T = Namespace.NodeA,
    .allow_recursive_rereferencing = true 
});

// ...
```

# Limitations & Caveats

### 1. ⚠️ Unsafe Memory Layout Assumptions
The biggest caveat of this library is that it makes assumptions about the internal memory layout of
`union`, `optional`, and `error union` types to store their tag/error values alongside the static data.

**These layouts are not guaranteed by the Zig language specification.** This means the library's behavior is fragile and **may break with future versions of the Zig compiler**, potentially leading to memory corruption. This is currently the only way to achieve this functionality without modifying the types themselves.

### 2. Data Cycles Cause Stack Overflow
As mentioned above, attempting to merge a data structure with a cycle will cause infinite recursion and crash the program.

### 3. Unsupported Types
The following types cannot be merged or have limited support:
*   **Dynamic Packed Structs (with Pointers):** These are not supported and will cause a compile error.
*   **Dynamic Untagged Unions (with Pointers/Slices):** These lack a tag and cannot be safely merged. They will cause a compile error.

