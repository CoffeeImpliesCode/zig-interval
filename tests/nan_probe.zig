//! A process that performs exactly one interval operation and does nothing
//! else, so that the only thing it reports is whether it survived.
//!
//! Why this is a separate program and not a test: the contract under test is
//! that a NaN scalar operand TRAPS, and a trap is an abort, not a return
//! value. Zig has no in-process panic expectation, so a test that called
//! `translate([1, 2], nan)` directly would abort the whole test binary the
//! moment the contract holds, taking every other test down with it. A test
//! asserting the opposite — that the call does NOT trap — aborts today, for
//! the same reason. Either way the abort lands on the fix rather than on the
//! bug, and a suite that punishes the fix is worse than no suite at all,
//! because the obvious response to it is to revert.
//!
//! In a child process the exit status is the signal and the abort is
//! contained, which makes this the only structure in which "this traps" is
//! expressible as a passing test. That is the whole reason for the shape.
//! DO NOT inline this into a test: the booby trap is one line away, and the
//! contract is easiest to destroy that way.
//!
//! Usage: `nan_probe <operation> <f64>`. The scalar is parsed with
//! `std.fmt.parseFloat`, so "nan" arrives as the same NaN any caller would
//! produce rather than as a bit pattern smuggled past the parser.

const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;

/// Exit status for arguments this probe cannot act on. Deliberately not
/// zero: a run that never reached the operation must never be readable as a
/// run that survived it, and the parent test's control invocation is what
/// turns that mistake into a failure rather than a pass.
const usage_status: u8 = 2;

/// The interval every operation is performed on. Well formed, so the scalar
/// is the only thing under test.
const base: Interval = Interval.init(1.0, 2.0);

/// A degenerate operand carrying `value` at both endpoints, which is how a
/// NaN scalar reaches the two-operand operations.
///
/// A struct literal and not `Interval.init`, deliberately. `init` is itself
/// the trap site, so staging the NaN through it would move the abort out of
/// the operation under test and into this probe's setup, and `add` would then
/// report a trap it never performed. Hand-building the operand is also how a
/// poisoned interval actually arrives from outside the type: a scalar read
/// off some earlier computation, not an interval anybody produced through the
/// checked constructor.
fn poison(value: f64) Interval {
    return .{ .lo = value, .hi = value };
}

/// One operation, and the name the parent test passes on the command line.
const Op = struct {
    name: []const u8,
    /// Performs exactly one call with `value` as the offending scalar.
    /// Returning at all means the call did not trap.
    apply: *const fn (f64) void,
};

fn doAdd(value: f64) void {
    _ = base.add(poison(value));
}

fn doSub(value: f64) void {
    _ = base.sub(poison(value));
}

fn doMul(value: f64) void {
    _ = base.mul(poison(value));
}

fn doDiv(value: f64) void {
    _ = base.div(poison(value));
}

fn doScale(value: f64) void {
    _ = base.scale(value);
}

fn doExpand(value: f64) void {
    _ = base.expand(value);
}

fn doTranslate(value: f64) void {
    _ = base.translate(value);
}

/// `neg` takes no scalar, so the only way a NaN reaches it is as an endpoint
/// of the interval it is called on. The value goes into the upper endpoint,
/// which is the endpoint `neg` hands to `init` first: a NaN there fails the
/// ordering before the lower one is even looked at.
fn doNeg(value: f64) void {
    const boxed: Interval = .{ .lo = base.lo, .hi = value };
    _ = boxed.neg();
}

/// The operations the contract names. The parent test walks its own copy of
/// this list, so an operation dropped from here surfaces as a failed control
/// over there rather than as a quietly shortened sweep.
const ops = [_]Op{
    .{ .name = "add", .apply = doAdd },
    .{ .name = "sub", .apply = doSub },
    .{ .name = "mul", .apply = doMul },
    .{ .name = "div", .apply = doDiv },
    .{ .name = "scale", .apply = doScale },
    .{ .name = "expand", .apply = doExpand },
    .{ .name = "translate", .apply = doTranslate },
    .{ .name = "neg", .apply = doNeg },
};

/// The operation named `name`, or null when there is none.
fn findOp(name: []const u8) ?*const Op {
    for (&ops) |*op| {
        if (std.mem.eql(u8, op.name, name)) return op;
    }
    return null;
}

pub fn main(init: std.process.Init) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 3) {
        std.debug.print("usage: nan_probe <operation> <f64>\n", .{});
        return usage_status;
    }
    const op = findOp(argv[1]) orelse {
        std.debug.print("nan_probe: no operation named '{s}'\n", .{argv[1]});
        return usage_status;
    };
    const value = std.fmt.parseFloat(f64, argv[2]) catch {
        std.debug.print("nan_probe: '{s}' is not an f64\n", .{argv[2]});
        return usage_status;
    };

    op.apply(value);
    return 0;
}
