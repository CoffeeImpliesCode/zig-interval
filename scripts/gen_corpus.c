/* Generate the directed-rounding containment corpus for T4.
 *
 * This is the generator the test-and-architecture plan's T4 section specifies.
 * It calls MPFR at 256 bits and writes one certified bracket per row:
 *
 *     want_lo = mpfr_get_d(f_down, RNDD)   f_down = f(x) evaluated with RNDD
 *     want_hi = mpfr_get_d(f_up,   RNDU)   f_up   = f(x) evaluated with RNDU
 *
 * Three things about MPFR's interface are worth knowing before changing this
 * file, and all three were got wrong in an earlier version:
 *
 *   * The ternary return is 0 for exact, +1 for inexact-rounded-UP and -1 for
 *     inexact-rounded-DOWN. -1 is NOT "not a number". Guarding on `>= 0` reads
 *     every inexact result as a failure.
 *   * The rounding modes are an ENUM with the values RNDN=0 RNDZ=1 RNDU=2
 *     RNDD=3, and that numbering is IDENTICAL in MPFR 3.1.6 and 4.2.1 - MPFR 4
 *     did not renumber it. Use the named constants, and read the numbers out of
 *     the header being compiled against: hardcoding 2 and 3 on the belief that
 *     "4.x swapped them" is how the next version of this file breaks. Swapped
 *     for real, they invert every bracket, which at least fails loudly.
 *   * mpfr_get_d takes (srcptr, rnd) - exactly two arguments, in every release
 *     from 3.1.6 to 4.2.1. There is no `d` parameter and there never was one.
 *     The hazard is that MPFR 3 declares it through _MPFR_PROTO, which expands
 *     to an unprototyped `()` for a K&R compiler, so a third argument is taken
 *     without a diagnostic; on x86-64 it lands in %rdx while the rounding mode
 *     is read from %esi.
 *
 * Evaluating the two directions SEPARATELY is not belt and braces. Evaluating
 * once and rounding the result to f64 rounds TWICE, and the second rounding is
 * not the one that was certified. MPFR's ternary return is kept so an exact
 * result stays separable from an inexact one - "the answer is exactly this"
 * versus "the answer is near this" - which is the whole of the f128 trap the
 * oracle's own header warns about.
 *
 * Written in C, against the real mpfr.h, rather than through a hand-rolled
 * ctypes binding. That is not stylistic: `mpfr_get_d` has taken exactly two
 * arguments in every release from 3.1.6 to 4.2.1, and the earlier binding
 * passed three. The third landed in a register the function never reads, so
 * the rounding mode was whatever that register happened to hold - usually 0,
 * which is precisely why round-to-nearest looked like it worked while every
 * other mode looked broken, and why the fault was hunted in the library
 * instead of at the call site. A corpus built that way is wrong invisibly: it
 * either rejects correct answers, or, if the brackets are widened to
 * compensate, accepts answers it should not. Compiling against the real
 * header removes the question entirely - and it turns out the header was what
 * the Python binding needed most.
 *
 * The `gamma` rows are a SECOND KIND of row in the same format, and they are
 * the only ones whose argument list is its own: the elementary sweep below
 * draws one list of arguments for twenty-one functions that are all defined
 * at every real, while the real Gamma function has poles, leaves the `f64`
 * range long before its argument does, and is worth pointing at arguments
 * that nothing else in the file reaches. Its emitter is separate for the same
 * reason its arguments are, and both are documented where they are written.
 *
 * Build:  see scripts/build_mpfr.sh
 * Usage:  ./gen_corpus > tests/corpus/elementary.txt
 */

#include <mpfr.h>
#include <math.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define PREC 256

static uint64_t bits(double x) {
    uint64_t u;
    memcpy(&u, &x, sizeof u);
    return u;
}

/* Arguments chosen to cover the shapes the finite sweep draws, plus the
 * subnormal and range-boundary ends where an enclosure's margin is what keeps
 * a bound from cutting off a real. */
static const double ARGS[] = {
    0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 3.0, -3.0,
    0.1, -0.1, 0.9, 1.5, -0.25, 10.0, -10.0, 1e-8, -1e-8,
    700.0, -700.0,
    /* The exponent that broke powf's fixed relative margin: 1.0000000001^1e8.
     * It is here because the corpus is now the reference the reproducer is
     * re-pointed at, and a corpus that does not contain the case cannot
     * certify it. */
    1.0000000001, 1e8,
    0x1p-1074,                  /* smallest positive subnormal          */
    -0x1p-1074,                 /* smallest negative subnormal          */
    0x1p-1022,                  /* smallest normal                      */
    0x1.fffffffffffffp1023,     /* floatMax                              */
    -0x1.fffffffffffffp1023,
};
static const int NARGS = (int)(sizeof ARGS / sizeof ARGS[0]);

typedef int (*unary_fn)(mpfr_ptr, mpfr_srcptr, mpfr_rnd_t);
typedef int (*binary_fn)(mpfr_ptr, mpfr_srcptr, mpfr_srcptr, mpfr_rnd_t);

static int g_wrote = 0;

/* Certified f64 bracket for f(x). Returns MPFR's ternary, or INT_MIN if the
 * result is not a number (a domain violation: nothing to enclose). */
static int bracket(unary_fn f, double x, double *wlo, double *whi) {
    mpfr_t xi, down, up;
    mpfr_init2(xi, PREC);
    mpfr_init2(down, PREC);
    mpfr_init2(up, PREC);
    int t = INT_MIN;
    mpfr_set_d(xi, x, MPFR_RNDN);
    int t1 = f(down, xi, MPFR_RNDD);
    int t2 = f(up, xi, MPFR_RNDU);
    /* MPFR's ternary is 0 for exact, +1 for inexact-rounded-up and -1 for
     * inexact-rounded-DOWN. It is NOT a NaN flag: an earlier version of this
     * file guarded with `t1 >= 0 && t2 >= 0`, which reads every inexact
     * result as a failure and silently kept only the exact rows - so the tier
     * appeared to pass while checking nothing but exp(0) and sin(0). NaN is
     * tested on the value instead. */
    if (!mpfr_nan_p(down) && !mpfr_nan_p(up)) {
        double lo = mpfr_get_d(down, MPFR_RNDD);
        double hi = mpfr_get_d(up, MPFR_RNDU);
        /* The bracket is only useful if it is not inverted. MPFR guarantees
         * down <= up; if the two f64 endpoints came back the other way round
         * the certified pair has been lost and the row is dropped rather than
         * emitted as a bound that excludes the truth. */
        /* An INFINITE bracket is not a real image. At a point argument, an
         * infinite result means the function has no finite value there - the
         * limit log(0) = -inf, atanh(1) = +inf - and the library models that by
         * REFUSING, which is a different question from enclosing a value. A
         * row like that would make the tier report a false disagreement. */
        if (lo <= hi && !isinf(lo) && !isinf(hi) && !isnan(lo) && !isnan(hi)) {
            *wlo = lo;
            *whi = hi;
            t = (t1 < t2) ? t1 : t2;
        }
    }
    mpfr_clear(xi);
    mpfr_clear(down);
    mpfr_clear(up);
    return t;
}

static void emit_unary(const char *name, unary_fn f, double x) {
    double lo, hi;
    int t = bracket(f, x, &lo, &hi);
    if (t == INT_MIN) return;
    printf("%s %016" PRIx64 " %016" PRIx64 " %016" PRIx64 " %016" PRIx64 " %d\n",
           name, bits(x), bits(x), bits(lo), bits(hi), t);
    g_wrote++;
}

static void emit_binary(const char *name, binary_fn f, double a, double b) {
    mpfr_t ai, bi, down, up;
    mpfr_init2(ai, PREC);
    mpfr_init2(bi, PREC);
    mpfr_init2(down, PREC);
    mpfr_init2(up, PREC);
    mpfr_set_d(ai, a, MPFR_RNDN);
    mpfr_set_d(bi, b, MPFR_RNDN);
    int t1 = f(down, ai, bi, MPFR_RNDD);
    int t2 = f(up, ai, bi, MPFR_RNDU);
    if (!mpfr_nan_p(down) && !mpfr_nan_p(up)) {
        double lo = mpfr_get_d(down, MPFR_RNDD);
        double hi = mpfr_get_d(up, MPFR_RNDU);
        if (lo <= hi && !isinf(lo) && !isinf(hi)) {
            printf("%s %016" PRIx64 " %016" PRIx64 " %016" PRIx64 " %016" PRIx64 " %d\n",
                   name, bits(a), bits(b), bits(lo), bits(hi),
                   (t1 < t2) ? t1 : t2);
            g_wrote++;
        }
    }
    mpfr_clear(ai);
    mpfr_clear(bi);
    mpfr_clear(down);
    mpfr_clear(up);
}

static void emit_pow(double x, long n) {
    mpfr_t xi, down, up;
    mpfr_init2(xi, PREC);
    mpfr_init2(down, PREC);
    mpfr_init2(up, PREC);
    mpfr_set_d(xi, x, MPFR_RNDN);
    /* mpfr_pow_si takes a SIGNED exponent, so the negative case needs no
     * separate path and no reasoning about which way the rounding has to go.
     * Two earlier versions of this file got it wrong: the first swapped the
     * endpoints of x^m (a negative exponent is an INVERSION, so the image is a
     * different real, not the same two bounds the other way round), and the
     * second reached for mpfr_ui_pow, which computes (1/n)^op rather than
     * 1/op^n. Both produced plausible-looking rows that were not the image. */
    int t1 = mpfr_pow_si(down, xi, (long)n, MPFR_RNDD);
    int t2 = mpfr_pow_si(up, xi, (long)n, MPFR_RNDU);
    if (!mpfr_nan_p(down) && !mpfr_nan_p(up)) {
        double lo = mpfr_get_d(down, MPFR_RNDD);
        double hi = mpfr_get_d(up, MPFR_RNDU);
        if (isinf(lo) || isinf(hi) || isnan(lo) || isnan(hi)) {
            mpfr_clear(xi); mpfr_clear(down); mpfr_clear(up);
            return;
        }
        printf("pow %016" PRIx64 " %016" PRIx64 " %016" PRIx64 " %016" PRIx64 " %d %ld\n",
               bits(x), bits(x), bits(lo), bits(hi),
               (t1 < t2) ? t1 : t2, n);
        g_wrote++;
    }
    mpfr_clear(xi);
    mpfr_clear(down);
    mpfr_clear(up);
}

/* The arguments the `gamma` rows are generated at, in the order they are
 * emitted. Every one of them is a SINGLETON: the two endpoint fields of the
 * row carry the same value twice, which is how a unary row is written above
 * and is what lets the test runner build a one-point interval without a
 * second format to agree on. */
static const double GAMMA_ARGS[] = {
    /* Positive. The half-integers, where the value is a rational multiple of
     * sqrt(pi), the integers, where it is a factorial, and the quarters,
     * which are the one shape here that is neither. */
    0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 6.5,
    10.0, 20.0, 30.0, 100.0,
    /* Negative non-integers. The value is a quotient of pi by a sine, so the
     * sign alternates with every pole crossed and a row that gets the sign
     * wrong is wrong by an infinity rather than by an epsilon. */
    -0.25, -0.5, -1.25, -1.5, -2.25, -2.5, -3.5, -4.5, -5.5, -10.5,
    /* EITHER SIDE of the first two poles. Each pair is the row that catches a
     * reflection formula that loses its sign, and the offsets are powers of
     * two so that the argument is exact and no decimal is in the path. */
    -1.0 + 0x1p-20, -1.0 - 0x1p-20,
    -2.0 + 0x1p-20, -2.0 - 0x1p-20,
    /* Just off zero, where the value is large again and, on the positive
     * side, is Gamma(eps) ~ 1/eps rather than a pole. */
    0x1p-20, 0x1p-40, -0x1p-20, -0x1p-40,
    1.0 + 0x1p-20,
    /* The high end. 170! is 7.2574e306 and is still a double; 171! is
     * 1.2452e309 and is not, so these three arguments bracket the place
     * where the function leaves the format and the last one emits nothing. */
    170.0, 171.0, 172.0,
    /* A value below the smallest positive double, and a POSITIVE one: it is
     * 1/2 - 400, an even number of poles down, so the sign alternation puts
     * it above zero. Its certified bracket is [0, 2^-1074], which is a real
     * constraint - an answer of [0, 0] would exclude a positive value - and
     * the negative counterpart is deliberately absent, because there the
     * upper endpoint rounds toward zero to -0.0 and no enclosing answer that
     * is one subnormal wide would meet a bound that is exactly -0.0. */
    -399.5,
    /* The poles themselves. MPFR answers NaN at each of these and NOTHING is
     * emitted for any of them; they are in the table so that their absence is
     * a property of this file and not of whichever sweep supplied the rest
     * of the arguments. */
    0.0, -1.0, -2.0, -3.0, -4.0,
};
static const int NGAMMA = (int)(sizeof GAMMA_ARGS / sizeof GAMMA_ARGS[0]);

/* One `gamma` row, or none. The format is the unary format above, field for
 * field, and the three ways to emit nothing here are three different pieces
 * of mathematics rather than three versions of one guard:
 *
 *   * At a pole there is no real value at all, and MPFR says so with a NaN.
 *   * A value that has left the `f64` range is a finite real that no double
 *     can be an endpoint of. Saturating it is not a bracket either: under
 *     RNDD an overflow becomes -floatMax, which is BELOW every real past the
 *     end of the range, so emitting it would state a bound that excludes the
 *     truth. This is checked on the MPFR value, before the conversion,
 *     because afterwards the two cases are the same number.
 *   * The directed endpoints can still come back inverted or non-finite, and
 *     the same rule as everywhere else applies: drop the row rather than
 *     publish a pair that is not a bracket.
 */
static void emit_gamma(double x) {
    mpfr_t xi, down, up;
    mpfr_init2(xi, PREC);
    mpfr_init2(down, PREC);
    mpfr_init2(up, PREC);
    mpfr_set_d(xi, x, MPFR_RNDN);
    int t1 = mpfr_gamma(down, xi, MPFR_RNDD);
    int t2 = mpfr_gamma(up, xi, MPFR_RNDU);

    int ok = !mpfr_nan_p(down) && !mpfr_nan_p(up) &&
             !mpfr_inf_p(down) && !mpfr_inf_p(up);
    double lo = 0.0, hi = 0.0;
    if (ok) {
        lo = mpfr_get_d(down, MPFR_RNDD);
        hi = mpfr_get_d(up, MPFR_RNDU);
        ok = (lo <= hi) && !isinf(lo) && !isinf(hi) && !isnan(lo) && !isnan(hi);
    }
    if (ok) {
        printf("gamma %016" PRIx64 " %016" PRIx64 " %016" PRIx64 " %016" PRIx64 " %d\n",
               bits(x), bits(x), bits(lo), bits(hi),
               (t1 < t2) ? t1 : t2);
        g_wrote++;
    }

    mpfr_clear(xi);
    mpfr_clear(down);
    mpfr_clear(up);
}

int main(void) {
    static const struct { const char *name; unary_fn f; } UNARY[] = {
        {"exp", mpfr_exp},     {"exp2", mpfr_exp2},   {"expm1", mpfr_expm1},
        {"log", mpfr_log},     {"log2", mpfr_log2},   {"log10", mpfr_log10},
        {"log1p", mpfr_log1p}, {"sin", mpfr_sin},     {"cos", mpfr_cos},
        {"tan", mpfr_tan},     {"asin", mpfr_asin},   {"acos", mpfr_acos},
        {"atan", mpfr_atan},   {"sinh", mpfr_sinh},   {"cosh", mpfr_cosh},
        {"tanh", mpfr_tanh},   {"asinh", mpfr_asinh}, {"acosh", mpfr_acosh},
        {"atanh", mpfr_atanh}, {"sqrt", mpfr_sqrt},   {"cbrt", mpfr_cbrt},
    };
    static const long EXPS[] = {0, 1, 2, 3, 5, 7, -1, -2, -3};

    printf("# op lo_hex hi_hex want_lo_hex want_hi_hex ternary [exponent]\n");
    printf("# generated by scripts/gen_corpus.c against MPFR %s at %d bits\n",
           mpfr_get_version(), PREC);
    printf("# endpoints and bounds are exact f64 bit patterns; no decimal is in the path\n");

    for (size_t u = 0; u < sizeof UNARY / sizeof UNARY[0]; u++)
        for (int i = 0; i < NARGS; i++)
            emit_unary(UNARY[u].name, UNARY[u].f, ARGS[i]);

    /* The Gamma rows, which carry their own argument list and their own
     * emitter, and whose rows are singletons like the unary ones above. */
    for (int i = 0; i < NGAMMA; i++)
        emit_gamma(GAMMA_ARGS[i]);

    for (int i = 0; i < NARGS; i++)
        for (size_t e = 0; e < sizeof EXPS / sizeof EXPS[0]; e++)
            emit_pow(ARGS[i], EXPS[e]);

    for (int i = 0; i < NARGS; i++)
        for (int j = 0; j < NARGS; j++) {
            if (ARGS[i] < 0.0) continue; /* no real general power of a negative base */
            emit_binary("powf", mpfr_pow, ARGS[i], ARGS[j]);
        }

    for (int i = 0; i < NARGS; i++)
        for (int j = 0; j < NARGS; j++)
            emit_binary("atan2", mpfr_atan2, ARGS[i], ARGS[j]);

    fprintf(stderr, "gen_corpus: wrote %d rows\n", g_wrote);
    return 0;
}