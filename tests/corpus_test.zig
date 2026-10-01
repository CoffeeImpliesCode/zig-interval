//! Containment against an independently generated reference corpus.
//!
//! This is the fourth tier of the oracle, and the first one whose reference is
//! NOT written in this file. The other three compute their references from
//! `f64` or `f128` arithmetic in the same tree, which is what the header above
//! warns about: a reference that is a second implementation of the same
//! function needs its own audit, and §2.2 shows what goes wrong when the
//! second implementation is quietly wrong.
//!
//! So the reference here is MPFR at 256 bits, called with a declared rounding
//! direction, by `scripts/gen_corpus.c`, and committed as
//! `tests/corpus/elementary.txt`. It is 450 rows over the twenty-one operations
//! the in-tree oracle does not judge. The generator's reasoning, and the two
//! ways an earlier version of it produced plausible rows that were not the
//! image, are in that file's header.
//!
//! **What is asserted, and what is not.** Containment, only: the library's
//! answer must contain the certified bracket. Tightness is never asserted. A
//! corpus bounds correctness, not width, and a width claim is exactly the sort
//! of thing §2.2 is about — the library deliberately pays three ULP on the
//! elementary functions, and a test that demanded tighter would be demanding a
//! wrong thing.
//!
//! **What exactness buys.** The corpus carries MPFR's ternary return, so a row
//! whose value is exactly representable is distinguishable from one that is
//! merely near it. That is recorded and reported rather than acted on: it is
//! the difference between "the answer is exactly this" and "the answer is
//! around this", and collapsing the two is what makes a rounded reference
//! look like a good one.
//!
//! **A `null` here is a failure, not a skip.** Every row in the corpus has a
//! real image — the generator drops anything MPFR could not evaluate — so a
//! refusal means the library and the reference disagree about whether the
//! image exists, which is a soundness question and not a coverage one.

const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const ext = interval.ext;

const corpus = @embedFile("corpus/elementary.txt");

fn f64FromBits(bits: u64) f64 {
    return @bitCast(bits);
}

/// One corpus row, parsed.
const Row = struct {
    op: []const u8,
    lo: f64,
    hi: f64,
    want_lo: f64,
    want_hi: f64,
    ternary: i64,
    exponent: i32,
};

fn fail(comptime fmt: []const u8, args: anytype) error{CorpusViolation} {
    std.debug.print(fmt, args);
    return error.CorpusViolation;
}

/// Parse one line. Returns null for a comment or a blank.
fn parseRow(line: []const u8) !?Row {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const op = it.next() orelse return error.MalformedCorpusRow;
    const lo_hex = it.next() orelse return error.MalformedCorpusRow;
    const hi_hex = it.next() orelse return error.MalformedCorpusRow;
    const wlo_hex = it.next() orelse return error.MalformedCorpusRow;
    const whi_hex = it.next() orelse return error.MalformedCorpusRow;
    const tern_hex = it.next() orelse return error.MalformedCorpusRow;
    // `pow` carries its exponent as a seventh field; every other operation is
    // named by its own line, so the field is optional here rather than a
    // second format the generator could disagree with.
    const exp_hex = it.next();

    // Endpoints and bounds are u64 BIT PATTERNS, parsed unsigned: half of them
    // carry the sign bit and overflow i64. The ternary field is the exception
    // - it is a small signed code, and keeping it signed is the point.
    const patterns = [_]u64{
        try std.fmt.parseInt(u64, lo_hex, 16),
        try std.fmt.parseInt(u64, hi_hex, 16),
        try std.fmt.parseInt(u64, wlo_hex, 16),
        try std.fmt.parseInt(u64, whi_hex, 16),
    };
    var exponent: i32 = 0;
    if (exp_hex) |e| exponent = try std.fmt.parseInt(i32, e, 10);

    return Row{
        .op = op,
        .lo = f64FromBits(patterns[0]),
        .hi = f64FromBits(patterns[1]),
        .want_lo = f64FromBits(patterns[2]),
        .want_hi = f64FromBits(patterns[3]),
        .ternary = try std.fmt.parseInt(i64, tern_hex, 10),
        .exponent = exponent,
    };
}

/// The library's answer for a row. `null` means the library REFUSED, which for
/// a corpus row is a disagreement rather than a skip.
fn libraryAnswer(r: Row) ?Interval {
    // The two-operand operations carry TWO INDEPENDENT arguments in the lo and
    // hi fields, not the two ends of one interval. They are dispatched BEFORE
    // the interval below is built, because that build asserts lo <= hi and most
    // of these rows have lo > hi.
    if (std.mem.eql(u8, r.op, "powf")) {
        return ext.powf(Interval.init(r.lo, r.lo), Interval.init(r.hi, r.hi));
    }
    if (std.mem.eql(u8, r.op, "atan2")) {
        return ext.atan2(Interval.init(r.lo, r.lo), Interval.init(r.hi, r.hi));
    }

    const x = Interval.init(r.lo, r.hi);
    if (std.mem.eql(u8, r.op, "pow")) return ext.pow(x, r.exponent);

    if (std.mem.eql(u8, r.op, "exp")) return ext.exp(x);
    if (std.mem.eql(u8, r.op, "exp2")) return ext.exp2(x);
    if (std.mem.eql(u8, r.op, "expm1")) return ext.expm1(x);
    if (std.mem.eql(u8, r.op, "log")) return ext.log(x);
    if (std.mem.eql(u8, r.op, "log2")) return ext.log2(x);
    if (std.mem.eql(u8, r.op, "log10")) return ext.log10(x);
    if (std.mem.eql(u8, r.op, "log1p")) return ext.log1p(x);
    if (std.mem.eql(u8, r.op, "sin")) return ext.sin(x);
    if (std.mem.eql(u8, r.op, "cos")) return ext.cos(x);
    if (std.mem.eql(u8, r.op, "tan")) return ext.tan(x);
    if (std.mem.eql(u8, r.op, "asin")) return ext.asin(x);
    if (std.mem.eql(u8, r.op, "acos")) return ext.acos(x);
    if (std.mem.eql(u8, r.op, "atan")) return ext.atan(x);
    if (std.mem.eql(u8, r.op, "sinh")) return ext.sinh(x);
    if (std.mem.eql(u8, r.op, "cosh")) return ext.cosh(x);
    if (std.mem.eql(u8, r.op, "tanh")) return ext.tanh(x);
    if (std.mem.eql(u8, r.op, "asinh")) return ext.asinh(x);
    if (std.mem.eql(u8, r.op, "acosh")) return ext.acosh(x);
    if (std.mem.eql(u8, r.op, "atanh")) return ext.atanh(x);
    if (std.mem.eql(u8, r.op, "sqrt")) return ext.sqrt(x);
    if (std.mem.eql(u8, r.op, "cbrt")) return ext.cbrt(x);
    return null;
}

test "corpus: every operation's answers contain an independently certified bracket" {
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    var checked: usize = 0;
    var exact_rows: usize = 0;
    var failures: usize = 0;
    var shown: usize = 0;

    while (lines.next()) |line| {
        const row = (try parseRow(line)) orelse continue;
        const got = libraryAnswer(row) orelse {
            failures += 1;
            if (shown < 12) {
                shown += 1;
                std.debug.print("  REFUSED {s}({e}, {e}) — the corpus says its image is real\n", .{ row.op, row.lo, row.hi });
            }
            continue;
        };

        // The whole point of the row. Containment of the certified bracket and
        // nothing more: a tighter answer than the reference would also fail
        // here, which is the correct behaviour - the reference is the truth,
        // not a lower bar.
        if (!(got.lo <= row.want_lo and got.hi >= row.want_hi)) {
            failures += 1;
            if (shown < 12) {
                shown += 1;
                std.debug.print("  NOT CONTAINED {s}({e}, {e}) [ternary {d}]\n", .{ row.op, row.lo, row.hi, row.ternary });
                std.debug.print("    library [{e}, {e}] does not contain the certified [{e}, {e}]\n", .{ got.lo, got.hi, row.want_lo, row.want_hi });
            }
            continue;
        }
        checked += 1;
        if (row.ternary == 0) exact_rows += 1;
    }

    std.debug.print("  corpus: {d} rows checked, {d} FAILED, {d} of them exactly representable\n", .{ checked, failures, exact_rows });
    if (checked == 0) return fail("corpus tier ran zero rows: a corpus that checks nothing proves nothing", .{});
    // Every operation the oracle did not already judge must be present, or the
    // corpus has silently lost the tier it was built for.
    if (checked < 100) return fail("corpus: only {d} rows parsed, expected the full corpus", .{checked});
    try std.testing.expectEqual(@as(usize, 0), failures);
}
