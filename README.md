# zig_interval

Closed-interval arithmetic over `f64` for Zig 0.16.

## Installation

Add the dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_interval = .{ .url = "<REPOSITORY_URL>", .hash = "<HASH>" },
},
```

`<REPOSITORY_URL>` and `<HASH>` are placeholders. Both values are assigned when
the package is published; run `zig fetch --save <url>` to have the toolchain
write a concrete stanza for you.

## Usage

The package exports a public module named `interval`. Import the `Interval` type
from it:

```zig
const std = @import("std");
const Interval = @import("interval").Interval;

pub fn main() void {
    const a = Interval.init(1.0, 3.0);
    const b = Interval.init(2.0, 5.0);
    const shared = a.intersect(b).?;          // [2, 3]
    const span = a.hull(b);                   // [1, 5]
    std.debug.print("{d} {d}\n", .{ shared.width(), span.midpoint() });
}
```

In your `build.zig`, wire that module into the module that needs it:

```zig
const dep = b.dependency("zig_interval", .{ .target = target, .optimize = optimize });
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
});
exe.root_module.addImport("interval", dep.module("interval"));
b.installArtifact(exe);
```

The dependency key `zig_interval` is the package name; the module name
`interval` is what `@import` resolves against.

## API reference

| Function | Semantics |
| --- | --- |
| `init(lo: f64, hi: f64) Interval` | Construct an interval; requires `lo <= hi`. |
| `contains(self: Interval, x: f64) bool` | Membership test, endpoints inclusive. |
| `hull(self: Interval, other: Interval) Interval` | Smallest interval covering both. |
| `hullOf(items: []const Interval) ?Interval` | Fold of `hull` over `items`; `null` for an empty slice. |
| `intersect(self: Interval, other: Interval) ?Interval` | Shared region; `null` when disjoint. |
| `intersectionOf(items: []const Interval) ?Interval` | Fold of `intersect` over `items`; `null` for an empty slice or a disjoint fold. |
| `width(self: Interval) f64` | `hi - lo`. |
| `overlaps(self: Interval, other: Interval) bool` | True when the two share at least one point. |
| `subsetOf(self: Interval, other: Interval) bool` | True when `self` is contained in `other`. |
| `midpoint(self: Interval) f64` | `(lo + hi) / 2`. |
| `clamp(self: Interval, x: f64) f64` | Clamp `x` into `[lo, hi]`. |
| `translate(self: Interval, delta: f64) Interval` | Shift both ends by `delta`. |
| `scale(self: Interval, factor: f64) Interval` | Scale the width about the midpoint by `\|factor\|`. |
| `expand(self: Interval, margin: f64) Interval` | Widen both ends by `margin`, or shrink both when it is negative; requires `margin >= -(hi - lo) / 2`, a more negative margin traps in Debug and ReleaseSafe. |
| `distanceTo(self: Interval, x: f64) f64` | `0` inside the interval, else the distance to the nearest endpoint. |

`scale` uses `|factor|` for the width, so a negative factor mirrors the width
without inverting the endpoints and the `lo <= hi` invariant still holds.

## Invariant

Every `Interval` satisfies `lo <= hi`. That holds for every value the library
returns, not only for ranges handed to `init`. `expand` builds its result
through `init`, so a margin that would invert the interval traps instead of
producing one; `hull` and `hullOf` take `lo` from a minimum and `hi` from a
maximum, `intersect` and `intersectionOf` guard their result with an explicit
`lo > hi` check, `translate` shifts both ends by the same delta, and `scale`
grows the width about the midpoint with `|factor|`. No public function can
return an inverted interval in a checked build.

`init` checks the invariant with `std.debug.assert`, which traps in Debug and
ReleaseSafe builds. The check is elided in ReleaseFast, so in fast builds the
caller is responsible for passing a valid range.

There is no separate empty-interval representation. Because `lo <= hi` always
holds, an empty result — an empty fold, or a disjoint intersection — is
signalled by `null` rather than by a sentinel interval.

## Build steps

| Step | Effect |
| --- | --- |
| `install` (default) | Installs the library artifact. |
| `test` | Runs the interval test suite and the external consumer fixture. |
| `consumer` | Builds and runs the external consumer fixture on its own. |
| `docs` | Emits API documentation. |

## Development

Run the test suite with:

```
zig build test
```

The `test` step also depends on `consumer`, which builds the standalone package
under `fixture/` against this one as a real dependency. That validates the
public module is registered and reachable through the dependency module graph,
not merely importable inside this repository.

## License

MIT. See [LICENSE](LICENSE).
