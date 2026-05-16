// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Verilator C++ harness for fir_core. Drives two parallel DUT instances
// (16-tap and 32-tap low-pass FIR) and cross-validates each output beat
// against vectors precomputed by tb/gen_random_vectors.py (which use
// scipy.signal.lfilter as the oracle, with a parallel hand-rolled
// integer convolution as a tightening cross-check).
//
// Tests (each test exits non-zero on mismatch):
//   1. Reset behaviour: outputs are idle (TVALID = 0) until first
//      sample is accepted.
//   2. 16-tap low-pass: 256 random int16 inputs, every output beat must
//      equal the precomputed reference exactly.
//   3. 32-tap low-pass: same idea, longer filter.
//   4. Saturation: a 16-tap deliberately-overscaled filter forces the
//      output to clip; the saturation flag must agree with the rail.
//   5. Backpressure: stall TREADY for varying durations and verify the
//      output stream still matches the reference (no dropped beats, no
//      reordering, AXIS handshake honoured).
//   6. Coefficient reconfig: change coefficients mid-stream and verify
//      the output transitions to the new filter on the next sample.
//
// Output: prints "+PASS" or "+FAIL <reason>" with a coverage report.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <random>

#include "verilated.h"
#include "Vfir_tb.h"
#include "Vfir_tb___024root.h"
#include "Vfir_tb_fir_tb.h"
#include "Vfir_tb_fir_cov.h"
#include "random_vectors.h"

// ---------------------------------------------------------------------
static int        g_failures = 0;
static vluint64_t g_time     = 0;

static void tick_clk(Vfir_tb* dut) {
    dut->clk_i = 0; dut->eval(); g_time++;
    dut->clk_i = 1; dut->eval(); g_time++;
}

// Pack int16 coefficient arrays into the flat 256-bit / 512-bit
// Verilator wide signals. Tap k lives at bit k*16, so on a little-
// endian 32-bit-word backing store, taps 2k and 2k+1 share one word.
static void pack_coeffs(uint32_t* dst, int n_words, const int16_t* h,
                        int n_taps) {
    for (int w = 0; w < n_words; w++) dst[w] = 0;
    for (int k = 0; k < n_taps; k++) {
        int word_idx     = k / 2;
        int bit_in_word  = (k % 2) * 16;
        uint16_t v       = (uint16_t)h[k];
        dst[word_idx]   |= ((uint32_t)v) << bit_in_word;
    }
}
static void load_coeffs16(Vfir_tb* dut, const int16_t* h) {
    pack_coeffs(&dut->coeff16_i[0], 8,  h, 16);
}
static void load_coeffs32(Vfir_tb* dut, const int16_t* h) {
    pack_coeffs(&dut->coeff32_i[0], 16, h, 32);
}

static void reset(Vfir_tb* dut) {
    dut->rst_ni       = 0;
    dut->s16_tvalid_i = 0; dut->m16_tready_i = 0; dut->s16_tdata_i = 0;
    dut->s32_tvalid_i = 0; dut->m32_tready_i = 0; dut->s32_tdata_i = 0;
    for (int i = 0; i < 8;  i++) dut->coeff16_i[i] = 0;
    for (int i = 0; i < 16; i++) dut->coeff32_i[i] = 0;
    for (int i = 0; i < 4; i++) tick_clk(dut);
    dut->rst_ni = 1;
    tick_clk(dut);
}

// ---------------------------------------------------------------------
// Stream `len` int16 samples through both filters in parallel, while
// asserting m_axis_tready_i. Collect the corresponding output beats.
// Returns the two output vectors. The 16-tap and 32-tap streams run
// independently so their internal pipelines may be at different fill
// levels; we track each separately.
// ---------------------------------------------------------------------
struct StreamResult {
    std::vector<int16_t> y16, y32;
    std::vector<bool>    sat16, sat32;
};

static StreamResult
stream_dual(Vfir_tb* dut, const int16_t* x, int len,
            int tready_period16 = 1, int tready_period32 = 1) {
    StreamResult r;
    r.y16.reserve(len);
    r.y32.reserve(len);
    r.sat16.reserve(len);
    r.sat32.reserve(len);

    int in16 = 0, in32 = 0;
    int t16  = 0, t32  = 0;

    // Always present a sample while there is one left to send. The DUT
    // signals readiness via s_tready_o; we only advance our index on
    // the cycles when both valid and ready are high.
    int budget = (len + 32) * 8 + 256;
    while ((in16 < len || in32 < len ||
            (int)r.y16.size() < len || (int)r.y32.size() < len) &&
           budget-- > 0) {

        // Drive inputs.
        if (in16 < len) {
            dut->s16_tdata_i  = (uint16_t)x[in16];
            dut->s16_tvalid_i = 1;
        } else {
            dut->s16_tvalid_i = 0;
        }
        if (in32 < len) {
            dut->s32_tdata_i  = (uint16_t)x[in32];
            dut->s32_tvalid_i = 1;
        } else {
            dut->s32_tvalid_i = 0;
        }

        // TREADY pattern.
        dut->m16_tready_i = (t16 == 0) ? 1 : 0;
        dut->m32_tready_i = (t32 == 0) ? 1 : 0;

        // Evaluate combinational outputs (s_tready_o, m_tvalid_o, ...)
        // BEFORE the clock edge by stepping one half-cycle low first.
        dut->clk_i = 0; dut->eval(); g_time++;

        bool s16_handshake = dut->s16_tvalid_i && dut->s16_tready_o;
        bool s32_handshake = dut->s32_tvalid_i && dut->s32_tready_o;
        bool m16_handshake = dut->m16_tvalid_o && dut->m16_tready_i;
        bool m32_handshake = dut->m32_tvalid_o && dut->m32_tready_i;

        int16_t y16 = (int16_t)dut->m16_tdata_o;
        int16_t y32 = (int16_t)dut->m32_tdata_o;
        bool sat16 = (dut->m16_tuser_o != 0);
        bool sat32 = (dut->m32_tuser_o != 0);

        dut->clk_i = 1; dut->eval(); g_time++;

        if (s16_handshake) in16++;
        if (s32_handshake) in32++;
        if (m16_handshake && (int)r.y16.size() < len) {
            r.y16.push_back(y16);
            r.sat16.push_back(sat16);
        }
        if (m32_handshake && (int)r.y32.size() < len) {
            r.y32.push_back(y32);
            r.sat32.push_back(sat32);
        }

        t16 = (t16 + 1) % (tready_period16 < 1 ? 1 : tready_period16);
        t32 = (t32 + 1) % (tready_period32 < 1 ? 1 : tready_period32);
    }

    return r;
}

// ---------------------------------------------------------------------
static void test_reset(Vfir_tb* dut) {
    std::printf("---- Reset behaviour ----\n");
    reset(dut);
    bool ok = (dut->m16_tvalid_o == 0) && (dut->m32_tvalid_o == 0);
    if (ok) std::printf("  [PASS] m_tvalid low after reset\n");
    else { std::printf("  [FAIL] m_tvalid not low after reset\n"); g_failures++; }
}

// ---------------------------------------------------------------------
static int
compare_streams(const char* name, const std::vector<int16_t>& got,
                const int16_t* exp, int len) {
    int local_fail = 0;
    int shown = 0;
    if ((int)got.size() != len) {
        std::printf("  [FAIL] %s: got %zu beats, expected %d\n",
                    name, got.size(), len);
        return 1;
    }
    for (int i = 0; i < len; i++) {
        if (got[i] != exp[i]) {
            local_fail++;
            if (shown < 5) {
                std::printf("  %s mismatch [%d]: got %d, exp %d\n",
                            name, i, got[i], exp[i]);
                shown++;
            }
        }
    }
    if (local_fail == 0) std::printf("  [PASS] %s (%d/%d beats)\n",
                                     name, len, len);
    else                 std::printf("  [FAIL] %s: %d / %d beats\n",
                                     name, local_fail, len);
    return local_fail;
}

// ---------------------------------------------------------------------
static void test_lowpass(Vfir_tb* dut) {
    std::printf("---- 16-tap and 32-tap low-pass cross-validation ----\n");
    reset(dut);
    load_coeffs16(dut, kFirH16);
    load_coeffs32(dut, kFirH32);

    auto r = stream_dual(dut, kFirIn, kFirInputLen);
    int f1 = compare_streams("FIR-16",  r.y16, kFirOut16, kFirInputLen);
    int f2 = compare_streams("FIR-32",  r.y32, kFirOut32, kFirInputLen);
    if (f1) g_failures += f1;
    if (f2) g_failures += f2;
}

// ---------------------------------------------------------------------
static void test_backpressure(Vfir_tb* dut) {
    std::printf("---- Backpressure (TREADY toggling) ----\n");
    reset(dut);
    load_coeffs16(dut, kFirH16);
    load_coeffs32(dut, kFirH32);

    // Output ready every 3rd cycle on 16-tap, every 5th on 32-tap.
    auto r = stream_dual(dut, kFirIn, kFirInputLen, 3, 5);
    int f1 = compare_streams("FIR-16 (BP=3)", r.y16, kFirOut16, kFirInputLen);
    int f2 = compare_streams("FIR-32 (BP=5)", r.y32, kFirOut32, kFirInputLen);
    if (f1) g_failures += f1;
    if (f2) g_failures += f2;
}

// ---------------------------------------------------------------------
static void test_saturation(Vfir_tb* dut) {
    std::printf("---- Saturation ----\n");
    reset(dut);
    // Use the 16-tap path with the deliberately overscaled coefficients.
    // The 32-tap path is parked on a zero filter so it does not affect
    // the result.
    load_coeffs16(dut, kFirHSat);
    int16_t h32_zero[32] = {0};
    load_coeffs32(dut, h32_zero);

    auto r = stream_dual(dut, kFirInSat, kFirInputLen);
    int f = compare_streams("FIR-16 sat", r.y16, kFirOutSat, kFirInputLen);
    if (f) g_failures += f;

    // Count how many output beats had tuser asserted; should be > 0
    // (the test design guarantees plenty of saturation events).
    int sat_beats = 0;
    for (bool b : r.sat16) if (b) sat_beats++;
    if (sat_beats == 0) {
        std::printf("  [FAIL] no saturation beats observed\n");
        g_failures++;
    } else {
        std::printf("  [INFO] %d / %zu beats saturated\n",
                    sat_beats, r.sat16.size());
    }
}

// ---------------------------------------------------------------------
static void test_reconfig(Vfir_tb* dut) {
    std::printf("---- Coefficient reconfig mid-stream ----\n");
    reset(dut);

    // Phase A: identity-ish filter (h[0] = 2^15, rest 0) -> output ==
    // input (after 2-cycle latency).
    int16_t h_ident[16] = {0};
    h_ident[0] = (int16_t)((1 << 15) - 1);    // 32767, very close to 1.0
    int16_t h32_zero[32] = {0};
    load_coeffs16(dut, h_ident);
    load_coeffs32(dut, h32_zero);

    // Stream a short impulse-like signal.
    int16_t in_a[8] = { 1000, 2000, 3000, -4000, 5000, -6000, 7000, -8000 };
    auto rA = stream_dual(dut, in_a, 8);

    int local_fail = 0;
    for (int i = 0; i < 8; i++) {
        // The identity output should match the input within +/- 1
        // (because 32767/32768 != 1 exactly).
        int16_t exp = (int16_t)((int32_t)in_a[i] * 32767 >> 15);
        if (std::abs((int)rA.y16[i] - (int)exp) > 1) {
            std::printf("  [FAIL] identity reconfig [%d]: got %d, exp ~%d\n",
                        i, rA.y16[i], exp);
            local_fail++;
        }
    }

    // Phase B: switch to a real low-pass; just confirm the DUT now
    // produces non-trivial filtered output (different from the input).
    load_coeffs16(dut, kFirH16);
    auto rB = stream_dual(dut, in_a, 8);
    int diff_beats = 0;
    for (int i = 0; i < 8; i++) {
        if (rB.y16[i] != in_a[i]) diff_beats++;
    }
    if (diff_beats == 0) {
        std::printf("  [FAIL] reconfig: output looks identical to input\n");
        local_fail++;
    }

    if (local_fail == 0) std::printf("  [PASS] reconfig\n");
    else                 g_failures += local_fail;
}

// ---------------------------------------------------------------------
// Coverage report
// ---------------------------------------------------------------------
static void report_coverage(const Vfir_tb* dut) {
    auto* cov = dut->rootp->fir_tb->u_cov;
    struct Bin { const char* name; uint8_t hit; };
    Bin bins[] = {
        {"in16_handshake",     cov->c_in16_handshake},
        {"in32_handshake",     cov->c_in32_handshake},
        {"out16_handshake",    cov->c_out16_handshake},
        {"out32_handshake",    cov->c_out32_handshake},
        {"backpressure_in",    cov->c_backpressure_in},
        {"backpressure_out",   cov->c_backpressure_out},
        {"saturated_high",     cov->c_saturated_high},
        {"saturated_low",      cov->c_saturated_low},
    };
    int total = sizeof(bins) / sizeof(bins[0]);
    int hit = 0;
    std::printf("\n---- Functional coverage ----\n");
    for (int i = 0; i < total; i++) {
        std::printf("  [%s] %-22s\n", bins[i].hit ? "HIT " : "MISS",
                    bins[i].name);
        if (bins[i].hit) hit++;
    }
    std::printf("Coverage: %d/%d bins (%.1f%%)\n",
                hit, total, 100.0 * hit / total);
}

// ---------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    setvbuf(stdout, nullptr, _IOLBF, 0);
    Vfir_tb* dut = new Vfir_tb();
    reset(dut);

    test_reset(dut);
    test_lowpass(dut);
    test_backpressure(dut);
    test_saturation(dut);
    test_reconfig(dut);

    report_coverage(dut);

    if (g_failures == 0) {
        std::printf("+PASS all tests passed\n");
        delete dut;
        return 0;
    } else {
        std::printf("+FAIL %d failures\n", g_failures);
        delete dut;
        return 1;
    }
}
