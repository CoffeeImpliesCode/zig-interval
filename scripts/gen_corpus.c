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
 *   * In MPFR 4.x the enum is RNDN=0 RNDZ=1 RNDU=2 RNDD=3 - RNDU and RNDD are
 *     SWAPPED relative to MPFR 3.x.
 *   * mpfr_get_d takes (srcptr, rnd). The `d` default parameter was removed in
 *     MPFR 4, and passing the old three-argument form silently reads the wrong
 *     register for the rounding mode.
 *
 * Evaluating the two directions SEPARATELY is not belt and braces. Evaluating
 * once and rounding the result to f64 rounds TWICE, and the second rounding is
 * not the one that was certified. MPFR's ternary return is kept so an exact
 * result stays separable from an inexact one - "the answer is exactly this"
 * versus "the answer is near this" - which is the whole of the f128 trap the
 * oracle's own header warns about.
 *
 * Written in C, against the real mpfr.h, rather than through a hand-rolled
 * ctypes binding. That is not stylistic: on this host MPFR 4.2.1's mpfr_get_d
 * did not honour its rounding-mode argument for any mode other than
 * round-to-nearest when reached from Python, and a corpus built on unverified
 * rounding directions is wrong invisibly - it either rejects correct answers,
 * or, if the brackets are widened to compensate, accepts answers it should not.
 * Compiling against the header removes the question entirely - and it turns
 * out the header was what the Python binding needed most. MPFR 4.x dropped
 * the `d` default parameter: `mpfr_get_d` takes (srcptr, rnd), not
 * (srcptr, d, rnd). The earlier binding passed three arguments to a
 * two-argument function, so the rounding mode was never read at all and the
 * "alternation" was a mis-called ABI rather than a broken library.
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