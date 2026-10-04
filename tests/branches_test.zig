//! The branch carrier: caller-buffer choice maps, generic sets and writers,
//! the typed lifting seams, and the real split producers.
//!
//! A branch map here is not bookkeeping. It is the only thing standing
//! between a set of alternatives and a hull that quietly destroys the
//! mathematics: `floor([0.9, 1.1])` is `{0, 1}` and not `[0, 1]`; `1/x`
//! over `[-1, 1]` is two rays and not `[-inf, inf]`; and once two
//! alternatives share a site, only the pairings that agree on that site are
//! the ones the caller may combine. So every test below asserts the
//! ALTERNATIVES and the METADATA that goes with them, and a test that only
//! counted pieces would pass just as well for a library that had merged
//! them.
//!
//! Three distinctions carry most of the weight, because losing any one of
//! them is silent:
//!
//!   * An empty result and a resource failure are different answers. A set
//!     with no pieces is a mathematical statement; `error.CapacityExceeded`
//!     is a statement about the caller's buffers. A failure restores the
//!     writer to the counts it had on entry and publishes nothing of the
//!     operation that failed.
//!   * Sites are the caller's own integers and choices are `i128`, not a
//!     bit. `18446744073709551615` and `-170141183460469231731687303715884105727`
//!     are ordinary site and choice values here, and they survive a merge
//!     unchanged. So does a map of FORTY bindings: there is no walk budget
//!     over a branch map anywhere in this library, so a suite that only ever
//!     used two or three bindings would not notice one.
//!   * A site denotes the same operator on the same arguments in the same
//!     evaluation. Two calls of `floor` on the SAME input at the SAME site
//!     describe the SAME cell and are correlated: their compatible pairings
//!     give `{0, 2}`, and the mixed sum `1` never appears. Give the second
//!     call a different site and every combination is live again, `1`
//!     included. The library does not police which of those two cases a
//!     caller is in -- different arguments at one site is a documented
//!     precondition violation -- but the pairing rule it does implement has
//!     to behave this way in both directions.
//!
//! Two producers carry the domain questions, and both are checked for the
//! same thing: the alternative is split, the GAP in the image is kept, and
//! the metadata is not promoted. `1/x` over `[-1, 1]` gives the negative
//! ray `[-inf, -1]` and the positive ray `[1, inf]`, and neither piece may
//! report `defined = always` because membership in the original box is
//! uncertain there -- the point `0` of that box has no image. `tan` over
//! `[1.5, 1.6]`, which straddles the pole at `pi/2`, gives two separated
//! rays and keeps both `defined` and `continuous` uncertain. `tan` over
//! `[0.4, 0.6]`, which contains no pole, is one piece and is continuous:
//! the uncertainty is the mathematics of that box, not a standing hedge.
//!
//! Where a value is not a binary number -- a square root of two, an inverse
//! trigonometric branch -- it is checked by CONTAINMENT against a coarse
//! bracket and by a ROUND TRIP through the forward function, never against
//! a rounded literal, which would pin the width of the enclosure instead of
//! its correctness.

const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const Tracked = interval.Tracked;
const Truth = interval.Truth;
const branches = interval.branches;
const trig = interval.trig;

const inf = std.math.inf(f64);

const Assignment = branches.Assignment;
const Choice = branches.Choice;
const Site = branches.Site;
const Piece = branches.Piece;
const Set = branches.Set;
const Writer = branches.Writer;

const TSet = Set(Tracked);
const TPiece = Piece(Tracked);
const TWriter = Writer(Tracked);

/// A one-piece set over `x` with no bindings: the starting point of most
/// producer calls below.
fn leafSet(buf: *[1]TPiece, x: Tracked) TSet {
    buf[0] = .{ .value = x, .assignments = &.{} };
    return .{ .pieces = buf[0..] };
}

// ---------------------------------------------------------------------------
// Value-level helpers. Each compares NUMBERS or METADATA; none counts pieces
// on its own.
// ---------------------------------------------------------------------------

/// The choice recorded at `site`, or null when the site is absent.
fn choiceAt(assignments: []const Assignment, site: Site) ?Choice {
    for (assignments) |a| {
        if (a.site == site) return a.choice;
    }
    return null;
}

/// A piece value exactly: the enclosure and the two truths. A wholly
/// undefined value is asked only about its range and `defined`, because
/// nothing was computed and there is no continuity to report.
fn expectPiece(v: Tracked, lo: f64, hi: f64, defined: Truth, continuous: Truth) !void {
    if (defined == .never) {
        try std.testing.expect(v.range == null);
        try std.testing.expectEqual(Truth.never, v.defined);
        return;
    }
    const r = v.range orelse return error.MissingRange;
    try std.testing.expectEqual(lo, r.lo);
    try std.testing.expectEqual(hi, r.hi);
    try std.testing.expectEqual(defined, v.defined);
    try std.testing.expectEqual(continuous, v.continuous);
}

/// Assert `v` CONTAINS `[lo, hi]`: the bounds of the answer are asked to
/// contain those numbers, never to equal them, and never to exceed them.
///
/// Every call in this file passes an EXACT bracket -- two binary numbers
/// between which the true value provably lies, from an MPFR256 evaluation of
/// the value itself, or two endpoints the value actually attains -- and no
/// call adds slack to it. The rule is deliberate in both directions, and
/// both mistakes it prevents were in this file before it was reviewed:
///
///   * asking an answer to CONTAIN a bracket wider than the value would be
///     asking it to be inflated, which no sound implementation owes;
///   * asking it to CONTAIN a bracket padded by a step demands one extra ULP
///     of width on the low side and one on the high side. A correctly
///     rounded outward enclosure of an exact bracket satisfies the bare
///     form, and nothing needs to be added to it.
///
/// The width claims in this file all run the other way: where an answer is
/// held to a bound from above, the bound is a value the mathematics puts
/// there, not a count of steps.
fn expectEncloses(v: Tracked, lo: f64, hi: f64) !void {
    const r = v.range orelse return error.MissingRange;
    try std.testing.expect(r.lo <= lo);
    try std.testing.expect(hi <= r.hi);
}

/// Assert `continuous` is not proved: the producer did not promote a
/// continuity the original box does not have, just because each of its own
/// preimage pieces is smooth.
///
/// This is `!= always` and not a negation of `upper()`. `upper()` answers
/// "could this be true", which holds of both `maybe` and `always`, so
/// negating it would demand `never`: a claim that the result is proved NOT
/// continuous. That is stronger than the contract asks, and for a piece that
/// still carries a range it contradicts the `Tracked` invariant that a range
/// is present exactly when the result is not wholly undefined. What the
/// contract asks is that continuity not be proved where the box has none,
/// and `maybe` is the honest answer there.
fn expectContinuityUncertain(v: Tracked) !void {
    try std.testing.expect(v.continuous != .always);
}

/// Assert `defined` is not proved, which is what a split over a box whose
/// membership is uncertain must report per piece: the zero that `1/x` has no
/// image at, or the pole `tan` has none at, lies inside the box the piece
/// came from, so the piece may not report itself defined everywhere. As
/// above, the test is `!= always` and not a negation of `upper()`.
fn expectDefinedUncertain(v: Tracked) !void {
    try std.testing.expect(v.defined != .always);
}

fn expectChoice(assignments: []const Assignment, site: Site, choice: Choice) !void {
    const found = choiceAt(assignments, site) orelse return error.MissingSite;
    try std.testing.expectEqual(choice, found);
}

/// Assert the map equals `expected` in order and in length: a map that
/// dropped, invented or reordered a binding fails here.
fn expectMap(assignments: []const Assignment, expected: []const Assignment) !void {
    try std.testing.expectEqual(expected.len, assignments.len);
    for (expected, assignments) |want, got| {
        try std.testing.expectEqual(want.site, got.site);
        try std.testing.expectEqual(want.choice, got.choice);
    }
}

/// A branch map is sorted and unique in `site`. Asserted on every map a
/// producer publishes, since an unsorted map is not one the caller may
/// merge.
fn expectSortedUnique(assignments: []const Assignment) !void {
    var i: usize = 1;
    while (i < assignments.len) : (i += 1) {
        try std.testing.expect(assignments[i - 1].site < assignments[i].site);
    }
}

/// Assert the pieces are exactly `expected` as a MULTISET of exact interval
/// values: every expected value is present once, and nothing else is.
/// Matching is by value and not by position, so this does not pin the order
/// a producer happens to emit in.
fn expectValues(set: TSet, expected: []const Interval) !void {
    try std.testing.expect(expected.len <= 64);
    try std.testing.expectEqual(expected.len, set.pieces.len);
    var used = [_]bool{false} ** 64;
    for (expected) |want| {
        var matched = false;
        for (set.pieces, 0..) |p, i| {
            if (used[i]) continue;
            const r = p.value.range orelse continue;
            if (!r.eql(want)) continue;
            used[i] = true;
            matched = true;
            break;
        }
        if (!matched) {
            std.debug.print("missing value [{d}, {d}] in the set\n", .{ want.lo, want.hi });
            return error.MissingValue;
        }
    }
}

/// The multiset of choices recorded at `site`, one per piece, with every
/// piece required to carry it. Compared as a multiset for the same reason
/// `expectValues` is.
fn expectChoices(set: TSet, site: Site, expected: []const Choice) !void {
    try std.testing.expect(expected.len <= 64);
    try std.testing.expectEqual(expected.len, set.pieces.len);
    var used = [_]bool{false} ** 64;
    for (expected) |want| {
        var matched = false;
        for (set.pieces, 0..) |p, i| {
            if (used[i]) continue;
            const got = choiceAt(p.assignments, site) orelse return error.MissingSite;
            if (got != want) continue;
            used[i] = true;
            matched = true;
            break;
        }
        if (!matched) {
            std.debug.print("missing choice {d} at site {d}\n", .{ want, site });
            return error.MissingChoice;
        }
    }
}

/// The piece whose map records `choice` at `site`.
fn pieceWithChoice(set: TSet, site: Site, choice: Choice) ?TPiece {
    for (set.pieces) |p| {
        const got = choiceAt(p.assignments, site) orelse continue;
        if (got == choice) return p;
    }
    return null;
}

/// Forty consecutive sites from `base`, each carrying the SAME choice. Used
/// to show a whole branch map is walked and not sampled: forty bindings
/// agreeing, and one disagreeing, are very different answers.
fn fortyUniform(buf: []Assignment, base: Site, choice: Choice) []const Assignment {
    std.debug.assert(buf.len >= 40);
    for (buf[0..40], 0..) |*a, i| {
        a.* = .{ .site = base + @as(Site, @intCast(i)), .choice = choice };
    }
    return buf[0..40];
}

fn answerInterval(x: ?Interval) !Interval {
    return x orelse error.OutOfDomain;
}

// ===========================================================================
// Choice maps: compatibility, merging, arbitrary sites and choices.
// ===========================================================================

test "compatible: disjoint maps agree, and a shared site decides" {
    const a = [_]Assignment{.{ .site = 1, .choice = 5 }};
    const b = [_]Assignment{.{ .site = 2, .choice = -7 }};
    // Disjoint sites: nothing to disagree about.
    try std.testing.expect(branches.compatible(a[0..], b[0..]));

    // Same site, same choice: the same cell.
    const same = [_]Assignment{.{ .site = 2, .choice = 5 }};
    try std.testing.expect(branches.compatible(a[0..], same[0..]));

    // Same site, different choice: a proven contradiction.
    const other = [_]Assignment{.{ .site = 2, .choice = -5 }};
    try std.testing.expect(!branches.compatible(a[0..], other[0..]));
}

test "compatible: one disagreeing site out of forty is still a contradiction" {
    var abuf: [40]Assignment = undefined;
    var bbuf: [40]Assignment = undefined;
    const a = fortyUniform(abuf[0..], 1000, 7);
    const b = fortyUniform(bbuf[0..], 1000, 7);

    try std.testing.expect(branches.compatible(a, b));

    // Change the LAST site only. Every earlier site still agrees and the
    // answer is still no: compatibility is judged per site, over all of
    // them, so a budget that stopped after a few bindings would answer yes.
    b[39].choice = 4242;
    try std.testing.expect(!branches.compatible(a, b));

    // Overlapping but not identical ranges are judged site by site.
    const last = [_]Assignment{.{ .site = 1039, .choice = 7 }};
    try std.testing.expect(branches.compatible(a, last[0..]));
    const wrong = [_]Assignment{.{ .site = 1039, .choice = 8 }};
    try std.testing.expect(!branches.compatible(a, wrong[0..]));
}

test "merge: disjoint maps union into one sorted map" {
    var out: [4]Assignment = undefined;
    const a = [_]Assignment{.{ .site = 7, .choice = 1 }};
    const b = [_]Assignment{.{ .site = 2, .choice = -3 }};

    const merged = try branches.merge(out[0..], a[0..], b[0..]);
    const m = merged orelse return error.ProvenContradiction;

    try expectMap(m, &.{
        .{ .site = 2, .choice = -3 },
        .{ .site = 7, .choice = 1 },
    });
}

test "merge: an agreeing shared site collapses to one binding" {
    var out: [4]Assignment = undefined;
    const a = [_]Assignment{
        .{ .site = 1, .choice = 4 },
        .{ .site = 6, .choice = -2 },
    };
    const b = [_]Assignment{
        .{ .site = 1, .choice = 4 },
        .{ .site = 9, .choice = 3 },
    };

    const merged = try branches.merge(out[0..], a[0..], b[0..]);
    const m = merged orelse return error.ProvenContradiction;
    try expectMap(m, &.{
        .{ .site = 1, .choice = 4 },
        .{ .site = 6, .choice = -2 },
        .{ .site = 9, .choice = 3 },
    });
}

test "merge: a proven contradiction is null, and empty maps merge to empty" {
    var out: [4]Assignment = undefined;
    const a = [_]Assignment{.{ .site = 1, .choice = 4 }};
    const b = [_]Assignment{.{ .site = 1, .choice = 5 }};

    // A contradiction, not a resource failure and not a one-sided union.
    const conflict = try branches.merge(out[0..], a[0..], b[0..]);
    try std.testing.expect(conflict == null);

    // Two empty maps are not a contradiction: their union is the empty map,
    // which is a different answer again from null.
    const none = [_]Assignment{};
    const empty = try branches.merge(out[0..], none[0..], none[0..]);
    const e = empty orelse return error.ProvenContradiction;
    try std.testing.expectEqual(@as(usize, 0), e.len);
}

test "merge: arbitrary large sites and non-binary choices survive exactly" {
    var out: [4]Assignment = undefined;
    const huge_site: Site = std.math.maxInt(Site);
    const above_i64: Site = 9_223_372_036_854_775_823;
    const lowest: Choice = std.math.minInt(Choice);
    const highest: Choice = std.math.maxInt(Choice);

    // Sites and choices are the caller's own integers, so the extremes of
    // both types are ordinary values here and have to come back unchanged:
    // truncating a site to a machine word, or a choice to a bit, would lose
    // both of these without any error to show for it.
    const a = [_]Assignment{.{ .site = above_i64, .choice = lowest }};
    const b = [_]Assignment{
        .{ .site = huge_site, .choice = highest },
        .{ .site = above_i64, .choice = lowest },
    };

    const merged = try branches.merge(out[0..], a[0..], b[0..]);
    const m = merged orelse return error.ProvenContradiction;
    try expectMap(m, &.{
        .{ .site = above_i64, .choice = lowest },
        .{ .site = huge_site, .choice = highest },
    });

    // Disagreeing AT a huge site is still a proven contradiction: the size of
    // the site says nothing about the comparison.
    var out2: [4]Assignment = undefined;
    const c = [_]Assignment{.{ .site = huge_site, .choice = -1 }};
    const conflict = try branches.merge(out2[0..], b[0..], c[0..]);
    try std.testing.expect(conflict == null);

    // And agreeing at it is not a collision either.
    var out3: [4]Assignment = undefined;
    const d = [_]Assignment{.{ .site = huge_site, .choice = highest }};
    const again = try branches.merge(out3[0..], b[0..], d[0..]);
    const m3 = again orelse return error.ProvenContradiction;
    try expectChoice(m3, huge_site, highest);
    try expectChoice(m3, above_i64, lowest);
}

test "merge: a map of more than thirty-two bindings is walked whole" {
    var out: [80]Assignment = undefined;
    var abuf: [40]Assignment = undefined;
    var bbuf: [40]Assignment = undefined;
    const a = fortyUniform(abuf[0..], 1000, 1);
    const b = fortyUniform(bbuf[0..], 1040, -1);

    const merged = try branches.merge(out[0..], a, b);
    const m = merged orelse return error.ProvenContradiction;

    try std.testing.expectEqual(@as(usize, 80), m.len);
    try expectSortedUnique(m);
    try expectChoice(m, 1000, 1);
    try expectChoice(m, 1039, 1);
    try expectChoice(m, 1040, -1);
    try expectChoice(m, 1079, -1);
}

test "merge: too small an output buffer is a resource failure, not a truncation" {
    var out: [2]Assignment = undefined;
    const a = [_]Assignment{
        .{ .site = 1, .choice = 1 },
        .{ .site = 2, .choice = 2 },
    };
    const b = [_]Assignment{.{ .site = 3, .choice = 3 }};

    // Three bindings are needed and two are available, so the answer is the
    // error -- not a two-binding map, which would then read as a complete
    // one, and not null, which would read as a contradiction.
    try std.testing.expectError(
        error.CapacityExceeded,
        branches.merge(out[0..], a[0..], b[0..]),
    );
}

// ===========================================================================
// The writer: fixed caller buffers, no allocator, atomic appends.
// ===========================================================================

test "writer: assignments are copied out of the caller's slice" {
    var pieces: [2]TPiece = undefined;
    var pool: [4]Assignment = undefined;
    var w = TWriter.init(pieces[0..], pool[0..]);

    var source = [_]Assignment{.{ .site = 3, .choice = 8 }};
    try w.append(Tracked.point(1.5), source[0..]);

    // Scribble over the slice the caller handed in. The writer owns its
    // copy, so the published piece must not follow.
    source[0] = .{ .site = 3, .choice = -999 };

    const view = w.view();
    try std.testing.expectEqual(@as(usize, 1), view.pieces.len);
    try expectChoice(view.pieces[0].assignments, 3, 8);
}

test "writer: append past either buffer fails and changes nothing" {
    var pieces: [1]TPiece = undefined;
    var pool: [2]Assignment = undefined;
    var w = TWriter.init(pieces[0..], pool[0..]);

    try w.append(Tracked.point(2.0), &.{.{ .site = 1, .choice = 1 }});
    const before = w.view();
    try std.testing.expectEqual(@as(usize, 1), before.pieces.len);

    // The piece buffer is full at one.
    try std.testing.expectError(
        error.CapacityExceeded,
        w.append(Tracked.point(3.0), &.{.{ .site = 2, .choice = 2 }}),
    );

    // A second piece that fits the piece buffer but not the assignment
    // buffer fails the same way, and must not leave the first piece short of
    // a binding either.
    var pieces2: [2]TPiece = undefined;
    var pool2: [2]Assignment = undefined;
    var w2 = TWriter.init(pieces2[0..], pool2[0..]);
    try w2.append(Tracked.point(2.0), &.{ .{ .site = 1, .choice = 1 }, .{ .site = 2, .choice = 2 } });
    const before2 = w2.view();
    try std.testing.expectError(
        error.CapacityExceeded,
        w2.append(Tracked.point(3.0), &.{.{ .site = 3, .choice = 3 }}),
    );

    // Each failed append rolled back: one piece, still two bindings, still
    // the original numbers, in the view taken before it as well.
    for ([_]TSet{ before, w.view(), before2, w2.view() }) |set| {
        try std.testing.expectEqual(@as(usize, 1), set.pieces.len);
        try std.testing.expectEqual(@as(f64, 2.0), set.pieces[0].value.range.?.lo);
        try expectMap(set.pieces[0].assignments, &.{
            .{ .site = 1, .choice = 1 },
            .{ .site = 2, .choice = 2 },
        });
    }
}

test "writer: a view already published stays valid while later appends land" {
    var pieces: [3]TPiece = undefined;
    var pool: [6]Assignment = undefined;
    var w = TWriter.init(pieces[0..], pool[0..]);

    try w.append(Tracked.point(1.0), &.{.{ .site = 1, .choice = 1 }});
    const early = w.view();
    try std.testing.expectEqual(@as(usize, 1), early.pieces.len);

    try w.append(Tracked.point(2.0), &.{.{ .site = 2, .choice = 2 }});
    try w.append(Tracked.point(3.0), &.{.{ .site = 3, .choice = 3 }});

    // The earlier view still names the first piece alone and the later one
    // sees all three: appending within the fixed buffers does not disturb
    // what was already handed out.
    try std.testing.expectEqual(@as(usize, 1), early.pieces.len);
    try expectPiece(early.pieces[0].value, 1.0, 1.0, .always, .always);
    try expectChoices(w.view(), 3, &.{ 1, 2, 3 });
}

test "writer: reset empties it and the buffers are reusable" {
    var pieces: [2]TPiece = undefined;
    var pool: [4]Assignment = undefined;
    var w = TWriter.init(pieces[0..], pool[0..]);

    try w.append(Tracked.point(4.0), &.{.{ .site = 9, .choice = -1 }});
    try std.testing.expectEqual(@as(usize, 1), w.view().pieces.len);

    w.reset();
    try std.testing.expectEqual(@as(usize, 0), w.view().pieces.len);

    // Reuse after a reset fills both buffers again from the top, and the
    // binding from the first round is gone rather than shadowed.
    try w.append(Tracked.point(5.0), &.{.{ .site = 11, .choice = 3 }});
    try std.testing.expectEqual(@as(usize, 1), w.view().pieces.len);
    try expectPiece(w.view().pieces[0].value, 5.0, 5.0, .always, .always);
    try expectMap(w.view().pieces[0].assignments, &.{.{ .site = 11, .choice = 3 }});
}

test "writer: a writer with no piece buffer fails on the first append" {
    var pool: [4]Assignment = undefined;
    var w = TWriter.init(&.{}, pool[0..]);

    // Empty is not the same as unable: this is a resource failure, and it
    // publishes no piece of its own.
    try std.testing.expectError(
        error.CapacityExceeded,
        w.append(Tracked.point(1.0), &.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), w.view().pieces.len);
}

// ===========================================================================
// Generic lifting: bindings carried, only compatible pairs combined.
// ===========================================================================

test "mapUnary: every piece keeps its own map, forty bindings included" {
    var in_pieces: [2]TPiece = undefined;
    var in_pool: [80]Assignment = undefined;
    var out_pieces: [2]TPiece = undefined;
    var out_pool: [80]Assignment = undefined;

    const a = fortyUniform(in_pool[0..40], 1000, -5);
    const b = fortyUniform(in_pool[40..80], 2000, 6);
    in_pieces[0] = .{ .value = Tracked.point(1.0), .assignments = a };
    in_pieces[1] = .{ .value = Tracked.point(-1.0), .assignments = b };

    var w = TWriter.init(out_pieces[0..], out_pool[0..]);
    const out = try branches.mapUnary(Tracked, &w, .{ .pieces = in_pieces[0..] }, negValue);

    try std.testing.expectEqual(@as(usize, 2), out.pieces.len);
    // The value moved through the function; the map did not.
    try expectMap(out.pieces[0].assignments, a);
    try expectPiece(out.pieces[0].value, -1.0, -1.0, .always, .always);
    try expectMap(out.pieces[1].assignments, b);
    try expectPiece(out.pieces[1].value, 1.0, 1.0, .always, .always);
    for (out.pieces) |p| try expectSortedUnique(p.assignments);
}

/// A mathematical callback, not a mock: `neg` really moves the numbers and
/// leaves the metadata alone, because a negation cannot change either.
fn negValue(x: Tracked) Tracked {
    return x.neg();
}

test "mapUnary: a real partial-domain function is not an echo of its input" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [1]TPiece = undefined;
    var pool: [4]Assignment = undefined;

    // The input is a fully defined, continuous leaf covering [-1, 1].
    const input = leafSet(&in_buf, Tracked.init(Interval.init(-1.0, 1.0)));
    try std.testing.expectEqual(Truth.always, input.pieces[0].value.defined);
    try std.testing.expectEqual(Truth.always, input.pieces[0].value.continuous);

    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.mapUnary(Tracked, &w, input, sqrtValue);

    try std.testing.expectEqual(@as(usize, 1), out.pieces.len);
    // sqrt over a domain-partial box: the image is the real one, the
    // definition is not proved, and the continuity is not proved either. An
    // echo of the input would have reported both as always.
    try expectEncloses(out.pieces[0].value, 0.0, 1.0);
    try std.testing.expectEqual(Truth.maybe, out.pieces[0].value.defined);
    try expectContinuityUncertain(out.pieces[0].value);
}

fn sqrtValue(x: Tracked) Tracked {
    return x.sqrt();
}

test "mapBinary: only compatible pairs are combined, and their maps are merged" {
    var a_pieces: [2]TPiece = undefined;
    var b_pieces: [2]TPiece = undefined;
    var out_pieces: [4]TPiece = undefined;
    var pool: [12]Assignment = undefined;

    // a carries site 5 with both signs, as a plus/minus split does.
    a_pieces[0] = .{ .value = Tracked.point(2.0), .assignments = &.{.{ .site = 5, .choice = 1 }} };
    a_pieces[1] = .{ .value = Tracked.point(-2.0), .assignments = &.{.{ .site = 5, .choice = -1 }} };
    // b has one piece in the same cell and one at a different site.
    b_pieces[0] = .{ .value = Tracked.point(10.0), .assignments = &.{.{ .site = 5, .choice = 1 }} };
    b_pieces[1] = .{ .value = Tracked.point(100.0), .assignments = &.{.{ .site = 6, .choice = 7 }} };

    var w = TWriter.init(out_pieces[0..], pool[0..]);
    const out = try branches.mapBinary(Tracked, &w, .{ .pieces = a_pieces[0..] }, .{ .pieces = b_pieces[0..] }, addValues);

    // Three of the four pairs are compatible: (5:+1, 5:+1) and both pairs
    // against the disjoint site. (5:-1, 5:+1) is a proven contradiction and
    // is not in the result.
    try expectValues(out, &.{
        Interval.init(12.0, 12.0),
        Interval.init(102.0, 102.0),
        Interval.init(98.0, 98.0),
    });
    for (out.pieces) |p| {
        try expectSortedUnique(p.assignments);
        // Each surviving piece carries both of its arguments' bindings.
        _ = try choiceAt(p.assignments, 5);
        _ = try choiceAt(p.assignments, 6);
    }
    // Exactly one piece is in cell 5:+1, and it is the one paired with the
    // b piece at site 5.
    var in_cell = 0;
    for (out.pieces) |p| {
        if ((try choiceAt(p.assignments, 5)).? == 1) in_cell += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), in_cell);
}

fn addValues(a: Tracked, b: Tracked) Tracked {
    return a.add(b);
}

fn mulValues(a: Tracked, b: Tracked) Tracked {
    return a.mul(b);
}

test "mapBinary: no compatible pair is an empty result, not an error" {
    var a_pieces: [1]TPiece = undefined;
    var b_pieces: [1]TPiece = undefined;
    var out_pieces: [4]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    a_pieces[0] = .{ .value = Tracked.point(2.0), .assignments = &.{.{ .site = 5, .choice = 1 }} };
    b_pieces[0] = .{ .value = Tracked.point(10.0), .assignments = &.{.{ .site = 5, .choice = -1 }} };

    var w = TWriter.init(out_pieces[0..], pool[0..]);
    const out = try branches.mapBinary(Tracked, &w, .{ .pieces = a_pieces[0..] }, .{ .pieces = b_pieces[0..] }, addValues);

    // An empty set is a mathematical answer about the alternatives. It is
    // not `error.CapacityExceeded`, and it is not a missing answer either.
    try std.testing.expectEqual(@as(usize, 0), out.pieces.len);
    try std.testing.expectEqual(@as(usize, 0), w.view().pieces.len);
}

test "mapBinary: a buffer that fits only some pairs fails and publishes nothing" {
    var a_pieces: [2]TPiece = undefined;
    var b_pieces: [2]TPiece = undefined;
    var out_pieces: [2]TPiece = undefined;
    var pool: [12]Assignment = undefined;

    // Disjoint sites, so all four pairs are compatible and all four are
    // live; two piece slots cannot hold them.
    a_pieces[0] = .{ .value = Tracked.point(1.0), .assignments = &.{.{ .site = 5, .choice = 0 }} };
    a_pieces[1] = .{ .value = Tracked.point(2.0), .assignments = &.{.{ .site = 5, .choice = 1 }} };
    b_pieces[0] = .{ .value = Tracked.point(10.0), .assignments = &.{.{ .site = 6, .choice = 0 }} };
    b_pieces[1] = .{ .value = Tracked.point(20.0), .assignments = &.{.{ .site = 6, .choice = 1 }} };

    var w = TWriter.init(out_pieces[0..], pool[0..]);
    try std.testing.expectError(
        error.CapacityExceeded,
        branches.mapBinary(Tracked, &w, .{ .pieces = a_pieces[0..] }, .{ .pieces = b_pieces[0..] }, addValues),
    );

    // Atomicity: the counts are back where they were, so the two pairs that
    // would have fitted are not published on their own. Silently dropping a
    // potentially compatible pair is exactly what must not happen.
    try std.testing.expectEqual(@as(usize, 0), w.view().pieces.len);

    // The same call with room for all four produces all four, and each pair's
    // merged map names both of the cells that produced it.
    var out4: [4]TPiece = undefined;
    var pool4: [16]Assignment = undefined;
    var w4 = TWriter.init(out4[0..], pool4[0..]);
    const full = try branches.mapBinary(Tracked, &w4, .{ .pieces = a_pieces[0..] }, .{ .pieces = b_pieces[0..] }, addValues);
    try expectValues(full, &.{
        Interval.init(11.0, 11.0),
        Interval.init(21.0, 21.0),
        Interval.init(12.0, 12.0),
        Interval.init(22.0, 22.0),
    });
    for (full.pieces) |p| {
        try expectSortedUnique(p.assignments);
        const i = (try choiceAt(p.assignments, 5)).?;
        const j = (try choiceAt(p.assignments, 6)).?;
        try std.testing.expect(i >= 0 and i <= 1);
        try std.testing.expect(j >= 0 and j <= 1);
        try std.testing.expectEqual(@as(f64, @floatFromInt(i + 1 + 10 * (j + 1))), p.value.range.?.hi);
    }
}

test "mapBinary: a forty-binding map is walked whole, pair by pair" {
    const n = 12;
    var a_pieces: [n]TPiece = undefined;
    var b_pieces: [n]TPiece = undefined;
    var apool: [n * 40]Assignment = undefined;
    var bpool: [n * 40]Assignment = undefined;
    var out_pieces: [n]TPiece = undefined;
    var opool: [n * 40]Assignment = undefined;

    // Each piece of a is in one cell of a forty-site space and each piece of
    // b in one cell of the same space. Only the DIAGONAL pairs agree at
    // every one of the forty sites, so the answer is twelve pieces -- and a
    // library that gave up after a few bindings, or that merged the maps
    // instead of comparing them, would not produce those twelve.
    for (0..n) |i| {
        const ci: Choice = @intCast(i);
        a_pieces[i] = .{ .value = Tracked.point(@floatFromInt(i + 1)), .assignments = fortyUniform(apool[i * 40 ..][0..40], 1000, ci) };
        b_pieces[i] = .{ .value = Tracked.point(@floatFromInt(i + 1)), .assignments = fortyUniform(bpool[i * 40 ..][0..40], 1000, ci) };
    }

    var w = TWriter.init(out_pieces[0..], opool[0..]);
    const out = try branches.mapBinary(Tracked, &w, .{ .pieces = a_pieces[0..] }, .{ .pieces = b_pieces[0..] }, mulValues);

    try std.testing.expectEqual(@as(usize, n), out.pieces.len);
    var seen = [_]bool{false} ** n;
    for (out.pieces) |p| {
        try std.testing.expectEqual(@as(usize, 40), p.assignments.len);
        try expectSortedUnique(p.assignments);
        const i = (try choiceAt(p.assignments, 1000)).?;
        // All forty sites agree, and the value is the product of the two
        // points that carry this cell.
        for (p.assignments) |a| try std.testing.expectEqual(i, a.choice);
        const k = @as(usize, @intCast(i));
        try std.testing.expect(k < n);
        try std.testing.expect(!seen[k]);
        seen[k] = true;
        const f = @as(f64, @floatFromInt(k + 1));
        try expectPiece(p.value, f * f, f * f, .always, .always);
    }
}

test "mapBinary: division through the seam is partial-domain, and exact when it can be" {
    var in_pieces: [2]TPiece = undefined;
    var denom: [1]TPiece = undefined;
    var out_pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    in_pieces[0] = .{ .value = Tracked.point(1.0), .assignments = &.{.{ .site = 1, .choice = 0 }} };
    in_pieces[1] = .{ .value = Tracked.point(1.0), .assignments = &.{.{ .site = 1, .choice = 1 }} };
    denom[0] = .{ .value = Tracked.init(Interval.init(-1.0, 1.0)), .assignments = &.{} };

    var w = TWriter.init(out_pieces[0..], pool[0..]);
    const out = try branches.mapBinary(Tracked, &w, .{ .pieces = in_pieces[0..] }, .{ .pieces = denom[0..] }, divideValues);

    try std.testing.expectEqual(@as(usize, 2), out.pieces.len);
    for (out.pieces) |p| {
        // 1/b for b in [-1, 1] excluding zero reaches arbitrarily far in
        // both directions, so the enclosure is the whole line, and the
        // definition is not proved because the zero denominator is in the
        // argument box.
        try expectDefinedUncertain(p.value);
        const r = p.value.range orelse return error.MissingRange;
        try std.testing.expectEqual(-inf, r.lo);
        try std.testing.expectEqual(inf, r.hi);
    }
    // The two arguments' cells both reach the answer.
    try expectChoices(out, 1, &.{ 0, 1 });

    // The same division by a denominator that cannot vanish is total, which
    // is the difference between the two answers.
    var denom2: [1]TPiece = undefined;
    denom2[0] = .{ .value = Tracked.point(2.0), .assignments = &.{} };
    var out2_pieces: [2]TPiece = undefined;
    var pool2: [8]Assignment = undefined;
    var w2 = TWriter.init(out2_pieces[0..], pool2[0..]);
    const out2 = try branches.mapBinary(Tracked, &w2, .{ .pieces = in_pieces[0..] }, .{ .pieces = denom2[0..] }, divideValues);
    try expectValues(out2, &.{ Interval.init(0.5, 0.5), Interval.init(0.5, 0.5) });
    for (out2.pieces) |p| {
        try std.testing.expectEqual(Truth.always, p.value.defined);
        try std.testing.expectEqual(Truth.always, p.value.continuous);
    }
}

fn divideValues(a: Tracked, b: Tracked) Tracked {
    return a.div(b);
}

test "mapSplit: a callback splits one piece into correlated alternatives" {
    var in_pieces: [1]TPiece = undefined;
    var out_pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    // One piece over [-1, 4] that already carries a binding from an earlier
    // operation. The callback appends the two correlated alternatives of the
    // square root: the negative part of the box has no real image at all,
    // and the nonnegative part has one.
    in_pieces[0] = .{
        .value = Tracked.init(Interval.init(-1.0, 4.0)),
        .assignments = &.{.{ .site = 3, .choice = 5 }},
    };

    var w = TWriter.init(out_pieces[0..], pool[0..]);
    const out = try branches.mapSplit(Tracked, &w, .{ .pieces = in_pieces[0..] }, splitSqrt);

    try std.testing.expectEqual(@as(usize, 2), out.pieces.len);

    // The undefined alternative carries the incoming binding and its own
    // cut, and no numeric range at all: an undefined result carries no fake
    // interval.
    const undef = pieceWithChoice(out, 77, 0) orelse return error.MissingAlternative;
    try std.testing.expect(undef.value.range == null);
    try std.testing.expectEqual(Truth.never, undef.value.defined);
    try expectMap(undef.assignments, &.{
        .{ .site = 3, .choice = 5 },
        .{ .site = 77, .choice = 0 },
    });

    // The defined alternative is the real square root of the part of the box
    // that has one, and it is not proved defined over the whole box.
    const real = pieceWithChoice(out, 77, 1) orelse return error.MissingAlternative;
    try expectEncloses(real.value, 0.0, 2.0);
    try expectDefinedUncertain(real.value);
    try expectMap(real.assignments, &.{
        .{ .site = 3, .choice = 5 },
        .{ .site = 77, .choice = 1 },
    });

    for (out.pieces) |p| try expectSortedUnique(p.assignments);
}

/// The split seam's callback, doing real mathematics: it merges the incoming
/// map with each new cut and appends one piece per alternative.
fn splitSqrt(w: *TWriter, piece: TPiece) !void {
    var neg_buf: [4]Assignment = undefined;
    var pos_buf: [4]Assignment = undefined;

    const neg_map = try branches.merge(neg_buf[0..], piece.assignments, &.{.{ .site = 77, .choice = 0 }});
    const pos_map = try branches.merge(pos_buf[0..], piece.assignments, &.{.{ .site = 77, .choice = 1 }});

    try w.append(Tracked.undefined(), neg_map orelse return error.Contradiction);
    try w.append(piece.value.sqrt(), pos_map orelse return error.Contradiction);
}

test "mapSplit: a callback that fails part way leaves the writer where it was" {
    var in_pieces: [1]TPiece = undefined;
    var out_pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    in_pieces[0] = .{
        .value = Tracked.point(1.0),
        .assignments = &.{.{ .site = 3, .choice = 5 }},
    };

    var w = TWriter.init(out_pieces[0..], pool[0..]);

    // Something already in the writer before the operation starts.
    try w.append(Tracked.point(42.0), &.{.{ .site = 1, .choice = 1 }});
    const before = w.view();
    try std.testing.expectEqual(@as(usize, 1), before.pieces.len);

    // The callback appends one piece and then reports a resource failure.
    try std.testing.expectError(
        error.CapacityExceeded,
        branches.mapSplit(Tracked, &w, .{ .pieces = in_pieces[0..] }, appendThenFail),
    );

    // Rolled back to the entry checkpoint: the half-written split is gone and
    // the prior result is untouched.
    try std.testing.expectEqual(@as(usize, 1), w.view().pieces.len);
    try expectPiece(w.view().pieces[0].value, 42.0, 42.0, .always, .always);
    try expectMap(w.view().pieces[0].assignments, &.{.{ .site = 1, .choice = 1 }});
    try expectPiece(before.pieces[0].value, 42.0, 42.0, .always, .always);
}

fn appendThenFail(w: *TWriter, piece: TPiece) !void {
    try w.append(piece.value, piece.assignments);
    return error.CapacityExceeded;
}

// ===========================================================================
// Producers over Tracked values.
// ===========================================================================

test "leaf: the value passes through with no cut invented" {
    var pieces: [2]TPiece = undefined;
    var pool: [4]Assignment = undefined;
    var w = TWriter.init(pieces[0..], pool[0..]);

    const out = try branches.leaf(&w, Tracked.init(Interval.init(-1.0, 1.0)));

    try std.testing.expectEqual(@as(usize, 1), out.pieces.len);
    try expectPiece(out.pieces[0].value, -1.0, 1.0, .always, .always);
    try std.testing.expectEqual(@as(usize, 0), out.pieces[0].assignments.len);
}

test "leaf: an empty input set produces an empty result, not a failure" {
    var pieces: [2]TPiece = undefined;
    var pool: [4]Assignment = undefined;
    var w = TWriter.init(pieces[0..], pool[0..]);

    const out = try branches.floor(&w, .{ .pieces = &.{} }, 7);

    try std.testing.expectEqual(@as(usize, 0), out.pieces.len);
}

test "recip: a box containing zero gives the two rays and never zero" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    const input = leafSet(&in_buf, Tracked.init(Interval.init(-4.0, 2.0)));
    // A site no registry could ever have handed out.
    const site: Site = 0xFEDCBA9876543210;

    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.recip(&w, input, site);

    // The negative side of the box maps to (-inf, -1/lo] and the positive
    // side to [1/hi, inf). Both ends are exact binary numbers here, so these
    // are the whole answers and not approximations of them.
    try expectValues(out, &.{
        Interval.init(-inf, -0.25),
        Interval.init(0.5, inf),
    });
    var choices: [2]Choice = undefined;
    for (out.pieces, 0..) |p, i| {
        choices[i] = choiceAt(p.assignments, site) orelse return error.MissingSite;
        // No piece may claim to be defined everywhere: zero is in the box and
        // has no image, so membership is uncertain for both of them.
        try expectDefinedUncertain(p.value);
        try expectSortedUnique(p.assignments);
        try std.testing.expect(!p.value.range.?.contains(0.0));
    }
    // Two distinguishable cells, not one label used twice.
    try std.testing.expect(choices[0] != choices[1]);
}

test "recip: a box that cannot reach zero keeps one alternative" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    const input = leafSet(&in_buf, Tracked.init(Interval.init(2.0, 4.0)));
    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.recip(&w, input, 7);

    try expectValues(out, &.{Interval.init(0.25, 0.5)});
    try std.testing.expectEqual(Truth.always, out.pieces[0].value.defined);
}

test "div: a denominator that vanishes keeps zero out of every alternative" {
    var num: [1]TPiece = undefined;
    var den: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    num[0] = .{ .value = Tracked.init(Interval.init(1.0, 2.0)), .assignments = &.{} };
    den[0] = .{ .value = Tracked.init(Interval.init(-1.0, 1.0)), .assignments = &.{} };

    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.div(&w, .{ .pieces = num[0..] }, .{ .pieces = den[0..] }, 21);

    // The quotient of a positive box by a box containing zero reaches
    // arbitrarily far in both directions and never reaches zero, so there
    // are two separated rays and no piece covering the gap between them.
    try std.testing.expectEqual(@as(usize, 2), out.pieces.len);
    var lo = inf;
    var hi = -inf;
    var choices: [2]Choice = undefined;
    for (out.pieces, 0..) |p, i| {
        const r = p.value.range orelse return error.MissingRange;
        try std.testing.expect(!r.contains(0.0));
        try expectDefinedUncertain(p.value);
        choices[i] = choiceAt(p.assignments, 21) orelse return error.MissingSite;
        lo = @min(lo, r.lo);
        hi = @max(hi, r.hi);
    }
    try std.testing.expectEqual(-inf, lo);
    try std.testing.expectEqual(inf, hi);
    try std.testing.expect(choices[0] != choices[1]);
}

test "div: a denominator away from zero gives one exact alternative" {
    var num: [1]TPiece = undefined;
    var den: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    num[0] = .{ .value = Tracked.point(6.0), .assignments = &.{} };
    den[0] = .{ .value = Tracked.point(3.0), .assignments = &.{} };

    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.div(&w, .{ .pieces = num[0..] }, .{ .pieces = den[0..] }, 21);

    try expectValues(out, &.{Interval.init(2.0, 2.0)});
    try std.testing.expectEqual(Truth.always, out.pieces[0].value.defined);
}

test "tan: a box straddling the pole keeps the gap and the uncertainty" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    // pi/2 is 1.5707963..., strictly inside this box, so tan is undefined
    // there and the image is two rays.
    const input = leafSet(&in_buf, Tracked.init(Interval.init(1.5, 1.6)));
    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.tan(&w, input, 31);

    try std.testing.expectEqual(@as(usize, 2), out.pieces.len);

    var positive: ?Interval = null;
    var negative: ?Interval = null;
    var choices: [2]Choice = undefined;
    for (out.pieces, 0..) |p, i| {
        const r = p.value.range orelse return error.MissingRange;
        choices[i] = choiceAt(p.assignments, 31) orelse return error.MissingSite;
        // The gap is kept: zero is in neither alternative.
        try std.testing.expect(!r.contains(0.0));
        // Neither side is proved defined over a box the pole is inside, and
        // neither may be promoted to continuous because its own preimage is
        // smooth: over the original box both are uncertain.
        try expectDefinedUncertain(p.value);
        try expectContinuityUncertain(p.value);
        if (r.lo > 0.0) positive = r else if (r.hi < 0.0) negative = r;
    }
    const pos = positive orelse return error.MissingPositiveRay;
    const neg = negative orelse return error.MissingNegativeRay;

    // The rays are unbounded where the mathematics says they are, and each
    // contains the image of the far end of the box: tan(1.5) is 14.1014...
    // and tan(1.6) is -34.2325...
    try std.testing.expectEqual(inf, pos.hi);
    try std.testing.expect(pos.lo <= 14.2);
    try std.testing.expectEqual(-inf, neg.lo);
    try std.testing.expect(neg.hi >= -34.3);
    try std.testing.expect(choices[0] != choices[1]);
}

test "tan: a box with no pole in it is one continuous alternative" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    const input = leafSet(&in_buf, Tracked.init(Interval.init(0.4, 0.6)));
    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.tan(&w, input, 31);

    try std.testing.expectEqual(@as(usize, 1), out.pieces.len);
    const v = out.pieces[0].value;
    // The answer has to CONTAIN the two values the box's endpoints have, and
    // the brackets below are where those values provably are: MPFR256
    // evaluations of tan of the binary64 numbers 0.4 and 0.6, each landing
    // strictly between two adjacent doubles. No slack: a certified answer
    // spans each pair exactly, and asking for more would be a width pin.
    try expectEncloses(v, 0x3fdb0f0b49dcdcd8, 0x3fdb0f0b49dcdcd9);
    try expectEncloses(v, 0x3fe5e472e03a280b, 0x3fe5e472e03a280c);
    try std.testing.expect(v.range.?.hi < 1.0);
    // The function is analytic across this box, so continuity is proved and
    // the uncertainty of the test above is the mathematics of the pole, not
    // a standing hedge about every producer.
    try std.testing.expectEqual(Truth.always, v.continuous);
    try std.testing.expectEqual(Truth.always, v.defined);
}

test "tan: a box crossing two poles splits per cell, not per sign" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [8]TPiece = undefined;
    var pool: [32]Assignment = undefined;

    // [1, 5] contains the poles pi/2 and 3pi/2 and the zero at pi between
    // them, so the image has three cells: a positive ray, a cell that runs
    // from -inf to +inf through zero, and a negative ray. Three cells is not
    // a sign bit, and a two-cell split of this box would have to invent one
    // of them.
    const input = leafSet(&in_buf, Tracked.init(Interval.init(1.0, 5.0)));
    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.tan(&w, input, 31);

    try std.testing.expect(out.pieces.len >= 3);
    var rays = 0;
    var through_zero = 0;
    for (out.pieces) |p| {
        const r = p.value.range orelse return error.MissingRange;
        try expectDefinedUncertain(p.value);
        // Every cell of this box runs up to a pole or away from one.
        if (r.hi == inf or r.lo == -inf) rays += 1;
        // Exactly one cell contains the value at pi, where tan is zero.
        if (r.contains(0.0)) through_zero += 1;
    }
    try std.testing.expect(rays >= 3);
    try std.testing.expectEqual(@as(usize, 1), through_zero);
    // Every cell is its own choice: an implementation that labelled them all
    // with one sign bit would collide here.
    try expectDistinctCells(out, 31);
}

test "floor: every integer cell is named, with the integer as the choice" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [4]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    // Two integers in the box and nothing between them: 0.5 is not an answer
    // to floor over a box that contains no half.
    var w = TWriter.init(pieces[0..], pool[0..]);
    const two = try branches.floor(&w, leafSet(&in_buf, Tracked.init(Interval.init(0.9, 1.1))), 7);
    try expectValues(two, &.{ Interval.init(0.0, 0.0), Interval.init(1.0, 1.0) });
    try expectChoices(two, 7, &.{ 0, 1 });
    // A constant integer image is continuous wherever it is defined.
    for (two.pieces) |p| {
        try std.testing.expectEqual(Truth.always, p.value.continuous);
        try std.testing.expectEqual(Truth.always, p.value.defined);
        try expectSortedUnique(p.assignments);
    }

    // Three integers in the box: no two-piece cap.
    var w2 = TWriter.init(pieces[0..], pool[0..]);
    const three = try branches.floor(&w2, leafSet(&in_buf, Tracked.init(Interval.init(0.9, 2.1))), 7);
    try expectValues(three, &.{
        Interval.init(0.0, 0.0),
        Interval.init(1.0, 1.0),
        Interval.init(2.0, 2.0),
    });
    try expectChoices(three, 7, &.{ 0, 1, 2 });
}

test "floor: negative cells carry negative integers as choices" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [4]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.floor(&w, leafSet(&in_buf, Tracked.init(Interval.init(-3.7, -2.2))), 7);

    try expectValues(out, &.{ Interval.init(-4.0, -4.0), Interval.init(-3.0, -3.0) });
    try expectChoices(out, 7, &.{ -4, -3 });
}

test "floor: an incoming map is preserved and the cut is appended to it" {
    var in_pieces: [1]TPiece = undefined;
    var pieces: [4]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    // The piece already carries a binding from an earlier operation, at a
    // site LOWER than the new cut, so a producer that dropped or reordered
    // the incoming binding is caught here.
    in_pieces[0] = .{
        .value = Tracked.init(Interval.init(0.9, 1.1)),
        .assignments = &.{.{ .site = 2, .choice = 5 }},
    };

    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.floor(&w, .{ .pieces = in_pieces[0..] }, 7);

    try std.testing.expectEqual(@as(usize, 2), out.pieces.len);
    for (out.pieces) |p| {
        try expectSortedUnique(p.assignments);
        try expectMap(p.assignments, &.{
            .{ .site = 2, .choice = 5 },
            .{ .site = 7, .choice = try choiceAt(p.assignments, 7) },
        });
    }
    const zero = pieceWithChoice(out, 7, 0) orelse return error.MissingCell;
    try expectPiece(zero.value, 0.0, 0.0, .always, .always);
    const one = pieceWithChoice(out, 7, 1) orelse return error.MissingCell;
    try expectPiece(one.value, 1.0, 1.0, .always, .always);
}

test "ceil, trunc and round disagree about the same box" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [6]TPiece = undefined;
    var pool: [24]Assignment = undefined;

    const box = Tracked.init(Interval.init(-1.5, 1.5));

    // ceil: towards +infinity on both sides.
    var wc = TWriter.init(pieces[0..], pool[0..]);
    const ceiled = try branches.ceil(&wc, leafSet(&in_buf, box), 7);
    try expectValues(ceiled, &.{
        Interval.init(-1.0, -1.0),
        Interval.init(0.0, 0.0),
        Interval.init(1.0, 1.0),
        Interval.init(2.0, 2.0),
    });
    try expectChoices(ceiled, 7, &.{ -1, 0, 1, 2 });

    // trunc: towards zero on both sides, so three cells where ceil has four
    // and floor would have five.
    var wt = TWriter.init(pieces[0..], pool[0..]);
    const truncated = try branches.trunc(&wt, leafSet(&in_buf, box), 7);
    try expectValues(truncated, &.{
        Interval.init(-1.0, -1.0),
        Interval.init(0.0, 0.0),
        Interval.init(1.0, 1.0),
    });
    try expectChoices(truncated, 7, &.{ -1, 0, 1 });

    // round: half AWAY FROM ZERO, so -1.5 becomes -2 and 1.5 becomes 2.
    var wr = TWriter.init(pieces[0..], pool[0..]);
    const rounded = try branches.round(&wr, leafSet(&in_buf, box), 7);
    try expectValues(rounded, &.{
        Interval.init(-2.0, -2.0),
        Interval.init(-1.0, -1.0),
        Interval.init(0.0, 0.0),
        Interval.init(1.0, 1.0),
        Interval.init(2.0, 2.0),
    });
    try expectChoices(rounded, 7, &.{ -2, -1, 0, 1, 2 });
}

test "the three tie rules separate only where a tie is" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;
    var w = TWriter.init(pieces[0..], pool[0..]);

    // Away from a tie all three rules are the same function, so a difference
    // there would be a bug of its own. The expected integers are written
    // out rather than computed, so this does not check the implementation
    // against itself.
    const plain = [_][2]f64{
        .{ -2.6, -3.0 },
        .{ -2.4, -2.0 },
        .{ -0.6, -1.0 },
        .{ -0.4, 0.0 },
        .{ 0.4, 0.0 },
        .{ 0.6, 1.0 },
        .{ 2.4, 2.0 },
        .{ 2.6, 3.0 },
    };
    for (plain) |row| {
        w.reset();
        try expectSingleton(try branches.round(&w, leafSet(&in_buf, Tracked.point(row[0])), 7), row[1]);
        w.reset();
        try expectSingleton(try branches.roundTiesUp(&w, leafSet(&in_buf, Tracked.point(row[0])), 7), row[1]);
        w.reset();
        try expectSingleton(try branches.roundTiesDown(&w, leafSet(&in_buf, Tracked.point(row[0])), 7), row[1]);
    }

    // The ties themselves, where the three rules are three different images.
    w.reset();
    try expectSingleton(try branches.round(&w, leafSet(&in_buf, Tracked.point(0.5)), 7), 1.0);
    w.reset();
    try expectSingleton(try branches.round(&w, leafSet(&in_buf, Tracked.point(-0.5)), 7), -1.0);
    w.reset();
    try expectSingleton(try branches.round(&w, leafSet(&in_buf, Tracked.point(2.5)), 7), 3.0);
    w.reset();
    try expectSingleton(try branches.round(&w, leafSet(&in_buf, Tracked.point(-2.5)), 7), -3.0);

    w.reset();
    try expectSingleton(try branches.roundTiesUp(&w, leafSet(&in_buf, Tracked.point(0.5)), 7), 1.0);
    w.reset();
    try expectSingleton(try branches.roundTiesUp(&w, leafSet(&in_buf, Tracked.point(-0.5)), 7), 0.0);
    w.reset();
    try expectSingleton(try branches.roundTiesUp(&w, leafSet(&in_buf, Tracked.point(2.5)), 7), 3.0);
    w.reset();
    try expectSingleton(try branches.roundTiesUp(&w, leafSet(&in_buf, Tracked.point(-2.5)), 7), -2.0);

    w.reset();
    try expectSingleton(try branches.roundTiesDown(&w, leafSet(&in_buf, Tracked.point(0.5)), 7), 0.0);
    w.reset();
    try expectSingleton(try branches.roundTiesDown(&w, leafSet(&in_buf, Tracked.point(-0.5)), 7), -1.0);
    w.reset();
    try expectSingleton(try branches.roundTiesDown(&w, leafSet(&in_buf, Tracked.point(2.5)), 7), 2.0);
    w.reset();
    try expectSingleton(try branches.roundTiesDown(&w, leafSet(&in_buf, Tracked.point(-2.5)), 7), -3.0);
}

/// A producer over a singleton box must give the one integer it names, as a
/// single alternative whose choice is that integer.
fn expectSingleton(out: TSet, want: f64) !void {
    try std.testing.expectEqual(@as(usize, 1), out.pieces.len);
    try expectPiece(out.pieces[0].value, want, want, .always, .always);
    try expectChoices(out, 7, &.{@as(Choice, @intFromFloat(want))});
}

test "sgn: the three signs of a box crossing zero, and one sign of a box that does not" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [4]TPiece = undefined;
    var pool: [16]Assignment = undefined;

    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.sgn(&w, leafSet(&in_buf, Tracked.init(Interval.init(-2.0, 3.0))), 7);

    // Exactly the three mathematical signs, and no piece claiming to be a
    // fourth alternative. The label values are the implementation's, so
    // what is asked of them is that they tell the three cells apart.
    try expectValues(out, &.{
        Interval.init(-1.0, -1.0),
        Interval.init(0.0, 0.0),
        Interval.init(1.0, 1.0),
    });
    try expectDistinctCells(out, 7);
    for (out.pieces) |p| try expectSortedUnique(p.assignments);

    // A box that is entirely positive has no zero alternative to invent.
    var w2 = TWriter.init(pieces[0..], pool[0..]);
    const pos = try branches.sgn(&w2, leafSet(&in_buf, Tracked.init(Interval.init(2.0, 3.0))), 7);
    try expectValues(pos, &.{Interval.init(1.0, 1.0)});

    var w3 = TWriter.init(pieces[0..], pool[0..]);
    const neg = try branches.sgn(&w3, leafSet(&in_buf, Tracked.init(Interval.init(-3.0, -2.0))), 7);
    try expectValues(neg, &.{Interval.init(-1.0, -1.0)});
}

test "plusMinus: the two signs of one input, at choices plus and minus one" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.plusMinus(&w, leafSet(&in_buf, Tracked.point(2.0)), 9);

    try expectValues(out, &.{ Interval.init(2.0, 2.0), Interval.init(-2.0, -2.0) });
    try expectChoices(out, 9, &.{ 1, -1 });
    // The choice IS the sign, so the alternative chosen -1 is the negative
    // one and the alternative chosen +1 is the positive one.
    const plus = pieceWithChoice(out, 9, 1) orelse return error.MissingAlternative;
    const minus = pieceWithChoice(out, 9, -1) orelse return error.MissingAlternative;
    try expectPiece(plus.value, 2.0, 2.0, .always, .always);
    try expectPiece(minus.value, -2.0, -2.0, .always, .always);

    // Over a box the two signs are the box and its reflection.
    var in_buf2: [1]TPiece = undefined;
    var w2 = TWriter.init(pieces[0..], pool[0..]);
    const over_box = try branches.plusMinus(&w2, leafSet(&in_buf2, Tracked.init(Interval.init(1.0, 3.0))), 9);
    try expectValues(over_box, &.{ Interval.init(1.0, 3.0), Interval.init(-3.0, -1.0) });
}

test "plusMinus: the same call at one site correlates the signs, two sites do not" {
    var in_buf: [1]TPiece = undefined;
    var a_pieces: [2]TPiece = undefined;
    var b_pieces: [2]TPiece = undefined;
    var pool: [16]Assignment = undefined;
    var out_pieces: [4]TPiece = undefined;
    var out_pool: [16]Assignment = undefined;

    // Two calls of the plus/minus of the SAME input at the SAME site: the
    // same operator on the same arguments, so the signs are correlated.
    var wa = TWriter.init(a_pieces[0..], pool[0..]);
    const a = try branches.plusMinus(&wa, leafSet(&in_buf, Tracked.point(2.0)), 9);
    var wb = TWriter.init(b_pieces[0..], pool[8..]);
    const b = try branches.plusMinus(&wb, leafSet(&in_buf, Tracked.point(2.0)), 9);

    var w = TWriter.init(out_pieces[0..], out_pool[0..]);
    const correlated = try branches.mapBinary(Tracked, &w, a, b, addValues);

    // The sums are +-2x: 4 and -4, and NOT 0, because the mixed pairings are
    // contradictions at one site.
    try expectValues(correlated, &.{ Interval.init(4.0, 4.0), Interval.init(-4.0, -4.0) });
    for (correlated.pieces) |p| {
        try std.testing.expect(!p.value.range.?.contains(0.0));
    }

    // The same two calls at DIFFERENT sites are independent, so every
    // combination is live and the cancelling pair is among them.
    var in_buf2: [1]TPiece = undefined;
    var a2_pieces: [2]TPiece = undefined;
    var b2_pieces: [2]TPiece = undefined;
    var pool2: [16]Assignment = undefined;
    var out2_pieces: [4]TPiece = undefined;
    var out2_pool: [16]Assignment = undefined;

    var wa2 = TWriter.init(a2_pieces[0..], pool2[0..]);
    const a2 = try branches.plusMinus(&wa2, leafSet(&in_buf2, Tracked.point(2.0)), 9);
    var wb2 = TWriter.init(b2_pieces[0..], pool2[8..]);
    const b2 = try branches.plusMinus(&wb2, leafSet(&in_buf2, Tracked.point(2.0)), 10);

    var w2 = TWriter.init(out2_pieces[0..], out2_pool[0..]);
    const independent = try branches.mapBinary(Tracked, &w2, a2, b2, addValues);

    try expectValues(independent, &.{
        Interval.init(4.0, 4.0),
        Interval.init(0.0, 0.0),
        Interval.init(0.0, 0.0),
        Interval.init(-4.0, -4.0),
    });
}

test "floor: the same input at one site excludes the mixed sum, two sites allow it" {
    var in_buf: [1]TPiece = undefined;
    var a_pieces: [2]TPiece = undefined;
    var b_pieces: [2]TPiece = undefined;
    var pool: [16]Assignment = undefined;
    var out_pieces: [4]TPiece = undefined;

    // The same operator on the same argument at the same site: the two
    // results are the same cell twice, so only the like cells pair.
    var wa = TWriter.init(a_pieces[0..], pool[0..]);
    const a = try branches.floor(&wa, leafSet(&in_buf, Tracked.init(Interval.init(0.9, 1.1))), 7);
    var wb = TWriter.init(b_pieces[0..], pool[8..]);
    const b = try branches.floor(&wb, leafSet(&in_buf, Tracked.init(Interval.init(0.9, 1.1))), 7);

    var w = TWriter.init(out_pieces[0..], pool[0..]);
    const correlated = try branches.mapBinary(Tracked, &w, a, b, addValues);

    // 0 + 0 and 1 + 1. The sum 1 would need 0 from one call and 1 from the
    // other, which are different cells of one site.
    try expectValues(correlated, &.{ Interval.init(0.0, 0.0), Interval.init(2.0, 2.0) });
    for (correlated.pieces) |p| {
        try std.testing.expect(!p.value.range.?.contains(1.0));
    }

    // Two different sites: the two calls are independent, all four pairings
    // are live, and 1 is among the sums.
    var in_buf2: [1]TPiece = undefined;
    var a2_pieces: [2]TPiece = undefined;
    var b2_pieces: [2]TPiece = undefined;
    var pool2: [16]Assignment = undefined;
    var out2_pieces: [4]TPiece = undefined;

    var wa2 = TWriter.init(a2_pieces[0..], pool2[0..]);
    const a2 = try branches.floor(&wa2, leafSet(&in_buf2, Tracked.init(Interval.init(0.9, 1.1))), 7);
    var wb2 = TWriter.init(b2_pieces[0..], pool2[8..]);
    const b2 = try branches.floor(&wb2, leafSet(&in_buf2, Tracked.init(Interval.init(0.9, 1.1))), 8);

    var w2 = TWriter.init(out2_pieces[0..], pool2[0..]);
    const independent = try branches.mapBinary(Tracked, &w2, a2, b2, addValues);

    try expectValues(independent, &.{
        Interval.init(0.0, 0.0),
        Interval.init(1.0, 1.0),
        Interval.init(1.0, 1.0),
        Interval.init(2.0, 2.0),
    });
}

test "mod: the cells are the floor of the quotient, shared with floor at one site" {
    var a_pieces: [1]TPiece = undefined;
    var m_pieces: [1]TPiece = undefined;
    var q_pieces: [4]TPiece = undefined;
    var f_pieces: [8]TPiece = undefined;
    var m_pieces_out: [8]TPiece = undefined;
    var r_pieces: [8]TPiece = undefined;
    var qpool: [16]Assignment = undefined;
    var fpool: [16]Assignment = undefined;
    var mpool: [16]Assignment = undefined;
    var rpool: [64]Assignment = undefined;

    // a = [0, 100] modulo 17. The cells are the floor of the quotient, 0 to
    // 5, and the value of each cell is the remainder.
    a_pieces[0] = .{ .value = Tracked.init(Interval.init(0.0, 100.0)), .assignments = &.{} };
    m_pieces[0] = .{ .value = Tracked.point(17.0), .assignments = &.{} };

    var wq = TWriter.init(q_pieces[0..], qpool[0..]);
    const quotient_box = try branches.div(&wq, .{ .pieces = a_pieces[0..] }, .{ .pieces = m_pieces[0..] }, 6);
    // The quotient of two boxes that reach no zero is one piece, and its top
    // is the quotient of the tops: 100/17. That value is provably above 5.88
    // and provably below 5.89 -- 5.88 * 17 = 99.96 < 100 < 100.13 = 5.89 * 17
    // -- so a bound the value is ABOVE is the one an answer has to reach and a
    // bound it is BELOW is the one an answer has to stop short of. Asking the
    // other way round, to reach 5.89, would be asking the enclosure to be
    // inflated past its value, and asking it to reach 100/17 as computed in
    // floating point would ask for up to an extra step. Neither is asked for
    // here: the cell list that follows is what pins the top precisely.
    try std.testing.expectEqual(@as(usize, 1), quotient_box.pieces.len);
    try expectEncloses(quotient_box.pieces[0].value, 0.0, 5.88);
    // Below 6, which is what makes cell 5 the last cell: 6 * 17 = 102 lies
    // outside a = [0, 100].
    try std.testing.expect(quotient_box.pieces[0].value.range.?.hi < 6.0);

    var wf = TWriter.init(f_pieces[0..], fpool[0..]);
    const quotient = try branches.floor(&wf, quotient_box, 5);
    try expectValues(quotient, &.{
        Interval.init(0.0, 0.0),
        Interval.init(1.0, 1.0),
        Interval.init(2.0, 2.0),
        Interval.init(3.0, 3.0),
        Interval.init(4.0, 4.0),
        Interval.init(5.0, 5.0),
    });
    try expectChoices(quotient, 5, &.{ 0, 1, 2, 3, 4, 5 });

    var wm = TWriter.init(m_pieces_out[0..], mpool[0..]);
    const remainders = try branches.mod(&wm, .{ .pieces = a_pieces[0..] }, .{ .pieces = m_pieces[0..] }, 5);

    // Every remainder cell is a positive remainder of a value no larger
    // than 17, and the last one is short because a stops at 100.
    for (remainders.pieces) |p| {
        const k: f64 = @floatFromInt((try choiceAt(p.assignments, 5)).?);
        const r = p.value.range orelse return error.MissingRange;
        try std.testing.expect(k >= 0.0 and k <= 5.0);
        try std.testing.expect(r.lo >= 0.0);
        try std.testing.expect(r.hi <= @min(17.0, 100.0 - 17.0 * k));
        try expectSortedUnique(p.assignments);
    }

    // Reconstruction: 17 * floor(quotient) + remainder is a, cell by cell.
    // The pairing is restricted to matching cells by the shared site, and
    // each pair lands inside its own cell's preimage of the box.
    var wr = TWriter.init(r_pieces[0..], rpool[0..]);
    const rebuilt = try branches.mapBinary(Tracked, &wr, quotient, remainders, reconstruct17);

    try std.testing.expectEqual(@as(usize, 6), rebuilt.pieces.len);
    var hull = Interval.init(inf, -inf);
    for (rebuilt.pieces) |p| {
        const k: f64 = @floatFromInt((try choiceAt(p.assignments, 5)).?);
        const r = p.value.range orelse return error.MissingRange;
        // The pair's sum lies in the preimage of the box that cell k names:
        // from 17k up to the smaller of the next cell's start and the top of
        // the box. Both ends are exact here -- 17k, the modulus and 100 are
        // integers and the remainders are differences of exact multiples --
        // so the sum is exact too and this bound is the mathematics of the
        // cell rather than a tolerance.
        const cell_hi = @min(17.0 * (k + 1.0), 100.0);
        try std.testing.expect(r.lo <= 17.0 * k);
        try std.testing.expect(r.hi >= cell_hi);
        try std.testing.expect(r.hi <= cell_hi);
        try expectSortedUnique(p.assignments);
        hull = hull.hull(r);
    }
    // Nothing overshoots the box, so 101 is not a value of a here. The bound
    // is 100 exactly: 100 is a value of the box, so an enclosure stopping
    // below it would be unsound, and nothing above it is one, so an enclosure
    // reaching above it would be inflated.
    try std.testing.expect(hull.hi <= 100.0);
    try std.testing.expect(hull.lo >= 0.0);
    // And the box is covered: every value of a has a cell.
    try std.testing.expect(hull.lo <= 0.0);
    try std.testing.expect(hull.hi >= 100.0);

    // The last cell is the interesting one: 85 + [0, 15] reaches exactly the
    // top of the box, which is what makes 101 impossible here.
    const top = pieceWithChoice(rebuilt, 5, 5) orelse return error.MissingCell;
    try expectEncloses(top.value, 85.0, 100.0);
    try std.testing.expect(top.value.range.?.hi <= 100.0);
}

fn reconstruct17(q: Tracked, r: Tracked) Tracked {
    return q.mul(Tracked.point(17.0)).add(r);
}

test "mod: at a different site the reconstruction may leave the box" {
    var a_pieces: [1]TPiece = undefined;
    var m_pieces: [1]TPiece = undefined;
    var q_pieces: [4]TPiece = undefined;
    var f_pieces: [8]TPiece = undefined;
    var m_pieces_out: [8]TPiece = undefined;
    var r_pieces: [64]TPiece = undefined;
    var qpool: [16]Assignment = undefined;
    var fpool: [16]Assignment = undefined;
    var mpool: [16]Assignment = undefined;
    var rpool: [1024]Assignment = undefined;

    a_pieces[0] = .{ .value = Tracked.init(Interval.init(0.0, 100.0)), .assignments = &.{} };
    m_pieces[0] = .{ .value = Tracked.point(17.0), .assignments = &.{} };

    // The same two calls, but the quotient floored at a site of its own, so
    // nothing correlates a quotient cell with a remainder cell.
    var wq = TWriter.init(q_pieces[0..], qpool[0..]);
    const quotient_box = try branches.div(&wq, .{ .pieces = a_pieces[0..] }, .{ .pieces = m_pieces[0..] }, 6);
    var wf = TWriter.init(f_pieces[0..], fpool[0..]);
    const quotient = try branches.floor(&wf, quotient_box, 15);
    var wm = TWriter.init(m_pieces_out[0..], mpool[0..]);
    const remainders = try branches.mod(&wm, .{ .pieces = a_pieces[0..] }, .{ .pieces = m_pieces[0..] }, 5);

    var wr = TWriter.init(r_pieces[0..], rpool[0..]);
    const rebuilt = try branches.mapBinary(Tracked, &wr, quotient, remainders, reconstruct17);

    // Every pairing is allowed now, so the top quotient cell added to an
    // EARLIER cell's remainder reaches past 100 -- 101 and 102 among the
    // values. The correlation is what kept the previous test inside the
    // box, and this is the demonstration that it was doing something.
    var hull = Interval.init(inf, -inf);
    for (rebuilt.pieces) |p| hull = hull.hull(p.value.range.?);
    try std.testing.expect(hull.hi >= 101.0);
}

test "mod: a negative modulus is a magnitude, so the positive remainder is unchanged" {
    var a_pieces: [1]TPiece = undefined;
    var m_pieces: [1]TPiece = undefined;
    var pos_pieces: [8]TPiece = undefined;
    var neg_pieces: [8]TPiece = undefined;
    var pos_pool: [16]Assignment = undefined;
    var neg_pool: [16]Assignment = undefined;

    a_pieces[0] = .{ .value = Tracked.init(Interval.init(0.0, 100.0)), .assignments = &.{} };
    m_pieces[0] = .{ .value = Tracked.point(17.0), .assignments = &.{} };
    var wpos = TWriter.init(pos_pieces[0..], pos_pool[0..]);
    const positive = try branches.mod(&wpos, .{ .pieces = a_pieces[0..] }, .{ .pieces = m_pieces[0..] }, 5);

    m_pieces[0] = .{ .value = Tracked.point(-17.0), .assignments = &.{} };
    var wneg = TWriter.init(neg_pieces[0..], neg_pool[0..]);
    const negative = try branches.mod(&wneg, .{ .pieces = a_pieces[0..] }, .{ .pieces = m_pieces[0..] }, 5);

    try std.testing.expectEqual(positive.pieces.len, negative.pieces.len);
    // Cell for cell, the remainders are the same positive intervals: the
    // modulus is taken in magnitude, so -17 and 17 are one operator here.
    for (0..6) |k| {
        const choice: Choice = @intCast(k);
        const a = pieceWithChoice(positive, 5, choice) orelse return error.MissingCell;
        const b = pieceWithChoice(negative, 5, choice) orelse return error.MissingCell;
        const ra = a.value.range orelse return error.MissingRange;
        const rb = b.value.range orelse return error.MissingRange;
        try std.testing.expect(ra.eql(rb));
        const f: f64 = @floatFromInt(k);
        try std.testing.expect(ra.lo >= 0.0);
        try std.testing.expect(ra.hi <= @min(17.0, 100.0 - 17.0 * f));
    }
}

test "powRational: rational powers give the right images" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [4]TPiece = undefined;
    var pool: [16]Assignment = undefined;

    // The square root of [1, 4] contains [1, 2] and is one cell, because
    // the whole box is in the domain of an even root. Only containment is
    // asked for: the width of the answer is a quality measure and pinning it
    // here would be pinning the rounding convention of one kernel.
    var w = TWriter.init(pieces[0..], pool[0..]);
    const root = try branches.powRational(&w, leafSet(&in_buf, Tracked.init(Interval.init(1.0, 4.0))), try rational(1, 2), 41);
    try std.testing.expectEqual(@as(usize, 1), root.pieces.len);
    try expectEncloses(root.pieces[0].value, 1.0, 2.0);
    try std.testing.expect(root.pieces[0].value.range.?.lo >= 0.0);
    try std.testing.expectEqual(Truth.always, root.pieces[0].value.defined);

    // The cube root of [-8, 8] contains [-2, 2] and reaches BELOW zero: an
    // odd degree root takes the negative half of the box rather than
    // clipping it away, which is the difference from the even root above.
    var w2 = TWriter.init(pieces[0..], pool[0..]);
    const cube = try branches.powRational(&w2, leafSet(&in_buf, Tracked.init(Interval.init(-8.0, 8.0))), try rational(1, 3), 41);
    try expectEncloses(cube.pieces[0].value, -2.0, 2.0);
    try std.testing.expect(cube.pieces[0].value.range.?.lo < 0.0);

    // An even integer power of a negative box is defined and positive, which
    // is the case a bare point estimate gets wrong.
    var w3 = TWriter.init(pieces[0..], pool[0..]);
    const square = try branches.powRational(&w3, leafSet(&in_buf, Tracked.init(Interval.init(-3.0, -2.0))), try rational(2, 1), 41);
    try expectEncloses(square.pieces[0].value, 4.0, 9.0);
    try std.testing.expect(square.pieces[0].value.range.?.lo >= 0.0);
    try std.testing.expectEqual(Truth.always, square.pieces[0].value.defined);

    // A power whose value is not a binary number is only asked to ENCLOSE
    // it, against the MPFR bracket of the true square root of two: the two
    // binary numbers it lies strictly between, 0x1.6a09e667f3bccp0 and
    // 0x1.6a09e667f3bcdp0, which are 1.4142135623730949 and
    // 1.4142135623730951. That is where the value IS rather than a budget
    // of extra steps, so no slack is asked for here: the bracket is exact.
    var w4 = TWriter.init(pieces[0..], pool[0..]);
    const irrational = try branches.powRational(&w4, leafSet(&in_buf, Tracked.point(2.0)), try rational(1, 2), 41);
    try expectEncloses(irrational.pieces[0].value, 0x1.6a09e667f3bccp0, 0x1.6a09e667f3bcdp0);

    // A box with a part that has no real image at all: the part that has one
    // survives with a non-negative image, and the definition is not proved
    // over the whole box.
    var w5 = TWriter.init(pieces[0..], pool[0..]);
    const partial = try branches.powRational(&w5, leafSet(&in_buf, Tracked.init(Interval.init(-1.0, 4.0))), try rational(1, 2), 41);
    var found = false;
    for (partial.pieces) |p| {
        const pr = p.value.range orelse {
            // An alternative with no image at all may be reported as
            // undefined; what is not allowed is claiming it is defined.
            try std.testing.expectEqual(Truth.never, p.value.defined);
            continue;
        };
        try std.testing.expect(pr.lo >= 0.0);
        try std.testing.expect(pr.lo <= 1.0);
        try std.testing.expect(pr.hi >= 2.0);
        try expectDefinedUncertain(p.value);
        found = true;
    }
    try std.testing.expect(found);
}

fn rational(n: i64, d: u64) !interval.Rational {
    return interval.Rational.init(n, d);
}

test "inverseTrig: the selected branches are the answers, and they round trip" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [4]TPiece = undefined;
    var pool: [16]Assignment = undefined;

    // sin(t) = 1/2 has a solution in every cell: pi/6, 5pi/6 and -7pi/6 for
    // the branches 0, 1 and -1. Those are not binary numbers, so each answer
    // is held to a coarse bracket and to a round trip rather than to a
    // literal.
    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.inverseTrig(
        &w,
        leafSet(&in_buf, Tracked.point(0.5)),
        .circle,
        .sin,
        51,
        &.{ 0, 1, -1 },
    );

    try std.testing.expectEqual(@as(usize, 3), out.pieces.len);
    try expectDistinctCells(out, 51);

    // Each selected branch round trips: feeding an answer back through the
    // forward function must contain the value it was asked to invert.
    for (out.pieces) |p| {
        const t = p.value.range orelse return error.MissingRange;
        const back = try answerInterval(trig.forward(.circle, .sin, t));
        try std.testing.expect(back.contains(0.5));
        try std.testing.expectEqual(Truth.always, p.value.defined);
    }

    // The three answers, matched to their branches by VALUE and not by label,
    // because the label encoding is the implementation's and the mathematics
    // is the contract's. Each piece has to SIT INSIDE an identifying bracket
    // and to CONTAIN the value its branch is supposed to have: asking for
    // only one of those would pass a hull of the box, and asking a piece to
    // contain its own identifying bracket would ask it to be inflated.
    const k0 = try pieceInBracket(out, 0.5, 0.6);
    const k1 = try pieceInBracket(out, 2.5, 2.7);
    const km1 = try pieceInBracket(out, -3.7, -3.6);
    // pi/6, 5pi/6 and -7pi/6, bracketed by MPFR256 evaluations of the true
    // values themselves -- adjacent doubles on each side, no slack asked for
    // in either direction.
    try expectEncloses(k0.value, 0x3fe0c152382d7365, 0x3fe0c152382d7366);
    try expectEncloses(k1.value, 0x4004f1a6c638d03e, 0x4004f1a6c638d03f);
    try expectEncloses(km1.value, 0xc00d524fe24f89f2, 0xc00d524fe24f89f1);
}

/// The one piece whose image lies inside the bracket `[lo, hi]`. Used where
/// the branches are matched by their mathematics rather than by a label the
/// library is free to choose.
fn pieceInBracket(set: TSet, lo: f64, hi: f64) !TPiece {
    var found: ?TPiece = null;
    for (set.pieces) |p| {
        const r = p.value.range orelse continue;
        if (r.lo < lo or r.hi > hi) continue;
        if (found != null) return error.AmbiguousBracket;
        found = p;
    }
    return found orelse error.MissingBracket;
}

/// Every piece carries `site`, and no two pieces share a choice there: the
/// alternatives of one call are distinguishable cells. What the choices
/// ARE is the implementation's; that they differ is the contract's.
fn expectDistinctCells(set: TSet, site: Site) !void {
    for (set.pieces, 0..) |p, i| {
        const c = choiceAt(p.assignments, site) orelse return error.MissingSite;
        for (set.pieces, 0..) |q, j| {
            if (i >= j) continue;
            const d = choiceAt(q.assignments, site) orelse return error.MissingSite;
            try std.testing.expect(c != d);
        }
    }
}

test "inverseTrig: a branch means the same branch however many were selected" {
    var in_buf: [1]TPiece = undefined;
    var one: [1]TPiece = undefined;
    var two: [2]TPiece = undefined;
    var pool: [16]Assignment = undefined;
    var pool2: [16]Assignment = undefined;

    var w1 = TWriter.init(one[0..], pool[0..]);
    const only_zero = try branches.inverseTrig(&w1, leafSet(&in_buf, Tracked.point(0.5)), .circle, .sin, 51, &.{0});

    var w2 = TWriter.init(two[0..], pool2[0..]);
    const zero_and_one = try branches.inverseTrig(&w2, leafSet(&in_buf, Tracked.point(0.5)), .circle, .sin, 51, &.{ 0, 1 });

    // The cell of branch 0 does not move because branch 1 was asked for as
    // well: a choice is a stable name for a cell, not a position in a list.
    // Matched by value, since the label encoding is not pinned here.
    try std.testing.expectEqual(@as(usize, 1), only_zero.pieces.len);
    const a = only_zero.pieces[0];
    const b = try pieceInBracket(zero_and_one, 0.5, 0.6);
    try expectEncloses(a.value, 0x3fe0c152382d7365, 0x3fe0c152382d7366);
    try std.testing.expect(a.value.range.?.eql(b.value.range.?));
    try expectMap(a.assignments, b.assignments);
}

test "inverseTrig: a finite family is the two roots, exactly antisymmetric" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    // cosh(t) = 3/2 has exactly two real solutions, +acosh(3/2) and its
    // negative, so the finite family is complete at two.
    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.inverseTrig(&w, leafSet(&in_buf, Tracked.point(1.5)), .hyperbola, .cosh, 51, &.{ 0, 1 });

    try std.testing.expectEqual(@as(usize, 2), out.pieces.len);
    try expectDistinctCells(out, 51);

    // Matched by sign, again by mathematics rather than by label.
    var positive: ?Interval = null;
    var negative: ?Interval = null;
    for (out.pieces) |p| {
        const r = p.value.range orelse return error.MissingRange;
        if (r.lo > 0.0) positive = r else if (r.hi < 0.0) negative = r;
    }
    const lo = positive orelse return error.MissingBranch;
    const hi = negative orelse return error.MissingBranch;
    // cosh is even, so the two roots are each other's reflection.
    try std.testing.expectEqual(-hi.hi, lo.lo);
    try std.testing.expectEqual(-hi.lo, lo.hi);
    try std.testing.expect(lo.lo > 0.0);
    try std.testing.expect(hi.hi < 0.0);

    // And both round trip.
    for (out.pieces) |p| {
        const back = try answerInterval(trig.forward(.hyperbola, .cosh, p.value.range.?));
        try std.testing.expect(back.contains(1.5));
    }
}

// ===========================================================================
// Set comparison: the join of possible outcomes, not a conjunction.
// ===========================================================================

test "compare: possible outcomes are joined over compatible pairs" {
    var a_pieces: [2]TPiece = undefined;
    var b_pieces: [2]TPiece = undefined;

    // Provably equal singletons at different sites: every pair says true.
    a_pieces[0] = .{ .value = Tracked.point(1.0), .assignments = &.{.{ .site = 1, .choice = 0 }} };
    b_pieces[0] = .{ .value = Tracked.point(1.0), .assignments = &.{.{ .site = 2, .choice = 0 }} };
    try std.testing.expectEqual(Truth.always, branches.compare(
        .{ .pieces = a_pieces[0..1] },
        .{ .pieces = b_pieces[0..1] },
        .eq,
    ));

    // Provably unequal: every pair says false.
    b_pieces[0] = .{ .value = Tracked.point(2.0), .assignments = &.{.{ .site = 2, .choice = 0 }} };
    try std.testing.expectEqual(Truth.never, branches.compare(
        .{ .pieces = a_pieces[0..1] },
        .{ .pieces = b_pieces[0..1] },
        .eq,
    ));

    // Undecidable, and the answer says so rather than choosing.
    b_pieces[0] = .{ .value = Tracked.init(Interval.init(1.0, 3.0)), .assignments = &.{.{ .site = 2, .choice = 0 }} };
    try std.testing.expectEqual(Truth.maybe, branches.compare(
        .{ .pieces = a_pieces[0..1] },
        .{ .pieces = b_pieces[0..1] },
        .eq,
    ));

    // One pair true and one pair false joins to maybe. The join is a union
    // of outcome sets; a library that conjoined them would answer never and
    // would have thrown away a true outcome.
    a_pieces[1] = .{ .value = Tracked.point(1.0), .assignments = &.{.{ .site = 1, .choice = 1 }} };
    b_pieces[1] = .{ .value = Tracked.point(2.0), .assignments = &.{.{ .site = 2, .choice = 1 }} };
    try std.testing.expectEqual(Truth.maybe, branches.compare(
        .{ .pieces = a_pieces[0..2] },
        .{ .pieces = b_pieces[0..2] },
        .eq,
    ));
}

test "compare: order relations, and never for no compatible pair at all" {
    var a_pieces: [1]TPiece = undefined;
    var b_pieces: [1]TPiece = undefined;

    a_pieces[0] = .{ .value = Tracked.point(1.0), .assignments = &.{.{ .site = 1, .choice = 0 }} };
    b_pieces[0] = .{ .value = Tracked.point(2.0), .assignments = &.{.{ .site = 2, .choice = 0 }} };
    try std.testing.expectEqual(Truth.always, branches.compare(
        .{ .pieces = a_pieces[0..] },
        .{ .pieces = b_pieces[0..] },
        .lt,
    ));
    try std.testing.expectEqual(Truth.never, branches.compare(
        .{ .pieces = a_pieces[0..] },
        .{ .pieces = b_pieces[0..] },
        .gt,
    ));
    try std.testing.expectEqual(Truth.always, branches.compare(
        .{ .pieces = a_pieces[0..] },
        .{ .pieces = b_pieces[0..] },
        .le,
    ));
    // Two distinct singletons are not equal, and ne is the negation of that.
    try std.testing.expectEqual(Truth.never, branches.compare(
        .{ .pieces = a_pieces[0..] },
        .{ .pieces = b_pieces[0..] },
        .eq,
    ));
    try std.testing.expectEqual(Truth.always, branches.compare(
        .{ .pieces = a_pieces[0..] },
        .{ .pieces = b_pieces[0..] },
        .ne,
    ));

    // No compatible pairs at all: there is no outcome to join, so the answer
    // is never rather than maybe. That is the whole difference between a
    // comparison over the alternatives and a conjunction over them.
    b_pieces[0] = .{ .value = Tracked.point(2.0), .assignments = &.{.{ .site = 1, .choice = 0 }} };
    try std.testing.expectEqual(Truth.never, branches.compare(
        .{ .pieces = a_pieces[0..] },
        .{ .pieces = b_pieces[0..] },
        .lt,
    ));
    try std.testing.expectEqual(Truth.never, branches.compare(
        .{ .pieces = a_pieces[0..] },
        .{ .pieces = b_pieces[0..] },
        .eq,
    ));
}

test "compare: an undefined piece contributes false, and does not poison a true one" {
    var a_pieces: [2]TPiece = undefined;
    var b_pieces: [1]TPiece = undefined;

    // Wholly undefined against a value: the relation is false, so the answer
    // is never and not maybe. An undefined result does not turn into an
    // unknown one here.
    a_pieces[0] = .{ .value = Tracked.undefined(), .assignments = &.{.{ .site = 1, .choice = 0 }} };
    b_pieces[0] = .{ .value = Tracked.point(1.0), .assignments = &.{.{ .site = 2, .choice = 0 }} };
    try std.testing.expectEqual(Truth.never, branches.compare(
        .{ .pieces = a_pieces[0..1] },
        .{ .pieces = b_pieces[0..1] },
        .eq,
    ));

    // With a second pair that is provably true the join is maybe: each
    // piece's definedness is kept, per pair.
    a_pieces[1] = .{ .value = Tracked.point(1.0), .assignments = &.{.{ .site = 1, .choice = 1 }} };
    try std.testing.expectEqual(Truth.maybe, branches.compare(
        .{ .pieces = a_pieces[0..2] },
        .{ .pieces = b_pieces[0..1] },
        .eq,
    ));
}

// ===========================================================================
// Resource behaviour of the producers themselves.
// ===========================================================================

test "floor: a split that does not fit fails and keeps the earlier pieces" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [2]TPiece = undefined;
    var pool: [8]Assignment = undefined;

    // One piece already in the writer, to be found intact after the failure.
    var w = TWriter.init(pieces[0..], pool[0..]);
    try w.append(Tracked.point(99.0), &.{.{ .site = 1, .choice = 1 }});
    const before = w.view();

    // [0, 40] needs forty-one cells and there are two slots.
    try std.testing.expectError(
        error.CapacityExceeded,
        branches.floor(&w, leafSet(&in_buf, Tracked.init(Interval.init(0.0, 40.0))), 7),
    );

    // Rolled back to the entry checkpoint, with the earlier piece and its
    // binding unchanged: a failed split publishes nothing of itself.
    try std.testing.expectEqual(@as(usize, 1), w.view().pieces.len);
    try expectPiece(w.view().pieces[0].value, 99.0, 99.0, .always, .always);
    try expectMap(w.view().pieces[0].assignments, &.{.{ .site = 1, .choice = 1 }});
    try expectPiece(before.pieces[0].value, 99.0, 99.0, .always, .always);
}

test "floor: an impossible number of cells is refused before being enumerated" {
    var in_buf: [1]TPiece = undefined;
    var pieces: [4]TPiece = undefined;
    var pool: [16]Assignment = undefined;

    // [0, 1e18] has 1e18 + 1 cells. Enumerating them is not possible, so with
    // four slots the only honest answer is the resource error -- and getting
    // it means the count was refused BEFORE the enumeration rather than after
    // it, which is the whole difference between this test finishing and not
    // finishing. The choice type is i128 rather than a machine word, so even
    // naming the top cell cannot trap.
    var w = TWriter.init(pieces[0..], pool[0..]);
    try std.testing.expectError(
        error.CapacityExceeded,
        branches.floor(&w, leafSet(&in_buf, Tracked.init(Interval.init(0.0, 1e18))), 7),
    );
    try std.testing.expectEqual(@as(usize, 0), w.view().pieces.len);
}

test "a producer keeps every binding of a forty-binding input map" {
    var in_pool: [40]Assignment = undefined;
    var in_pieces: [1]TPiece = undefined;
    var pieces: [4]TPiece = undefined;
    var pool: [96]Assignment = undefined;

    const many = fortyUniform(in_pool[0..], 1_000_000, -3);
    in_pieces[0] = .{
        .value = Tracked.init(Interval.init(0.9, 1.1)),
        .assignments = many,
    };

    var w = TWriter.init(pieces[0..], pool[0..]);
    const out = try branches.floor(&w, .{ .pieces = in_pieces[0..] }, 7);

    try std.testing.expectEqual(@as(usize, 2), out.pieces.len);
    for (out.pieces) |p| {
        // Forty incoming bindings plus the cut: forty-one, none dropped, and
        // the new site sorted in with the rest.
        try std.testing.expectEqual(@as(usize, 41), p.assignments.len);
        try expectSortedUnique(p.assignments);
        for (many) |a| try expectChoice(p.assignments, a.site, a.choice);
        _ = try choiceAt(p.assignments, 7);
    }
}