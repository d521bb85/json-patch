# json-patch

A complete implementation of [JSON Patch (RFC 6902)](https://www.rfc-editor.org/rfc/rfc6902)
and [JSON Pointer (RFC 6901)](https://www.rfc-editor.org/rfc/rfc6901) for Zig, with no dependencies.

Instead of parsing a whole document into a tree, it keeps every value as a slice of the
original text and looks inside only the containers a patch passes through. Everything else is
skipped by a bit-parallel scanner and copied to the output untouched.

- **Atomic.** A patch that fails leaves the document as it was, with no copy made up front.
- **Lossless.** Untouched values come out byte for byte, so formatting and number precision survive.
- **Exact.** Numbers compare by true numeric value at any size, as RFC 6902 requires, not through `f64`.
- **Safe on hostile input.** Nesting is limited, and no patch can overflow the stack.

## Install

Requires Zig 0.17.0.

```bash
zig fetch --save git+https://github.com/d521bb85/json-patch
```

Then, in `build.zig`:

```zig
const json_patch = b.dependency("json_patch", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("json_patch", json_patch.module("json_patch"));
```

## Usage

### One document, one patch

```zig
const json_patch = @import("json_patch");

const result = try json_patch.apply(gpa,
    \\{"name": "zig", "tags": ["fast"]}
,
    \\[
    \\  {"op": "replace", "path": "/name", "value": "json-patch"},
    \\  {"op": "add", "path": "/tags/-", "value": "safe"}
    \\]
, .{});
defer gpa.free(result);
```

### Keeping a document and applying many patches

```zig
var doc: json_patch.Document = try .parse(gpa, text, .{});
defer doc.deinit();

var patch: json_patch.Patch = try .parse(gpa, patch_text, .{});
defer patch.deinit();

var diagnostics: json_patch.Diagnostics = .{};
doc.apply(&patch, .{ .diagnostics = &diagnostics }) catch |err| {
    // The document is unchanged. `diagnostics.operation` is the index of the
    // operation that failed.
    return err;
};

const balance = try doc.get("/account/balance"); // JSON text, or null if absent
try writer.print("{f}", .{&doc}); // or doc.toOwnedSlice(gpa)
```

A `Patch` is not changed by being applied, so one patch can be used on many documents, from
several threads at once. A `Document` must be used from one thread at a time, even for reads.

### Building a patch in code

Values are anything `std.json.Stringify` accepts, and escaping is handled for you.

```zig
var patch: json_patch.Patch = .init(gpa);
defer patch.deinit();

try patch.testValue("/version", 3);
try patch.replace("/version", 4);
try patch.add("/users/-", .{ .name = "Ada", .admin = true });
try patch.move("/draft", "/published");
try patch.copy("/published", "/backup");
try patch.remove("/stale");
try patch.add("/settings", json_patch.Patch.Raw{ .json = "{\"theme\":\"dark\"}" });

try writer.print("{f}", .{patch}); // the patch as RFC 6902 JSON
```

### Reading values into Zig types

`Document.get` returns JSON text, which `std.json` can parse into any type:

```zig
const text = (try doc.get("/users/0")).?;
const user = try std.json.parseFromSlice(User, gpa, text, .{});
defer user.deinit();
```

## Options for databases

These trade convenience for speed where the caller can guarantee something:

| Option | Effect | Requirement |
| --- | --- | --- |
| `Document.ParseOptions.validation = .none` | Parsing takes constant time | The text is known to be valid JSON, for example because it was validated when it was stored. Invalid text is memory safe, but can cause `error.SyntaxError` or invalid output. |
| `Document.ParseOptions.source = .borrow` | The document is not copied | The text outlives the `Document` |
| `Patch.ParseOptions.source = .borrow` | The patch is not copied | The text outlives the `Patch` |
| `Document.ApplyOptions.values = .borrow` | Values are not copied into the document | The `Patch` outlives the `Document` |

Memory for values replaced by a patch is held until `deinit`. A long-lived document can call
`compact` to release it.

## Behavior where the RFCs leave room

| Case | Behavior |
| --- | --- |
| Duplicate keys in a document | The last one wins, as in most parsers. `remove` removes all of them. |
| Duplicate `op`, `path`, `from`, or `value` in an operation | Rejected, when the member applies to that operation. |
| Removing the root | Allowed mid-patch, so a later `add` at `""` can restore it. A patch that ends with no root fails with `error.RootRemoved`. |
| Lone surrogates such as `"\ud800"` | Rejected, matching `std.json`. |
| Byte order marks | Rejected. |
| Nesting | Limited to 1024 levels by default, adjustable up to 65535 with `max_depth`. A patch can still build a deeper document, which needs a higher `max_depth` to be parsed again. |
| Key order | Preserved. New keys go at the end. |
| Number formatting | Preserved. Numbers from a patch are written as they were spelled in the patch. |

## Errors

Parsing a patch can fail with `error.SyntaxError`, `NestingTooDeep`, `NotAnArray`, `NotAnObject`,
`MissingMember`, `DuplicateMember`, `InvalidMemberType`, `UnknownOperation`, `InvalidPointer`, or
`MoveIntoDescendant`.

Applying one can fail with `error.PathNotFound`, `InvalidArrayIndex`, `IndexOutOfBounds`,
`TestFailed`, `RootRemoved`, or `OutOfMemory`, and with `SyntaxError` if the document skipped
validation.

## Testing

```bash
zig build test
```

- **Conformance:** every case in the [community test suite](https://github.com/json-patch/json-patch-tests),
  including those it marks as disabled, run in each ownership and validation mode.
- **Differential:** random documents and patches are checked against a naive reference
  implementation that shares no code with the library, including that failed patches change nothing.
- **Fuzzing:** `zig build test --fuzz` feeds arbitrary bytes to the parsers.

## Performance

Each number below is the full path from JSON text to JSON text: parse the document, parse the
patch, apply it, and write the result. Times are medians on an Apple M5, with every library built
for speed (`ReleaseFast`, `-O3 -flto`, or `--release` with LTO), and each result is checked against
the expected output, so an incorrect result cannot appear as a fast one.

| Workload | Document | Ops | This library | This library, trusted | [yyjson](https://github.com/ibireme/yyjson) | Rust `json-patch` | Node `fast-json-patch` | Go `evanphx/json-patch` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `small` | 544 B | 4 | 0.8 µs | **0.6 µs** | 0.8 µs | 2.5 µs | 4.2 µs | 12.7 µs |
| `medium` | 84 KB | 8 | 58 µs | **22 µs** | 64 µs | 227 µs | 203 µs | 846 µs |
| `twitter` | 467 KB | 8 | 260 µs | **103 µs** | 263 µs | 930 µs | 1.15 ms | 4.9 ms |
| `citm_catalog` | 500 KB | 8 | 379 µs | **144 µs** | 382 µs | 1.48 ms | 3.05 ms | 5.4 ms |
| `pretty` | 2.7 MB | 8 | 1.61 ms | **0.61 ms** | 1.63 ms | 4.9 ms | 10.6 ms | 26.1 ms |
| `large` | 17 MB | 8 | 12.1 ms | **4.8 ms** | 19.1 ms | 48.2 ms | 101 ms | 173 ms |
| `keyed` | 17 MB | 8 | 13.1 ms | **5.4 ms** | 22.4 ms | 54.7 ms | 115 ms | 188 ms |
| `many_ops` | 84 KB | 1000 | 211 µs | 175 µs | 176 µs | 589 µs | 10 ms | rejected |

- **Trusted** sets `.validation = .none`, for documents already known to be valid, such as those a
  database stored earlier. The other libraries validate their input, so this column is not a
  like-for-like comparison with them.
- **The default mode** is a like-for-like comparison. Against yyjson, the closest competitor, it
  is within 2% on `small`, `twitter`, `citm_catalog`, and `pretty`, about 10% faster on `medium`,
  37-41% faster on `large` and `keyed`, and about 20% slower on `many_ops`. That workload is the worst
  case for lazy expansion, because a patch that touches much of a document gets little from
  skipping the rest. In trusted mode, `many_ops` is a tie with yyjson within measurement noise.
- **"Rejected"** means that library refused a valid patch. `evanphx/json-patch` 5.9.11 fails a `test`
  on an object after one of its members has been `replace`d with `null`.
- These are the versions tested: yyjson 0.12.0, Rust `json-patch` 4.2.0 with `serde_json` 1.0.154,
  Node `fast-json-patch` 3.1.1 on Node 24, and Go 1.27 with `evanphx/json-patch` 5.9.11.
- Results are from one ARM machine, and only this workload set. x86 has not been measured.

Time still grows with document size, because validation reads every byte and expanding a container
has to scan it to find where each child ends. Skipping runs at about 12 GB/s and validation at
about 2.3 GB/s on this machine.

To reproduce these numbers, build the other implementations with `bench/build.sh`, which needs a
copy of the yyjson source plus cargo, go, and npm, then:

```bash
python3 bench/generate.py bench/data
```

```bash
python3 bench/run.py bench/data 2000
```

`zig-baseline` in that output is a conventional `std.json` implementation, for comparison.

## License

MIT. The files in `test/json-patch-tests` are from the community test suite and are under the
Apache License 2.0. They are not part of the package that consumers download.
