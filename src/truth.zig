//! Three-valued truth: an ENCLOSURE of the possible answers to a question
//! that has two answers.
//!
//! The three states here are not a three-valued logic invented for its own
//! sake. They are what an interval of answers looks like when the answer is
//! a Boolean: an enclosure of a number is a pair of bounds on a real, and
//! an enclosure of a truth is a pair of bounds on the number a Boolean is,
//! namely zero and one. `never` is the interval `[0, 0]`, `always` is
//! `[1, 1]`, and `maybe` is `[0, 1]`.
//!
//! That reading is the whole of the type, and it settles every question a
//! caller has about it. `maybe` does NOT mean the answer is mixed: it means
//! the enclosure admits both answers, which is a claim about what is KNOWN
//! rather than about what is. A value that is certainly one of the two, for
//! reasons the tracker does not have, is `maybe` here, and a caller that
//! treats `maybe` as "it varies" has read the type as something it is not.
//! Every operation below is therefore defined on the OUTCOME SET a state
//! allows — `never` allows {false}, `maybe` allows {false, true}, `always`
//! allows {true} — and each answers the enclosure of the outcome that
//! operation produces over those sets.
//!
//! The outcome-set reading makes the five operations below precise rather
//! than suggestive, and it is worth stating the rule they share: an
//! operation is reported as `always` when it holds for EVERY pair of
//! outcomes its arguments allow, as `never` when it fails for every pair,
//! and as `maybe` between. `maybe` is what a genuine mixture reports, and
//! it is also what an argument whose own outcomes are unknown reports, and
//! the two are deliberately not distinguished.
//!
//! `join` is the exception that proves the rule, and it is the operation
//! most often written wrongly. It is the union of the two outcome SETS, not
//! a Boolean `or` over an order on the states: `always` and `never` together
//! allow both outcomes, so they join to `maybe` and not to `always`. The
//! Boolean reading is not a harmless variant here — it asserts that only
//! one of the two outcomes is possible, which one of the two arguments
//! rules out — so `join` is spelled the way it is spelled and its table is
//! written down in the tests rather than derived from a rank.

/// Which Boolean outcomes a question is still allowed to answer, as an
/// enclosure rather than as an answer.
///
/// The state carries two bounds on the indicator "is this true": `lower`
/// says the indicator is certainly one, `upper` says it could be one. Two
/// outcomes and two ordered bounds give three states and not four, because
/// a bound below a bound would be a fourth state no answer can be in.
pub const Truth = enum(u2) {
    /// Certainly false: the only outcome allowed is `false`.
    never = 0,
    /// Not known: both outcomes are allowed, which is a claim about
    /// knowledge rather than a claim that the answer varies.
    maybe = 1,
    /// Certainly true: the only outcome allowed is `true`.
    always = 2,

    /// The state whose indicator lies in `[lo, hi]`.
    ///
    /// `lo <= hi` is a precondition and not a guarantee: a caller who asks
    /// for the indicator to be certainly one and only possibly zero has
    /// asked for a state that does not exist, and the crossing is diagnosed
    /// by `std.debug.assert` in Debug and ReleaseSafe.
    pub fn fromBounds(lo: bool, hi: bool) Truth {
        std.debug.assert(!lo or hi);
        if (lo) return .always;
        if (hi) return .maybe;
        return .never;
    }

    /// Whether the answer is certainly true.
    ///
    /// False for both `never` and `maybe`: `maybe` allows the false
    /// outcome, so nothing about it is certain. True only for `always`.
    pub fn lower(self: Truth) bool {
        return self == .always;
    }

    /// Whether the answer may be true.
    ///
    /// True for `maybe` and `always`, false only for `never`, which is the
    /// state that rules the true outcome out.
    pub fn upper(self: Truth) bool {
        return self != .never;
    }

    /// The other answer: the state that allows exactly the outcomes this one
    /// does not.
    ///
    /// An involution, since negating twice swaps the two bounds back, and a
    /// fixed point on `maybe`, whose outcome set is closed under
    /// complementation.
    pub fn negate(self: Truth) Truth {
        return switch (self) {
            .never => .always,
            .maybe => .maybe,
            .always => .never,
        };
    }

    /// Conjunction: the outcome is `self and other`, over the outcome sets.
    ///
    /// The intersection of the two sets, which is `fromBounds` of the two
    /// lowers and the two uppers. It is certainly true only when BOTH
    /// arguments are certainly true, and certainly false as soon as EITHER
    /// rules the true outcome out.
    pub fn both(self: Truth, other: Truth) Truth {
        return .fromBounds(self.lower() and other.lower(), self.upper() and other.upper());
    }

    /// Disjunction: the outcome is `self or other`, over the outcome sets.
    ///
    /// A disjunction SEES an outcome each argument allows and settles on
    /// one, which is why it is not the union of the two sets — `join` below
    /// is that, and the two differ on exactly the pair `always` and `never`,
    /// where this answers `always` and the union answers `maybe`. It is
    /// certainly true as soon as EITHER argument is certainly true, and
    /// certainly false only when both rule the true outcome out.
    pub fn either(self: Truth, other: Truth) Truth {
        return .fromBounds(self.lower() or other.lower(), self.upper() or other.upper());
    }

    /// Material implication, `self -> other`, over the outcome sets.
    ///
    /// Certainly true when no pair of allowed outcomes falsifies it. The
    /// only falsifying pair is a true antecedent with a false consequent, so
    /// the truth of the lower bound is `self` rules the true outcome out, or
    /// `other` is certainly true. Certainly false only when the antecedent
    /// is certainly true and the consequent certainly false, which is what
    /// the upper bound reads.
    ///
    /// A false antecedent makes the whole thing certainly true, which is the
    /// first row of the table and the reason this is the material form and
    /// not a semantic one: there is no world here in which the outcome
    /// depends on anything but the two enclosures.
    pub fn implies(self: Truth, other: Truth) Truth {
        return .fromBounds(!self.upper() or other.lower(), !self.lower() or other.upper());
    }

    /// Equivalence of two outcomes, over the outcome sets.
    ///
    /// Certainly true only when both arguments are SETTLED and they settled
    /// the same way: two states that both allow both outcomes are not known
    /// equal, however alike they look. Certainly false when both are settled
    /// and they settled differently, and `maybe` in between, where one side
    /// allows both outcomes and so cannot be compared with the other either
    /// way.
    ///
    /// Two `maybe`s answer `maybe` rather than `always`, and that is the
    /// claim worth making. They are the same state and not the same answer:
    /// each admits both outcomes, so they may agree and may not, and neither
    /// `always` (known equal) nor `never` (known different) is available on
    /// that pair. Reading "same state" as "same value" is what turns this
    /// into the one connective that reports knowledge it does not have.
    pub fn equivalent(self: Truth, other: Truth) Truth {
        // `self == other` is not the whole answer, and using it alone would
        // say that two `maybe`s are certainly equal: they are the same STATE,
        // not the same value, and what each admits is exactly what the other
        // admits. So `always` needs both agreement AND a state that settles
        // the question, which rules out `maybe` on both sides.
        const settled = self != .maybe and other != .maybe;
        const same = self == other;
        return .fromBounds(same and settled, same or self == .maybe or other == .maybe);
    }

    /// Union of the two outcome SETS, which is not a Boolean `or`.
    ///
    /// The state that allows every outcome either argument allows. It is
    /// certainly true only when both arguments are certainly true — the
    /// union adds outcomes rather than removing them — and it is possibly
    /// true as soon as either is, which is the half the union shares with
    /// the conjunction and the half it does not.
    ///
    /// `always.join(never)` is `maybe`, and that cell is the whole reason
    /// this operation exists: read as a Boolean `or` over a rank on the
    /// states it would answer `always`, asserting that only the true outcome
    /// is possible when one of the two arguments rules out precisely that.
    pub fn join(self: Truth, other: Truth) Truth {
        return .fromBounds(self.lower() and other.lower(), self.upper() or other.upper());
    }
};