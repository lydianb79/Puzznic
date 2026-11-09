// NESCore implementation: 6502 CPU, 2C02 PPU (scanline renderer with loopy scrolling),
// 2A03 APU, NROM (mapper 0) / UxROM (mapper 2) / CNROM (mapper 3) cartridges, standard controllers.
#include "nescore.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <stdatomic.h>

#define CPU_HZ 1789773.0
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// ---------------------------------------------------------------------------
// State (POD only, so save states are a plain memcpy)
// ---------------------------------------------------------------------------
typedef struct {
    uint8_t a, x, y, s, p;
    uint16_t pc;
    int nmi_pending;
    int irq_line;
    uint64_t cycles;
    int stall;
} CPU;

typedef struct {
    uint8_t ctrl, mask, status, oamaddr;
    uint16_t v, t;
    uint8_t fx, w;
    uint8_t readbuf, openbus;
    uint8_t oam[256];
    uint8_t ciram[2048];
    uint8_t pal[32];
    int scanline, dot;
    int odd;
    int frame_done;
    int s0_hit_dot; // dot on current line where sprite 0 hit happens, -1 if none
    uint64_t frame;
} PPU;

typedef struct {
    int enabled;
    uint8_t duty, dutypos;
    int length;
    int halt; // also envelope loop
    int const_vol;
    uint8_t vol;
    int env_start; uint8_t env_div, env_decay;
    int sweep_en, sweep_neg, sweep_reload; uint8_t sweep_period, sweep_shift, sweep_div;
    uint16_t timer_period, timer;
    int ones_complement; // pulse 1 uses ones' complement negate
} Pulse;

typedef struct {
    int enabled; int length; int control;
    uint8_t linear_reload, linear; int linear_reload_flag;
    uint16_t timer_period, timer; uint8_t seq;
} Triangle;

typedef struct {
    int enabled; int length; int halt; int const_vol; uint8_t vol;
    int env_start; uint8_t env_div, env_decay;
    int mode; uint16_t timer_period, timer; uint16_t lfsr;
} Noise;

typedef struct {
    int enabled; int irq_en; int loop; int irq_flag;
    uint16_t rate, timer;
    uint8_t output;
    uint16_t sample_addr, sample_len;
    uint16_t cur_addr, bytes_left;
    uint8_t shift; int bits_left; int silence;
    uint8_t buffer; int buffer_empty;
} DMC;

typedef struct {
    Pulse p1, p2; Triangle tri; Noise noise; DMC dmc;
    int fc_mode; int fc_irq_inhibit; int fc_irq; uint32_t fc_cycle;
    int fc_reset_delay; uint8_t fc_pending_val;
    uint64_t cycle;
    // resampling / filters
    double acc; double acc_n; double frac;
    double hp1_prev_in, hp1_prev_out, hp2_prev_in, hp2_prev_out, lp_prev;
} APU;

typedef struct {
    CPU cpu; PPU ppu; APU apu;
    uint8_t ram[2048];
    uint8_t prgram[8192];
    uint8_t pad_state[2], pad_shift[2], pad_strobe;
    uint8_t buttons[2];
    uint8_t chr_bank, prg_bank; // mapper registers (CNROM / UxROM)
} Machine;


// ---------------------------------------------------------------------------
// "Remastered" audio: state for re-synthesising the APU channels
// ---------------------------------------------------------------------------
typedef struct { float ic1, ic2; } SVF;
typedef struct { float lp, bp, hp; } SVFOut;

#define ENH_COMB_MAX 3400
#define ENH_AP_MAX 1400
#define ENH_CHORUS 4096
typedef struct {
    float ph[3];           // oscillator phases
    float freq_s, amp_s;   // smoothed frequency / amplitude
    SVF f;
} EnhVoice;

typedef struct {
    EnhVoice p[2];
    float tri_ph, tri_sub_ph, tri_freq_s, tri_amp_s;
    float noise_amp_s, noise_hold, noise_ph;
    uint32_t rng;
    SVF nlp, nhp;
    float dmc_prev_in, dmc_hp;
    float chorus[ENH_CHORUS]; int chorus_w; float lfo;
    float comb[8][ENH_COMB_MAX]; int comb_len[8], comb_idx[8]; float comb_filt[8];
    float ap[4][ENH_AP_MAX]; int ap_len[4], ap_idx[4];
    float dcl_in, dcl_out, dcr_in, dcr_out;
    double configured_rate;
} Enh;

#define RING 16384 // stereo frames
struct NES {
    Machine m;
    // cartridge
    uint8_t* prg; size_t prg_size;
    uint8_t chr[8192]; int chr_ram;
    uint8_t* chr_rom; size_t chr_banks; // all CHR-ROM banks (CNROM switches 8 KB at a time)
    int mapper;
    int vertical_mirror;
    // config
    int unlimited_sprites;
    uint32_t chan_mask;
    int audio_enabled;
    int audio_mode; // 0 original, 1 remastered
    float enh_reverb, enh_width, enh_bass; int enh_tone;
    Enh enh;
    double sample_rate, rate_adjust;
    float palette_rgb[192];
    uint32_t palette_rgba[64];
    // outputs
    uint32_t fb[NES_W * NES_H];
    uint8_t layer_bg[NES_W * NES_H];
    uint8_t layer_spr[NES_W * NES_H];
    uint8_t layer_bd[NES_H];
    // audio ring buffer (single producer: emulation thread, single consumer: audio thread)
    float ring[RING * 2];
    _Atomic uint32_t ring_w, ring_r;
};

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------
void nes_build_palette(float* out, float sat, float hue_deg, float contrast, float bright, float gamma) {
    static const float lo_t[4] = {0.350f, 0.518f, 0.962f, 1.550f};
    static const float hi_t[4] = {1.094f, 1.506f, 1.962f, 1.962f};
    const float black = 0.518f, white = 1.962f;
    if (gamma <= 0.1f) gamma = 2.2f;
    for (int c = 0; c < 64; c++) {
        int hue = c & 15, level = (c >> 4) & 3;
        float lo = lo_t[level], hi = hi_t[level];
        if (hue == 0) lo = hi;
        if (hue == 13) hi = lo;
        if (hue > 13) lo = hi = black;
        float y = 0, i = 0, q = 0;
        for (int p = 0; p < 12; p++) {
            float spot = (((hue + p + 8) % 12) < 6) ? hi : lo;
            float v = (spot - black) / (white - black);
            float ang = (float)M_PI * ((float)p + hue_deg / 30.0f) / 6.0f;
            y += v; i += v * cosf(ang); q += v * sinf(ang);
        }
        y /= 12.0f; i /= 12.0f; q /= 12.0f;
        i *= sat * 1.0f; q *= sat * 1.0f;
        y = (y - 0.5f) * contrast + 0.5f + bright;
        float rgb[3] = {
            y + 0.946882f * i + 0.623557f * q,
            y - 0.274788f * i - 0.635691f * q,
            y - 1.108545f * i + 1.709007f * q };
        for (int k = 0; k < 3; k++) {
            float f = rgb[k];
            f = f < 0 ? 0 : (f > 1 ? 1 : f);
            f = powf(f, 2.2f / gamma);
            out[c * 3 + k] = f;
        }
    }
}

void nes_set_palette(NES* n, const float* rgb) {
    memcpy(n->palette_rgb, rgb, sizeof(n->palette_rgb));
    for (int c = 0; c < 64; c++) {
        uint32_t r = (uint32_t)(rgb[c*3+0] * 255.0f + 0.5f);
        uint32_t g = (uint32_t)(rgb[c*3+1] * 255.0f + 0.5f);
        uint32_t b = (uint32_t)(rgb[c*3+2] * 255.0f + 0.5f);
        n->palette_rgba[c] = 0xFF000000u | (b << 16) | (g << 8) | r;
    }
}

// ---------------------------------------------------------------------------
// Forward decls
// ---------------------------------------------------------------------------
static uint8_t cpu_read(NES* n, uint16_t a);
static void    cpu_write(NES* n, uint16_t a, uint8_t v);
static void    ppu_step(NES* n, int dots);
static void    apu_step(NES* n, int cycles);
static uint8_t apu_read_status(NES* n);
static void    apu_write(NES* n, uint16_t a, uint8_t v);

// ---------------------------------------------------------------------------
// PPU memory
// ---------------------------------------------------------------------------
static inline uint16_t nt_index(const NES* n, uint16_t a) {
    a &= 0x0FFF;
    int table = (a >> 10) & 3;
    int bank = n->vertical_mirror ? (table & 1) : ((table >> 1) & 1);
    return (uint16_t)(bank * 0x400 + (a & 0x3FF));
}
static inline uint8_t pal_index(uint16_t a) {
    a &= 0x1F;
    if ((a & 0x13) == 0x10) a &= 0x0F;
    return (uint8_t)a;
}
static inline const uint8_t* chr_cur(const NES* n) {
    if (n->chr_ram || !n->chr_banks) return n->chr;
    return n->chr_rom + (size_t)(n->m.chr_bank % n->chr_banks) * 8192;
}
static uint8_t ppu_mem_read(NES* n, uint16_t a) {
    a &= 0x3FFF;
    if (a < 0x2000) return chr_cur(n)[a];
    if (a < 0x3F00) return n->m.ppu.ciram[nt_index(n, a)];
    return n->m.ppu.pal[pal_index(a)];
}
static void ppu_mem_write(NES* n, uint16_t a, uint8_t v) {
    a &= 0x3FFF;
    if (a < 0x2000) { if (n->chr_ram) n->chr[a] = v; return; }
    if (a < 0x3F00) { n->m.ppu.ciram[nt_index(n, a)] = v; return; }
    n->m.ppu.pal[pal_index(a)] = v & 0x3F;
}

static uint8_t ppu_reg_read(NES* n, uint16_t a) {
    PPU* p = &n->m.ppu;
    switch (a & 7) {
    case 2: {
        uint8_t r = (uint8_t)((p->status & 0xE0) | (p->openbus & 0x1F));
        p->status &= 0x7F;
        p->w = 0;
        p->openbus = r;
        return r;
    }
    case 4: p->openbus = p->oam[p->oamaddr]; return p->openbus;
    case 7: {
        uint16_t addr = p->v & 0x3FFF;
        uint8_t r;
        if (addr >= 0x3F00) {
            r = (uint8_t)((ppu_mem_read(n, addr) & 0x3F) | (p->openbus & 0xC0));
            p->readbuf = ppu_mem_read(n, addr - 0x1000);
        } else {
            r = p->readbuf;
            p->readbuf = ppu_mem_read(n, addr);
        }
        p->v = (uint16_t)((p->v + ((p->ctrl & 4) ? 32 : 1)) & 0x7FFF);
        p->openbus = r;
        return r;
    }
    default: return p->openbus;
    }
}

static void ppu_reg_write(NES* n, uint16_t a, uint8_t v) {
    PPU* p = &n->m.ppu;
    p->openbus = v;
    switch (a & 7) {
    case 0: {
        uint8_t old = p->ctrl;
        p->ctrl = v;
        p->t = (uint16_t)((p->t & 0xF3FF) | ((v & 3) << 10));
        if (!(old & 0x80) && (v & 0x80) && (p->status & 0x80)) n->m.cpu.nmi_pending = 1;
        break;
    }
    case 1: p->mask = v; break;
    case 3: p->oamaddr = v; break;
    case 4: p->oam[p->oamaddr++] = v; break;
    case 5:
        if (!p->w) { p->t = (uint16_t)((p->t & ~0x001F) | (v >> 3)); p->fx = v & 7; p->w = 1; }
        else { p->t = (uint16_t)((p->t & 0x8C1F) | ((v & 7) << 12) | ((v & 0xF8) << 2)); p->w = 0; }
        break;
    case 6:
        if (!p->w) { p->t = (uint16_t)((p->t & 0x00FF) | ((v & 0x3F) << 8)); p->w = 1; }
        else { p->t = (uint16_t)((p->t & 0xFF00) | v); p->v = p->t; p->w = 0; }
        break;
    case 7:
        ppu_mem_write(n, p->v, v);
        p->v = (uint16_t)((p->v + ((p->ctrl & 4) ? 32 : 1)) & 0x7FFF);
        break;
    }
}

// ---------------------------------------------------------------------------
// PPU scanline renderer
// ---------------------------------------------------------------------------
static void render_line(NES* n, int line) {
    PPU* p = &n->m.ppu;
    uint8_t bgpix[NES_W];   // 0 = transparent else palette RAM index (1..15 non-zero lowbits)
    uint8_t sppix[NES_W];   // palette RAM index 16..31 or 0
    uint8_t spbehind[NES_W];
    uint8_t sp0[NES_W];
    memset(bgpix, 0, sizeof bgpix);
    memset(sppix, 0, sizeof sppix);
    memset(spbehind, 0, sizeof spbehind);
    memset(sp0, 0, sizeof sp0);
    int show_bg = (p->mask & 0x08) != 0;
    int show_sp = (p->mask & 0x10) != 0;
    p->s0_hit_dot = -1;

    if (show_bg) {
        uint16_t v = p->v;
        int fine_y = (v >> 12) & 7;
        uint16_t pt = (p->ctrl & 0x10) ? 0x1000 : 0;
        int x = -(int)p->fx;
        for (int tile = 0; tile < 33; tile++) {
            uint16_t ntaddr = (uint16_t)(0x2000 | (v & 0x0FFF));
            uint8_t tileno = ppu_mem_read(n, ntaddr);
            uint16_t ataddr = (uint16_t)(0x23C0 | (v & 0x0C00) | ((v >> 4) & 0x38) | ((v >> 2) & 0x07));
            uint8_t at = ppu_mem_read(n, ataddr);
            int shift = ((v >> 4) & 4) | (v & 2);
            uint8_t palsel = (uint8_t)((at >> shift) & 3);
            uint8_t lo = chr_cur(n)[(pt + tileno * 16 + fine_y) & 0x1FFF];
            uint8_t hi = chr_cur(n)[(pt + tileno * 16 + fine_y + 8) & 0x1FFF];
            for (int b = 0; b < 8; b++, x++) {
                if (x < 0 || x >= NES_W) continue;
                int bit = 7 - b;
                uint8_t pix = (uint8_t)(((lo >> bit) & 1) | (((hi >> bit) & 1) << 1));
                if (pix && (x >= 8 || (p->mask & 0x02))) bgpix[x] = (uint8_t)(palsel * 4 + pix);
            }
            // increment coarse X with nametable wrap
            if ((v & 0x001F) == 31) { v &= ~0x001F; v ^= 0x0400; } else v++;
        }
    }

    if (show_sp) {
        int h = (p->ctrl & 0x20) ? 16 : 8;
        int count = 0;
        int limit = n->unlimited_sprites ? 64 : 8;
        for (int i = 0; i < 64; i++) {
            int sy = p->oam[i * 4 + 0];
            int row = line - (sy + 1);
            if (row < 0 || row >= h) continue;
            if (count == 8) p->status |= 0x20; // sprite overflow
            if (count >= limit) break;
            count++;
            uint8_t tileno = p->oam[i * 4 + 1];
            uint8_t attr = p->oam[i * 4 + 2];
            int sx = p->oam[i * 4 + 3];
            if (attr & 0x80) row = h - 1 - row;
            uint16_t addr;
            if (h == 16) {
                uint16_t table = (tileno & 1) ? 0x1000 : 0;
                uint8_t t = tileno & 0xFE;
                if (row >= 8) { t++; row -= 8; }
                addr = (uint16_t)(table + t * 16 + row);
            } else {
                uint16_t table = (p->ctrl & 0x08) ? 0x1000 : 0;
                addr = (uint16_t)(table + tileno * 16 + row);
            }
            const uint8_t* cc = chr_cur(n); uint8_t lo = cc[addr & 0x1FFF], hi = cc[(addr + 8) & 0x1FFF];
            for (int b = 0; b < 8; b++) {
                int x = sx + b;
                if (x >= NES_W) break;
                int bit = (attr & 0x40) ? b : 7 - b;
                uint8_t pix = (uint8_t)(((lo >> bit) & 1) | (((hi >> bit) & 1) << 1));
                if (!pix) continue;
                if (x < 8 && !(p->mask & 0x04)) continue;
                if (i == 0) sp0[x] = 1;
                if (sppix[x]) continue; // lower OAM index wins
                sppix[x] = (uint8_t)(16 + (attr & 3) * 4 + pix);
                spbehind[x] = (attr & 0x20) ? 1 : 0;
            }
        }
    }

    // composite + layer export
    uint8_t backdrop = p->pal[0] & 0x3F;
    uint8_t grey = (p->mask & 0x01) ? 0x30 : 0x3F;
    n->layer_bd[line] = backdrop & grey;
    uint32_t* fbl = &n->fb[line * NES_W];
    uint8_t* lb = &n->layer_bg[line * NES_W];
    uint8_t* ls = &n->layer_spr[line * NES_W];
    for (int x = 0; x < NES_W; x++) {
        uint8_t bgc = bgpix[x] ? (uint8_t)(p->pal[pal_index(bgpix[x])] & grey) : 0;
        uint8_t spc = sppix[x] ? (uint8_t)(p->pal[pal_index(sppix[x])] & grey) : 0;
        lb[x] = bgpix[x] ? (uint8_t)(1 + bgc) : 0;
        ls[x] = sppix[x] ? (uint8_t)((1 + spc) | (spbehind[x] ? 0x80 : 0)) : 0;
        uint8_t col;
        if (sppix[x] && (!spbehind[x] || !bgpix[x])) col = spc;
        else if (bgpix[x]) col = bgc;
        else col = backdrop & grey;
        fbl[x] = n->palette_rgba[col];
        if (sp0[x] && bgpix[x] && x != 255 && p->s0_hit_dot < 0 && !(p->status & 0x40))
            p->s0_hit_dot = x + 2;
    }
}

static inline int rendering(const PPU* p) { return (p->mask & 0x18) != 0; }

static void incr_y(PPU* p) {
    if ((p->v & 0x7000) != 0x7000) p->v += 0x1000;
    else {
        p->v &= ~0x7000;
        int y = (p->v & 0x03E0) >> 5;
        if (y == 29) { y = 0; p->v ^= 0x0800; }
        else if (y == 31) y = 0;
        else y++;
        p->v = (uint16_t)((p->v & ~0x03E0) | (y << 5));
    }
}

static void blank_line(NES* n, int line) {
    PPU* p = &n->m.ppu;
    uint8_t bd = p->pal[0] & 0x3F;
    // with rendering off, the PPU shows the colour v points at if it is inside palette RAM
    if (((p->v & 0x3FFF) >= 0x3F00)) bd = p->pal[pal_index(p->v)] & 0x3F;
    n->layer_bd[line] = bd;
    for (int x = 0; x < NES_W; x++) n->fb[line * NES_W + x] = n->palette_rgba[bd];
    memset(&n->layer_bg[line * NES_W], 0, NES_W);
    memset(&n->layer_spr[line * NES_W], 0, NES_W);
}

static void ppu_step(NES* n, int dots) {
    PPU* p = &n->m.ppu;
    while (dots-- > 0) {
        int line = p->scanline, dot = p->dot;
        if (line < 240) {
            if (dot == 1) {
                if (rendering(p)) render_line(n, line); else { blank_line(n, line); p->s0_hit_dot = -1; }
            }
            if (p->s0_hit_dot >= 0 && dot == p->s0_hit_dot && rendering(p)) { p->status |= 0x40; p->s0_hit_dot = -1; }
            if (rendering(p)) {
                if (dot == 256) incr_y(p);
                if (dot == 257) p->v = (uint16_t)((p->v & ~0x041F) | (p->t & 0x041F));
            }
        } else if (line == 241 && dot == 1) {
            p->status |= 0x80;
            if (p->ctrl & 0x80) n->m.cpu.nmi_pending = 1;
            p->frame_done = 1;
        } else if (line == 261) {
            if (dot == 1) { p->status &= 0x1F; }
            if (rendering(p)) {
                if (dot == 257) p->v = (uint16_t)((p->v & ~0x041F) | (p->t & 0x041F));
                if (dot == 280) p->v = (uint16_t)((p->v & ~0x7BE0) | (p->t & 0x7BE0));
                if (dot == 339 && p->odd) { p->dot = 340; }
            }
        }
        p->dot++;
        if (p->dot > 340) {
            p->dot = 0;
            p->scanline++;
            if (p->scanline > 261) { p->scanline = 0; p->odd ^= 1; p->frame++; }
        }
    }
}

// ---------------------------------------------------------------------------
// Bus
// ---------------------------------------------------------------------------
static uint8_t cpu_read(NES* n, uint16_t a) {
    Machine* m = &n->m;
    if (a < 0x2000) return m->ram[a & 0x7FF];
    if (a < 0x4000) return ppu_reg_read(n, a);
    if (a == 0x4015) return apu_read_status(n);
    if (a == 0x4016 || a == 0x4017) {
        int port = a & 1;
        uint8_t r;
        if (m->pad_strobe) r = m->buttons[port] & 1;
        else { r = m->pad_shift[port] & 1; m->pad_shift[port] = (uint8_t)((m->pad_shift[port] >> 1) | 0x80); }
        return (uint8_t)(0x40 | r);
    }
    if (a < 0x6000) return 0;
    if (a < 0x8000) return m->prgram[a & 0x1FFF];
    if (n->mapper == 2) {
        size_t banks = n->prg_size / 16384;
        size_t bank = a < 0xC000 ? (size_t)m->prg_bank % banks : banks - 1;
        return n->prg[bank * 16384 + (a & 0x3FFF)];
    }
    return n->prg[(a - 0x8000) % n->prg_size];
}

static void cpu_write(NES* n, uint16_t a, uint8_t v) {
    Machine* m = &n->m;
    if (a < 0x2000) { m->ram[a & 0x7FF] = v; return; }
    if (a < 0x4000) { ppu_reg_write(n, a, v); return; }
    if (a == 0x4014) {
        uint16_t base = (uint16_t)(v << 8);
        for (int i = 0; i < 256; i++) m->ppu.oam[(m->ppu.oamaddr + i) & 0xFF] = cpu_read(n, (uint16_t)(base + i));
        m->cpu.stall += 513 + (int)(m->cpu.cycles & 1);
        return;
    }
    if (a == 0x4016) {
        m->pad_strobe = v & 1;
        if (m->pad_strobe) { m->pad_shift[0] = m->buttons[0]; m->pad_shift[1] = m->buttons[1]; }
        return;
    }
    if (a <= 0x4017) { apu_write(n, a, v); return; }
    if (a >= 0x6000 && a < 0x8000) { m->prgram[a & 0x1FFF] = v; return; }
    if (a >= 0x8000) {
        // discrete-logic mappers have bus conflicts: the written value is ANDed with ROM
        uint8_t busv = (uint8_t)(v & cpu_read(n, a));
        if (n->mapper == 3) m->chr_bank = busv;
        else if (n->mapper == 2) m->prg_bank = busv;
    }
}

// ---------------------------------------------------------------------------
// CPU
// ---------------------------------------------------------------------------
enum { FC = 1, FZ = 2, FI = 4, FD = 8, FB = 16, FU = 32, FV = 64, FN = 128 };
enum { M_IMP, M_ACC, M_IMM, M_ZP, M_ZPX, M_ZPY, M_ABS, M_ABX, M_ABY, M_IND, M_IZX, M_IZY, M_REL };
enum {
    O_ADC, O_AND, O_ASL, O_BCC, O_BCS, O_BEQ, O_BIT, O_BMI, O_BNE, O_BPL, O_BRK, O_BVC, O_BVS, O_CLC,
    O_CLD, O_CLI, O_CLV, O_CMP, O_CPX, O_CPY, O_DEC, O_DEX, O_DEY, O_EOR, O_INC, O_INX, O_INY, O_JMP,
    O_JSR, O_LDA, O_LDX, O_LDY, O_LSR, O_NOP, O_ORA, O_PHA, O_PHP, O_PLA, O_PLP, O_ROL, O_ROR, O_RTI,
    O_RTS, O_SBC, O_SEC, O_SED, O_SEI, O_STA, O_STX, O_STY, O_TAX, O_TAY, O_TSX, O_TXA, O_TXS, O_TYA,
    O_KIL, O_SLO, O_RLA, O_SRE, O_RRA, O_SAX, O_LAX, O_DCP, O_ISB, O_ANC, O_ALR, O_ARR, O_XAA, O_AHX,
    O_TAS, O_SHY, O_SHX, O_LAS, O_AXS, O_COUNT
};
static const char* op_names[O_COUNT] = {
    "ADC","AND","ASL","BCC","BCS","BEQ","BIT","BMI","BNE","BPL","BRK","BVC","BVS","CLC",
    "CLD","CLI","CLV","CMP","CPX","CPY","DEC","DEX","DEY","EOR","INC","INX","INY","JMP",
    "JSR","LDA","LDX","LDY","LSR","NOP","ORA","PHA","PHP","PLA","PLP","ROL","ROR","RTI",
    "RTS","SBC","SEC","SED","SEI","STA","STX","STY","TAX","TAY","TSX","TXA","TXS","TYA",
    "KIL","SLO","RLA","SRE","RRA","SAX","LAX","DCP","ISB","ANC","ALR","ARR","XAA","AHX",
    "TAS","SHY","SHX","LAS","AXS" };

static const char* op_table =
 "BRK ORA KIL SLO NOP ORA ASL SLO PHP ORA ASL ANC NOP ORA ASL SLO "
 "BPL ORA KIL SLO NOP ORA ASL SLO CLC ORA NOP SLO NOP ORA ASL SLO "
 "JSR AND KIL RLA BIT AND ROL RLA PLP AND ROL ANC BIT AND ROL RLA "
 "BMI AND KIL RLA NOP AND ROL RLA SEC AND NOP RLA NOP AND ROL RLA "
 "RTI EOR KIL SRE NOP EOR LSR SRE PHA EOR LSR ALR JMP EOR LSR SRE "
 "BVC EOR KIL SRE NOP EOR LSR SRE CLI EOR NOP SRE NOP EOR LSR SRE "
 "RTS ADC KIL RRA NOP ADC ROR RRA PLA ADC ROR ARR JMP ADC ROR RRA "
 "BVS ADC KIL RRA NOP ADC ROR RRA SEI ADC NOP RRA NOP ADC ROR RRA "
 "NOP STA NOP SAX STY STA STX SAX DEY NOP TXA XAA STY STA STX SAX "
 "BCC STA KIL AHX STY STA STX SAX TYA STA TXS TAS SHY STA SHX AHX "
 "LDY LDA LDX LAX LDY LDA LDX LAX TAY LDA TAX LAX LDY LDA LDX LAX "
 "BCS LDA KIL LAX LDY LDA LDX LAX CLV LDA TSX LAS LDY LDA LDX LAX "
 "CPY CMP NOP DCP CPY CMP DEC DCP INY CMP DEX AXS CPY CMP DEC DCP "
 "BNE CMP KIL DCP NOP CMP DEC DCP CLD CMP NOP DCP NOP CMP DEC DCP "
 "CPX SBC NOP ISB CPX SBC INC ISB INX SBC NOP SBC CPX SBC INC ISB "
 "BEQ SBC KIL ISB NOP SBC INC ISB SED SBC NOP ISB NOP SBC INC ISB ";

static const char* mode_table =
 "imp izx imp izx zp  zp  zp  zp  imp imm acc imm abs abs abs abs "
 "rel izy imp izy zpx zpx zpx zpx imp aby imp aby abx abx abx abx "
 "abs izx imp izx zp  zp  zp  zp  imp imm acc imm abs abs abs abs "
 "rel izy imp izy zpx zpx zpx zpx imp aby imp aby abx abx abx abx "
 "imp izx imp izx zp  zp  zp  zp  imp imm acc imm abs abs abs abs "
 "rel izy imp izy zpx zpx zpx zpx imp aby imp aby abx abx abx abx "
 "imp izx imp izx zp  zp  zp  zp  imp imm acc imm ind abs abs abs "
 "rel izy imp izy zpx zpx zpx zpx imp aby imp aby abx abx abx abx "
 "imm izx imm izx zp  zp  zp  zp  imp imm imp imm abs abs abs abs "
 "rel izy imp izy zpx zpx zpy zpy imp aby imp aby abx abx aby aby "
 "imm izx imm izx zp  zp  zp  zp  imp imm imp imm abs abs abs abs "
 "rel izy imp izy zpx zpx zpy zpy imp aby imp aby abx abx aby aby "
 "imm izx imm izx zp  zp  zp  zp  imp imm imp imm abs abs abs abs "
 "rel izy imp izy zpx zpx zpx zpx imp aby imp aby abx abx abx abx "
 "imm izx imm izx zp  zp  zp  zp  imp imm imp imm abs abs abs abs "
 "rel izy imp izy zpx zpx zpx zpx imp aby imp aby abx abx abx abx ";

static const uint8_t cyc_table[256] = {
7,6,2,8,3,3,5,5,3,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
6,6,2,8,3,3,5,5,4,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
6,6,2,8,3,3,5,5,3,2,2,2,3,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
6,6,2,8,3,3,5,5,4,2,2,2,5,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
2,6,2,6,3,3,3,3,2,2,2,2,4,4,4,4, 2,6,2,6,4,4,4,4,2,5,2,5,5,5,5,5,
2,6,2,6,3,3,3,3,2,2,2,2,4,4,4,4, 2,5,2,5,4,4,4,4,2,4,2,4,4,4,4,4,
2,6,2,8,3,3,5,5,2,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
2,6,2,8,3,3,5,5,2,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7 };

static uint8_t g_op[256], g_mode[256], g_penalty[256];
static int g_tables_ready = 0;

static void build_tables(void) {
    if (g_tables_ready) return;
    for (int i = 0; i < 256; i++) {
        const char* on = op_table + i * 4;
        const char* mn = mode_table + i * 4;
        int op = O_NOP;
        for (int k = 0; k < O_COUNT; k++) if (!strncmp(on, op_names[k], 3)) { op = k; break; }
        int mode = M_IMP;
        if (!strncmp(mn, "imp", 3)) mode = M_IMP; else if (!strncmp(mn, "acc", 3)) mode = M_ACC;
        else if (!strncmp(mn, "imm", 3)) mode = M_IMM; else if (!strncmp(mn, "zpx", 3)) mode = M_ZPX;
        else if (!strncmp(mn, "zpy", 3)) mode = M_ZPY; else if (!strncmp(mn, "zp ", 3)) mode = M_ZP;
        else if (!strncmp(mn, "abs", 3)) mode = M_ABS; else if (!strncmp(mn, "abx", 3)) mode = M_ABX;
        else if (!strncmp(mn, "aby", 3)) mode = M_ABY; else if (!strncmp(mn, "ind", 3)) mode = M_IND;
        else if (!strncmp(mn, "izx", 3)) mode = M_IZX; else if (!strncmp(mn, "izy", 3)) mode = M_IZY;
        else if (!strncmp(mn, "rel", 3)) mode = M_REL;
        g_op[i] = (uint8_t)op; g_mode[i] = (uint8_t)mode;
        int reads = (op == O_LDA || op == O_LDX || op == O_LDY || op == O_EOR || op == O_AND || op == O_ORA ||
                     op == O_ADC || op == O_SBC || op == O_CMP || op == O_LAX || op == O_LAS ||
                     (op == O_NOP && mode == M_ABX));
        g_penalty[i] = (uint8_t)reads;
    }
    g_tables_ready = 1;
}

static inline void push(NES* n, uint8_t v) { n->m.ram[0x100 | n->m.cpu.s] = v; n->m.cpu.s--; }
static inline uint8_t pop(NES* n) { n->m.cpu.s++; return n->m.ram[0x100 | n->m.cpu.s]; }
static inline void setzn(CPU* c, uint8_t v) { c->p = (uint8_t)((c->p & ~(FZ | FN)) | (v ? 0 : FZ) | (v & 0x80)); }
static inline uint16_t rd16(NES* n, uint16_t a) { return (uint16_t)(cpu_read(n, a) | (cpu_read(n, (uint16_t)(a + 1)) << 8)); }

static void interrupt(NES* n, uint16_t vec, int brk) {
    CPU* c = &n->m.cpu;
    push(n, (uint8_t)(c->pc >> 8)); push(n, (uint8_t)c->pc);
    push(n, (uint8_t)((c->p | FU) & ~FB) | (brk ? FB : 0));
    c->p |= FI;
    c->pc = rd16(n, vec);
}

static inline void op_adc(CPU* c, uint8_t v) {
    unsigned sum = c->a + v + (c->p & FC);
    c->p = (uint8_t)((c->p & ~(FC | FV)) | (sum > 0xFF ? FC : 0) | ((~(c->a ^ v) & (c->a ^ sum) & 0x80) ? FV : 0));
    c->a = (uint8_t)sum; setzn(c, c->a);
}
static inline void op_cmp(CPU* c, uint8_t r, uint8_t v) {
    uint8_t d = (uint8_t)(r - v);
    c->p = (uint8_t)((c->p & ~FC) | (r >= v ? FC : 0)); setzn(c, d);
}

// Executes one instruction (or pending interrupt). Returns CPU cycles used.
static int cpu_step(NES* n) {
    CPU* c = &n->m.cpu;
    if (c->stall > 0) { int s = c->stall; c->stall = 0; return s; }
    if (c->nmi_pending) { c->nmi_pending = 0; interrupt(n, 0xFFFA, 0); return 7; }
    if (c->irq_line && !(c->p & FI)) { interrupt(n, 0xFFFE, 0); return 7; }

    uint8_t opc = cpu_read(n, c->pc++);
    int op = g_op[opc], mode = g_mode[opc];
    int cycles = cyc_table[opc];
    uint16_t addr = 0; int cross = 0;
    switch (mode) {
    case M_IMP: case M_ACC: break;
    case M_IMM: addr = c->pc++; break;
    case M_ZP:  addr = cpu_read(n, c->pc++); break;
    case M_ZPX: addr = (uint8_t)(cpu_read(n, c->pc++) + c->x); break;
    case M_ZPY: addr = (uint8_t)(cpu_read(n, c->pc++) + c->y); break;
    case M_ABS: addr = rd16(n, c->pc); c->pc += 2; break;
    case M_ABX: { uint16_t b = rd16(n, c->pc); c->pc += 2; addr = (uint16_t)(b + c->x); cross = (b & 0xFF00) != (addr & 0xFF00); break; }
    case M_ABY: { uint16_t b = rd16(n, c->pc); c->pc += 2; addr = (uint16_t)(b + c->y); cross = (b & 0xFF00) != (addr & 0xFF00); break; }
    case M_IND: { uint16_t pnt = rd16(n, c->pc); c->pc += 2;
        uint16_t hiaddr = (uint16_t)((pnt & 0xFF00) | ((pnt + 1) & 0x00FF));
        addr = (uint16_t)(cpu_read(n, pnt) | (cpu_read(n, hiaddr) << 8)); break; }
    case M_IZX: { uint8_t zp = (uint8_t)(cpu_read(n, c->pc++) + c->x);
        addr = (uint16_t)(n->m.ram[zp] | (n->m.ram[(uint8_t)(zp + 1)] << 8)); break; }
    case M_IZY: { uint8_t zp = cpu_read(n, c->pc++);
        uint16_t b = (uint16_t)(n->m.ram[zp] | (n->m.ram[(uint8_t)(zp + 1)] << 8));
        addr = (uint16_t)(b + c->y); cross = (b & 0xFF00) != (addr & 0xFF00); break; }
    case M_REL: { int8_t off = (int8_t)cpu_read(n, c->pc++); addr = (uint16_t)(c->pc + off); break; }
    }
    if (cross && g_penalty[opc]) cycles++;

#define BRANCH(cond) do { if (cond) { cycles++; if ((c->pc & 0xFF00) != (addr & 0xFF00)) cycles++; c->pc = addr; } } while (0)
#define RD() cpu_read(n, addr)
    uint8_t v;
    switch (op) {
    case O_LDA: c->a = RD(); setzn(c, c->a); break;
    case O_LDX: c->x = RD(); setzn(c, c->x); break;
    case O_LDY: c->y = RD(); setzn(c, c->y); break;
    case O_STA: cpu_write(n, addr, c->a); break;
    case O_STX: cpu_write(n, addr, c->x); break;
    case O_STY: cpu_write(n, addr, c->y); break;
    case O_ADC: op_adc(c, RD()); break;
    case O_SBC: op_adc(c, (uint8_t)~RD()); break;
    case O_AND: c->a &= RD(); setzn(c, c->a); break;
    case O_ORA: c->a |= RD(); setzn(c, c->a); break;
    case O_EOR: c->a ^= RD(); setzn(c, c->a); break;
    case O_CMP: op_cmp(c, c->a, RD()); break;
    case O_CPX: op_cmp(c, c->x, RD()); break;
    case O_CPY: op_cmp(c, c->y, RD()); break;
    case O_BIT: v = RD(); c->p = (uint8_t)((c->p & ~(FZ | FV | FN)) | ((c->a & v) ? 0 : FZ) | (v & 0xC0)); break;
    case O_ASL: case O_LSR: case O_ROL: case O_ROR: {
        v = (mode == M_ACC) ? c->a : RD();
        uint8_t r;
        if (op == O_ASL) { c->p = (uint8_t)((c->p & ~FC) | (v >> 7)); r = (uint8_t)(v << 1); }
        else if (op == O_LSR) { c->p = (uint8_t)((c->p & ~FC) | (v & 1)); r = v >> 1; }
        else if (op == O_ROL) { r = (uint8_t)((v << 1) | (c->p & FC)); c->p = (uint8_t)((c->p & ~FC) | (v >> 7)); }
        else { r = (uint8_t)((v >> 1) | ((c->p & FC) << 7)); c->p = (uint8_t)((c->p & ~FC) | (v & 1)); }
        setzn(c, r);
        if (mode == M_ACC) c->a = r; else cpu_write(n, addr, r);
        break;
    }
    case O_INC: v = (uint8_t)(RD() + 1); cpu_write(n, addr, v); setzn(c, v); break;
    case O_DEC: v = (uint8_t)(RD() - 1); cpu_write(n, addr, v); setzn(c, v); break;
    case O_INX: c->x++; setzn(c, c->x); break;
    case O_INY: c->y++; setzn(c, c->y); break;
    case O_DEX: c->x--; setzn(c, c->x); break;
    case O_DEY: c->y--; setzn(c, c->y); break;
    case O_TAX: c->x = c->a; setzn(c, c->x); break;
    case O_TXA: c->a = c->x; setzn(c, c->a); break;
    case O_TAY: c->y = c->a; setzn(c, c->y); break;
    case O_TYA: c->a = c->y; setzn(c, c->a); break;
    case O_TSX: c->x = c->s; setzn(c, c->x); break;
    case O_TXS: c->s = c->x; break;
    case O_PHA: push(n, c->a); break;
    case O_PHP: push(n, (uint8_t)(c->p | FB | FU)); break;
    case O_PLA: c->a = pop(n); setzn(c, c->a); break;
    case O_PLP: c->p = (uint8_t)((pop(n) & ~FB) | FU); break;
    case O_JMP: c->pc = addr; break;
    case O_JSR: { uint16_t ret = (uint16_t)(c->pc - 1); push(n, (uint8_t)(ret >> 8)); push(n, (uint8_t)ret); c->pc = addr; break; }
    case O_RTS: { uint16_t lo = pop(n), hi = pop(n); c->pc = (uint16_t)(((hi << 8) | lo) + 1); break; }
    case O_RTI: { c->p = (uint8_t)((pop(n) & ~FB) | FU); uint16_t lo = pop(n), hi = pop(n); c->pc = (uint16_t)((hi << 8) | lo); break; }
    case O_BRK: c->pc++; interrupt(n, 0xFFFE, 1); break;
    case O_BPL: BRANCH(!(c->p & FN)); break;
    case O_BMI: BRANCH(c->p & FN); break;
    case O_BVC: BRANCH(!(c->p & FV)); break;
    case O_BVS: BRANCH(c->p & FV); break;
    case O_BCC: BRANCH(!(c->p & FC)); break;
    case O_BCS: BRANCH(c->p & FC); break;
    case O_BNE: BRANCH(!(c->p & FZ)); break;
    case O_BEQ: BRANCH(c->p & FZ); break;
    case O_CLC: c->p &= ~FC; break;
    case O_SEC: c->p |= FC; break;
    case O_CLI: c->p &= ~FI; break;
    case O_SEI: c->p |= FI; break;
    case O_CLV: c->p &= ~FV; break;
    case O_CLD: c->p &= ~FD; break;
    case O_SED: c->p |= FD; break;
    case O_NOP: if (mode != M_IMP && mode != M_ACC) (void)RD(); break;
    case O_KIL: break;
    // unofficial opcodes used by some games
    case O_LAX: c->a = c->x = RD(); setzn(c, c->a); break;
    case O_SAX: cpu_write(n, addr, c->a & c->x); break;
    case O_DCP: v = (uint8_t)(RD() - 1); cpu_write(n, addr, v); op_cmp(c, c->a, v); break;
    case O_ISB: v = (uint8_t)(RD() + 1); cpu_write(n, addr, v); op_adc(c, (uint8_t)~v); break;
    case O_SLO: v = RD(); c->p = (uint8_t)((c->p & ~FC) | (v >> 7)); v <<= 1; cpu_write(n, addr, v); c->a |= v; setzn(c, c->a); break;
    case O_RLA: { v = RD(); uint8_t r = (uint8_t)((v << 1) | (c->p & FC)); c->p = (uint8_t)((c->p & ~FC) | (v >> 7));
        cpu_write(n, addr, r); c->a &= r; setzn(c, c->a); break; }
    case O_SRE: v = RD(); c->p = (uint8_t)((c->p & ~FC) | (v & 1)); v >>= 1; cpu_write(n, addr, v); c->a ^= v; setzn(c, c->a); break;
    case O_RRA: { v = RD(); uint8_t r = (uint8_t)((v >> 1) | ((c->p & FC) << 7)); c->p = (uint8_t)((c->p & ~FC) | (v & 1));
        cpu_write(n, addr, r); op_adc(c, r); break; }
    case O_ANC: c->a &= RD(); setzn(c, c->a); c->p = (uint8_t)((c->p & ~FC) | (c->a >> 7)); break;
    case O_ALR: c->a &= RD(); c->p = (uint8_t)((c->p & ~FC) | (c->a & 1)); c->a >>= 1; setzn(c, c->a); break;
    case O_ARR: c->a &= RD(); c->a = (uint8_t)((c->a >> 1) | ((c->p & FC) << 7)); setzn(c, c->a);
        c->p = (uint8_t)((c->p & ~(FC | FV)) | ((c->a >> 6) & 1) | ((((c->a >> 6) ^ (c->a >> 5)) & 1) ? FV : 0)); break;
    case O_AXS: { v = RD(); uint8_t ax = c->a & c->x; c->p = (uint8_t)((c->p & ~FC) | (ax >= v ? FC : 0)); c->x = (uint8_t)(ax - v); setzn(c, c->x); break; }
    case O_LAS: c->a = c->x = c->s = RD() & c->s; setzn(c, c->a); break;
    default: break; // XAA, AHX, TAS, SHY, SHX: unstable, ignored
    }
#undef BRANCH
#undef RD
    return cycles;
}

// ---------------------------------------------------------------------------
// APU
// ---------------------------------------------------------------------------
static const uint8_t len_table[32] = {10,254,20,2,40,4,80,6,160,8,60,10,14,12,26,14,12,16,24,18,48,20,96,22,192,24,72,26,16,28,32,30};
static const uint8_t duty_table[4][8] = {{0,1,0,0,0,0,0,0},{0,1,1,0,0,0,0,0},{0,1,1,1,1,0,0,0},{1,0,0,1,1,1,1,1}};
static const uint8_t tri_table[32] = {15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
static const uint16_t noise_table[16] = {4,8,16,32,64,96,128,160,202,254,380,508,762,1016,2034,4068};
static const uint16_t dmc_table[16] = {428,380,340,320,286,254,226,214,190,160,142,128,106,84,72,54};

static uint16_t sweep_target(const Pulse* p) {
    uint16_t delta = p->timer_period >> p->sweep_shift;
    if (p->sweep_neg) return (uint16_t)(p->timer_period - delta - (p->ones_complement ? 1 : 0));
    return (uint16_t)(p->timer_period + delta);
}
static int pulse_out(const Pulse* p) {
    if (!p->enabled || p->length == 0 || p->timer_period < 8 || sweep_target(p) > 0x7FF) return 0;
    if (!duty_table[p->duty][p->dutypos]) return 0;
    return p->const_vol ? p->vol : p->env_decay;
}
static void env_clock(int* start, uint8_t* div, uint8_t* decay, uint8_t vol, int loop) {
    if (*start) { *start = 0; *decay = 15; *div = vol; }
    else if (*div == 0) { *div = vol; if (*decay) (*decay)--; else if (loop) *decay = 15; }
    else (*div)--;
}
static void quarter_frame(APU* a) {
    env_clock(&a->p1.env_start, &a->p1.env_div, &a->p1.env_decay, a->p1.vol, a->p1.halt);
    env_clock(&a->p2.env_start, &a->p2.env_div, &a->p2.env_decay, a->p2.vol, a->p2.halt);
    env_clock(&a->noise.env_start, &a->noise.env_div, &a->noise.env_decay, a->noise.vol, a->noise.halt);
    Triangle* t = &a->tri;
    if (t->linear_reload_flag) t->linear = t->linear_reload; else if (t->linear) t->linear--;
    if (!t->control) t->linear_reload_flag = 0;
}
static void sweep_clock(Pulse* p) {
    uint16_t target = sweep_target(p);
    if (p->sweep_div == 0 && p->sweep_en && p->sweep_shift && p->timer_period >= 8 && target <= 0x7FF) p->timer_period = target;
    if (p->sweep_div == 0 || p->sweep_reload) { p->sweep_div = p->sweep_period; p->sweep_reload = 0; }
    else p->sweep_div--;
}
static void half_frame(APU* a) {
    if (a->p1.length && !a->p1.halt) a->p1.length--;
    if (a->p2.length && !a->p2.halt) a->p2.length--;
    if (a->tri.length && !a->tri.control) a->tri.length--;
    if (a->noise.length && !a->noise.halt) a->noise.length--;
    sweep_clock(&a->p1); sweep_clock(&a->p2);
}

static void pulse_write(Pulse* p, int reg, uint8_t v) {
    switch (reg) {
    case 0: p->duty = v >> 6; p->halt = (v >> 5) & 1; p->const_vol = (v >> 4) & 1; p->vol = v & 15; break;
    case 1: p->sweep_en = v >> 7; p->sweep_period = (v >> 4) & 7; p->sweep_neg = (v >> 3) & 1; p->sweep_shift = v & 7; p->sweep_reload = 1; break;
    case 2: p->timer_period = (uint16_t)((p->timer_period & 0x700) | v); break;
    case 3: p->timer_period = (uint16_t)((p->timer_period & 0xFF) | ((v & 7) << 8));
        if (p->enabled) p->length = len_table[v >> 3];
        p->dutypos = 0; p->env_start = 1; break;
    }
}

static void apu_write(NES* n, uint16_t addr, uint8_t v) {
    APU* a = &n->m.apu;
    if (addr <= 0x4003) { pulse_write(&a->p1, addr - 0x4000, v); return; }
    if (addr <= 0x4007) { pulse_write(&a->p2, addr - 0x4004, v); return; }
    switch (addr) {
    case 0x4008: a->tri.control = v >> 7; a->tri.linear_reload = v & 0x7F; break;
    case 0x400A: a->tri.timer_period = (uint16_t)((a->tri.timer_period & 0x700) | v); break;
    case 0x400B: a->tri.timer_period = (uint16_t)((a->tri.timer_period & 0xFF) | ((v & 7) << 8));
        if (a->tri.enabled) a->tri.length = len_table[v >> 3];
        a->tri.linear_reload_flag = 1; break;
    case 0x400C: a->noise.halt = (v >> 5) & 1; a->noise.const_vol = (v >> 4) & 1; a->noise.vol = v & 15; break;
    case 0x400E: a->noise.mode = v >> 7; a->noise.timer_period = noise_table[v & 15]; break;
    case 0x400F: if (a->noise.enabled) a->noise.length = len_table[v >> 3]; a->noise.env_start = 1; break;
    case 0x4010: a->dmc.irq_en = v >> 7; a->dmc.loop = (v >> 6) & 1; a->dmc.rate = dmc_table[v & 15];
        if (!a->dmc.irq_en) { a->dmc.irq_flag = 0; }
        break;
    case 0x4011: a->dmc.output = v & 0x7F; break;
    case 0x4012: a->dmc.sample_addr = (uint16_t)(0xC000 | (v << 6)); break;
    case 0x4013: a->dmc.sample_len = (uint16_t)((v << 4) | 1); break;
    case 0x4015:
        a->p1.enabled = v & 1; if (!a->p1.enabled) a->p1.length = 0;
        a->p2.enabled = (v >> 1) & 1; if (!a->p2.enabled) a->p2.length = 0;
        a->tri.enabled = (v >> 2) & 1; if (!a->tri.enabled) a->tri.length = 0;
        a->noise.enabled = (v >> 3) & 1; if (!a->noise.enabled) a->noise.length = 0;
        a->dmc.irq_flag = 0;
        if (v & 0x10) { if (!a->dmc.bytes_left) { a->dmc.cur_addr = a->dmc.sample_addr; a->dmc.bytes_left = a->dmc.sample_len; } }
        else a->dmc.bytes_left = 0;
        break;
    case 0x4017:
        a->fc_mode = v >> 7; a->fc_irq_inhibit = (v >> 6) & 1;
        if (a->fc_irq_inhibit) a->fc_irq = 0;
        a->fc_cycle = 0;
        if (a->fc_mode) { quarter_frame(a); half_frame(a); }
        break;
    }
}

static uint8_t apu_read_status(NES* n) {
    APU* a = &n->m.apu;
    uint8_t r = (uint8_t)((a->p1.length > 0) | ((a->p2.length > 0) << 1) | ((a->tri.length > 0) << 2) |
                ((a->noise.length > 0) << 3) | ((a->dmc.bytes_left > 0) << 4) | (a->fc_irq << 6) | (a->dmc.irq_flag << 7));
    a->fc_irq = 0;
    return r;
}

static void ring_push(NES* n, float l, float r) {
    if (!n->audio_enabled) return;
    uint32_t w = atomic_load_explicit(&n->ring_w, memory_order_relaxed);
    uint32_t rd = atomic_load_explicit(&n->ring_r, memory_order_acquire);
    if (w - rd >= RING) return; // full: drop
    n->ring[(w % RING) * 2] = l;
    n->ring[(w % RING) * 2 + 1] = r;
    atomic_store_explicit(&n->ring_w, w + 1, memory_order_release);
}

// --- remastered synth helpers ----------------------------------------------
static inline SVFOut svf_run(SVF* f, float x, float cutoff, float q, float sr) {
    float fc = cutoff < sr * 0.45f ? cutoff : sr * 0.45f;
    float g = tanf((float)M_PI * fc / sr), k = 1.0f / q;
    float a1 = 1.0f / (1.0f + g * (g + k)), a2 = g * a1, a3 = g * a2;
    float v3 = x - f->ic2;
    float v1 = a1 * f->ic1 + a2 * v3;
    float v2 = f->ic2 + a2 * f->ic1 + a3 * v3;
    f->ic1 = 2.0f * v1 - f->ic1;
    f->ic2 = 2.0f * v2 - f->ic2;
    SVFOut o = { v2, v1, x - k * v1 - v2 };
    return o;
}
static inline float polyblep(float t, float dt) {
    if (dt <= 0.0f) return 0.0f;
    if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
    if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
    return 0.0f;
}
static inline float osc_saw(float t, float dt) { return 2.0f * t - 1.0f - polyblep(t, dt); }
static inline float osc_pulse(float t, float dt, float duty) {
    float v = t < duty ? 1.0f : -1.0f;
    v += polyblep(t, dt);
    float t2 = t + 1.0f - duty; if (t2 >= 1.0f) t2 -= 1.0f;
    v -= polyblep(t2, dt);
    return v - (2.0f * duty - 1.0f); // remove DC of asymmetric duty
}
static inline float wrap1(float x) { return x - floorf(x); }
static inline float soft_clip(float x) {
    if (x > 3.0f) return 1.0f;
    if (x < -3.0f) return -1.0f;
    return x * (27.0f + x * x) / (27.0f + 9.0f * x * x);
}

static void enh_configure(NES* n) {
    Enh* e = &n->enh;
    double sr = n->sample_rate;
    static const int comb_base[8] = {1116, 1188, 1277, 1356, 1139, 1211, 1300, 1379};
    static const int ap_base[4] = {556, 441, 579, 464};
    for (int i = 0; i < 8; i++) {
        int len = (int)(comb_base[i] * sr / 44100.0);
        e->comb_len[i] = len < ENH_COMB_MAX ? len : ENH_COMB_MAX;
        e->comb_idx[i] = 0; e->comb_filt[i] = 0;
        memset(e->comb[i], 0, sizeof(e->comb[i]));
    }
    for (int i = 0; i < 4; i++) {
        int len = (int)(ap_base[i] * sr / 44100.0);
        e->ap_len[i] = len < ENH_AP_MAX ? len : ENH_AP_MAX;
        e->ap_idx[i] = 0;
        memset(e->ap[i], 0, sizeof(e->ap[i]));
    }
    memset(e->chorus, 0, sizeof(e->chorus));
    e->chorus_w = 0;
    if (!e->rng) e->rng = 0x12345678u;
    e->configured_rate = sr;
}

static inline float chorus_tap(const Enh* e, float delay_samples) {
    float pos = (float)e->chorus_w - delay_samples;
    while (pos < 0) pos += ENH_CHORUS;
    int i0 = (int)pos; float fr = pos - (float)i0;
    float a = e->chorus[i0 % ENH_CHORUS], b = e->chorus[(i0 + 1) % ENH_CHORUS];
    return a + (b - a) * fr;
}

// Builds one stereo sample by reading the live APU registers and playing them with new instruments.
static void enh_sample(NES* n, float* outL, float* outR) {
    Enh* e = &n->enh;
    APU* a = &n->m.apu;
    float sr = (float)n->sample_rate;
    if (e->configured_rate != n->sample_rate) enh_configure(n);
    uint32_t mask = n->chan_mask;
    float width = n->enh_width;
    float L = 0, R = 0;
    const float ka = 1.0f - expf(-1.0f / (0.004f * sr));  // amplitude smoothing (removes envelope zipper)
    const float kf = 1.0f - expf(-1.0f / (0.0015f * sr)); // tiny glide on pitch changes
    static const float duty_tab[4] = {0.125f, 0.25f, 0.5f, 0.75f};

    // --- leads (pulse 1 & 2) ---
    float lead_mono = 0;
    for (int i = 0; i < 2; i++) {
        Pulse* p = i ? &a->p2 : &a->p1;
        EnhVoice* v = &e->p[i];
        int on = (mask & (1u << i)) && p->enabled && p->length > 0 && p->timer_period >= 8 && sweep_target(p) <= 0x7FF;
        float vol = on ? (float)(p->const_vol ? p->vol : p->env_decay) / 15.0f : 0.0f;
        float f = (float)(CPU_HZ / (16.0 * (p->timer_period + 1)));
        if (v->amp_s < 0.002f) v->freq_s = f; else v->freq_s += (f - v->freq_s) * kf;
        v->amp_s += (vol - v->amp_s) * ka;
        if (v->amp_s < 1e-5f && vol == 0.0f) { v->amp_s = 0; continue; }
        float dt = v->freq_s / sr, duty = duty_tab[p->duty & 3];
        float osc, cutoff;
        switch (n->enh_tone) {
        case 0: // clean: band-limited original waveform
            osc = osc_pulse(v->ph[0], dt, duty);
            cutoff = 16000.0f;
            break;
        case 2: { // supersaw
            float dt1 = dt * 1.0059f, dt2 = dt * 0.9942f;
            osc = (osc_saw(v->ph[0], dt) + osc_saw(v->ph[1], dt1) + osc_saw(v->ph[2], dt2)) * 0.36f
                + osc_pulse(v->ph[0], dt, duty) * 0.25f;
            v->ph[1] = wrap1(v->ph[1] + dt1); v->ph[2] = wrap1(v->ph[2] + dt2);
            cutoff = v->freq_s * 10.0f + 1800.0f;
            break;
        }
        default: { // warm analog
            float dt1 = dt * 1.0035f;
            osc = osc_pulse(v->ph[0], dt, duty) * 0.65f + osc_saw(v->ph[1], dt1) * 0.35f;
            v->ph[1] = wrap1(v->ph[1] + dt1);
            cutoff = v->freq_s * 5.0f + 900.0f;
            break;
        }
        }
        v->ph[0] = wrap1(v->ph[0] + dt);
        float s = svf_run(&v->f, osc, cutoff > 12000.0f ? 12000.0f : cutoff, 0.8f, sr).lp;
        s *= v->amp_s * 0.20f;
        float pan = (i ? 0.38f : -0.38f) * width;            // -1..1
        float ang = (pan + 1.0f) * (float)M_PI * 0.25f;
        L += s * cosf(ang) * 1.4142f; R += s * sinf(ang) * 1.4142f;
        lead_mono += s;
    }

    // stereo chorus on the leads
    e->chorus[e->chorus_w] = lead_mono;
    e->lfo += 0.55f / sr; if (e->lfo >= 1.0f) e->lfo -= 1.0f;
    float lfo = sinf(e->lfo * 2.0f * (float)M_PI);
    float base = 0.013f * sr, depth = 0.0025f * sr;
    float chL = chorus_tap(e, base + depth * lfo);
    float chR = chorus_tap(e, base - depth * lfo);
    e->chorus_w = (e->chorus_w + 1) % ENH_CHORUS;
    L += chL * 0.45f * width; R += chR * 0.45f * width;

    // --- bass (triangle) ---
    {
        Triangle* t = &a->tri;
        int on = (mask & 4) && t->enabled && t->length && t->linear && t->timer_period >= 2;
        float f = (float)(CPU_HZ / (32.0 * (t->timer_period + 1)));
        if (e->tri_amp_s < 0.002f) e->tri_freq_s = f; else e->tri_freq_s += (f - e->tri_freq_s) * kf;
        e->tri_amp_s += ((on ? 1.0f : 0.0f) - e->tri_amp_s) * ka;
        if (e->tri_amp_s > 1e-5f) {
            float dt = e->tri_freq_s / sr;
            float ph = e->tri_ph;
            float tri = 4.0f * fabsf(ph - 0.5f) - 1.0f;
            float sine = sinf(ph * 2.0f * (float)M_PI);
            float sub = sinf(e->tri_sub_ph * 2.0f * (float)M_PI);
            float x = sine * 0.7f + tri * 0.3f + sub * 0.45f * n->enh_bass;
            x = soft_clip(x * (1.0f + 0.6f * n->enh_bass)) ;
            float s = x * e->tri_amp_s * 0.30f;
            L += s; R += s;
            e->tri_ph = wrap1(ph + dt);
            e->tri_sub_ph = wrap1(e->tri_sub_ph + dt * 0.5f);
        }
    }

    // --- drums / effects (noise) ---
    {
        Noise* z = &a->noise;
        int on = (mask & 8) && z->enabled && z->length;
        float vol = on ? (float)(z->const_vol ? z->vol : z->env_decay) / 15.0f : 0.0f;
        e->noise_amp_s += (vol - e->noise_amp_s) * (1.0f - expf(-1.0f / (0.0008f * sr)));
        if (e->noise_amp_s > 1e-5f) {
            float rate = (float)(CPU_HZ / (2.0 * (z->timer_period ? z->timer_period : 4)));
            float src;
            if (z->mode) {
                src = (z->lfsr & 1) ? -1.0f : 1.0f; // metallic/tonal mode: keep the console's sequence
            } else {
                e->rng ^= e->rng << 13; e->rng ^= e->rng >> 17; e->rng ^= e->rng << 5;
                src = (float)(e->rng & 0xFFFF) / 32768.0f - 1.0f;
            }
            float lpc = rate * 0.5f; if (lpc < 400.0f) lpc = 400.0f;
            float x = svf_run(&e->nlp, src, lpc, 0.9f, sr).lp;
            x = svf_run(&e->nhp, x, 160.0f, 0.7f, sr).hp;
            float s = x * e->noise_amp_s * 0.20f;
            float pan = 0.15f * width;
            L += s * (1.0f - pan); R += s * (1.0f + pan);
        }
    }

    // --- DPCM samples ---
    if (mask & 16) {
        float d = (float)a->dmc.output / 127.0f;
        float k = expf(-2.0f * (float)M_PI * 20.0f / sr);
        e->dmc_hp = k * (e->dmc_hp + d - e->dmc_prev_in); e->dmc_prev_in = d;
        L += e->dmc_hp * 0.45f; R += e->dmc_hp * 0.45f;
    }

    // --- reverb (Freeverb-style: 4 combs + 2 allpasses per side) ---
    float rv = n->enh_reverb;
    if (rv > 0.001f) {
        float in = (L + R) * 0.5f * 0.03f;
        float room = 0.80f + 0.06f * rv, damp = 0.35f;
        float wl = 0, wr = 0;
        for (int c = 0; c < 8; c++) {
            float o = e->comb[c][e->comb_idx[c]];
            e->comb_filt[c] = o * (1.0f - damp) + e->comb_filt[c] * damp;
            e->comb[c][e->comb_idx[c]] = in + e->comb_filt[c] * room;
            if (++e->comb_idx[c] >= e->comb_len[c]) e->comb_idx[c] = 0;
            if (c < 4) wl += o; else wr += o;
        }
        for (int k2 = 0; k2 < 4; k2++) {
            float* x = k2 < 2 ? &wl : &wr;
            float bo = e->ap[k2][e->ap_idx[k2]];
            float o = -*x + bo;
            e->ap[k2][e->ap_idx[k2]] = *x + bo * 0.5f;
            if (++e->ap_idx[k2] >= e->ap_len[k2]) e->ap_idx[k2] = 0;
            *x = o;
        }
        float wet = rv * 2.2f;
        float mid = (wl + wr) * 0.5f, side = (wl - wr) * 0.5f * (0.5f + width);
        L += (mid + side) * wet; R += (mid - side) * wet;
    }

    // --- DC block + soft limiter ---
    float kdc = 1.0f - 2.0f * (float)M_PI * 10.0f / sr;
    float yl = L - e->dcl_in + kdc * e->dcl_out; e->dcl_in = L; e->dcl_out = yl;
    float yr = R - e->dcr_in + kdc * e->dcr_out; e->dcr_in = R; e->dcr_out = yr;
    // level-matched to the original mix (~same loudness when switching modes)
    *outL = soft_clip(yl * 0.6f) * 0.85f;
    *outR = soft_clip(yr * 0.6f) * 0.85f;
}

static void apu_step(NES* n, int cycles) {
    APU* a = &n->m.apu;
    double cps = CPU_HZ / (n->sample_rate * n->rate_adjust);
    while (cycles-- > 0) {
        a->cycle++;
        // frame counter (in CPU cycles)
        a->fc_cycle++;
        uint32_t fc = a->fc_cycle;
        if (!a->fc_mode) {
            if (fc == 7457) quarter_frame(a);
            else if (fc == 14913) { quarter_frame(a); half_frame(a); }
            else if (fc == 22371) quarter_frame(a);
            else if (fc == 29829) { quarter_frame(a); half_frame(a); if (!a->fc_irq_inhibit) a->fc_irq = 1; }
            else if (fc >= 29830) a->fc_cycle = 0;
        } else {
            if (fc == 7457) quarter_frame(a);
            else if (fc == 14913) { quarter_frame(a); half_frame(a); }
            else if (fc == 22371) quarter_frame(a);
            else if (fc == 37281) { quarter_frame(a); half_frame(a); }
            else if (fc >= 37282) a->fc_cycle = 0;
        }
        // triangle timer: every CPU cycle
        if (a->tri.timer == 0) {
            a->tri.timer = a->tri.timer_period;
            if (a->tri.length && a->tri.linear && a->tri.timer_period >= 2) a->tri.seq = (a->tri.seq + 1) & 31;
        } else a->tri.timer--;
        // other timers: every APU cycle (2 CPU cycles)
        if (a->cycle & 1) {
            Pulse* ps[2] = {&a->p1, &a->p2};
            for (int i = 0; i < 2; i++) {
                if (ps[i]->timer == 0) { ps[i]->timer = ps[i]->timer_period; ps[i]->dutypos = (ps[i]->dutypos + 1) & 7; }
                else ps[i]->timer--;
            }
            if (a->noise.timer == 0) {
                a->noise.timer = a->noise.timer_period;
                uint16_t bit = (uint16_t)((a->noise.lfsr & 1) ^ ((a->noise.lfsr >> (a->noise.mode ? 6 : 1)) & 1));
                a->noise.lfsr = (uint16_t)((a->noise.lfsr >> 1) | (bit << 14));
            } else a->noise.timer--;
        }
        // DMC (rate in CPU cycles)
        DMC* d = &a->dmc;
        if (d->buffer_empty && d->bytes_left) {
            d->buffer = cpu_read(n, d->cur_addr);
            d->buffer_empty = 0;
            d->cur_addr = (uint16_t)(d->cur_addr == 0xFFFF ? 0x8000 : d->cur_addr + 1);
            if (--d->bytes_left == 0) {
                if (d->loop) { d->cur_addr = d->sample_addr; d->bytes_left = d->sample_len; }
                else if (d->irq_en) d->irq_flag = 1;
            }
        }
        if (d->timer == 0) {
            d->timer = d->rate ? d->rate - 1 : 427;
            if (!d->silence) {
                if (d->shift & 1) { if (d->output <= 125) d->output += 2; }
                else { if (d->output >= 2) d->output -= 2; }
            }
            d->shift >>= 1;
            if (--d->bits_left <= 0) {
                d->bits_left = 8;
                if (d->buffer_empty) d->silence = 1;
                else { d->silence = 0; d->shift = d->buffer; d->buffer_empty = 1; }
            }
        } else d->timer--;

        // mix
        uint32_t m = n->chan_mask;
        int p1 = (m & 1) ? pulse_out(&a->p1) : 0;
        int p2 = (m & 2) ? pulse_out(&a->p2) : 0;
        int t = (m & 4) ? tri_table[a->tri.seq] : 0;
        int nz = (m & 8) ? ((a->noise.enabled && a->noise.length && !(a->noise.lfsr & 1)) ? (a->noise.const_vol ? a->noise.vol : a->noise.env_decay) : 0) : 0;
        int dm = (m & 16) ? d->output : 0;
        double pulse = (p1 + p2) ? 95.88 / (8128.0 / (p1 + p2) + 100.0) : 0.0;
        double tnd_in = t / 8227.0 + nz / 12241.0 + dm / 22638.0;
        double tnd = tnd_in > 0 ? 159.79 / (1.0 / tnd_in + 100.0) : 0.0;
        a->acc += pulse + tnd; a->acc_n += 1.0;
        a->frac += 1.0;
        if (a->frac >= cps) {
            a->frac -= cps;
            double s = a->acc / a->acc_n; a->acc = 0; a->acc_n = 0;
            // high-pass 90 Hz, high-pass 440 Hz, low-pass 14 kHz (first order, like the console's output stage)
            double sr = n->sample_rate;
            double k1 = exp(-2.0 * M_PI * 90.0 / sr), k2 = exp(-2.0 * M_PI * 440.0 / sr);
            double lpk = 1.0 - exp(-2.0 * M_PI * 14000.0 / sr);
            double h1 = k1 * (a->hp1_prev_out + s - a->hp1_prev_in); a->hp1_prev_in = s; a->hp1_prev_out = h1;
            double h2 = k2 * (a->hp2_prev_out + h1 - a->hp2_prev_in); a->hp2_prev_in = h1; a->hp2_prev_out = h2;
            a->lp_prev += (h2 - a->lp_prev) * lpk;
            if (n->audio_mode == 1) {
                float l, r;
                enh_sample(n, &l, &r);
                ring_push(n, l, r);
            } else {
                float m = (float)(a->lp_prev * 1.6);
                ring_push(n, m, m);
            }
        }
    }
    n->m.cpu.irq_line = a->fc_irq || a->dmc.irq_flag;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
NES* nes_create(const uint8_t* rom, size_t len, char* err, int errlen) {
    build_tables();
    if (len < 16 || memcmp(rom, "NES\x1A", 4) != 0) { snprintf(err, errlen, "Not an iNES ROM image."); return NULL; }
    int prg_banks = rom[4], chr_banks = rom[5];
    int mapper = (rom[6] >> 4) | (rom[7] & 0xF0);
    if ((rom[7] & 0x0C) == 0x08) mapper = (rom[6] >> 4) | (rom[7] & 0xF0); // NES 2.0, same low mapper bits
    if (mapper != 0 && mapper != 2 && mapper != 3) { snprintf(err, errlen, "Unsupported mapper %d (NROM, UxROM and CNROM games such as Puzznic are supported).", mapper); return NULL; }
    size_t off = 16 + ((rom[6] & 4) ? 512 : 0);
    size_t prg_size = (size_t)prg_banks * 16384;
    if (prg_banks < 1 || (mapper != 2 && prg_banks > 2) || off + prg_size + (size_t)chr_banks * 8192 > len) {
        snprintf(err, errlen, "ROM image is truncated or has an invalid header."); return NULL;
    }
    NES* n = (NES*)calloc(1, sizeof(NES));
    if (!n) { snprintf(err, errlen, "Out of memory."); return NULL; }
    n->prg = (uint8_t*)malloc(prg_size);
    memcpy(n->prg, rom + off, prg_size);
    n->prg_size = prg_size;
    n->mapper = mapper;
    if (chr_banks) {
        n->chr_banks = (size_t)chr_banks;
        n->chr_rom = (uint8_t*)malloc(n->chr_banks * 8192);
        memcpy(n->chr_rom, rom + off + prg_size, n->chr_banks * 8192);
        memcpy(n->chr, n->chr_rom, 8192);
    } else n->chr_ram = 1;
    n->vertical_mirror = rom[6] & 1;
    n->chan_mask = 0x1F;
    n->audio_enabled = 1;
    n->enh_reverb = 0.35f; n->enh_width = 0.7f; n->enh_bass = 0.4f; n->enh_tone = 1;
    n->sample_rate = 48000.0; n->rate_adjust = 1.0;
    float pal[192];
    nes_build_palette(pal, 1.0f, 0.0f, 1.0f, 0.0f, 2.2f);
    nes_set_palette(n, pal);
    nes_reset(n);
    return n;
}

void nes_destroy(NES* n) { if (!n) return; free(n->prg); free(n->chr_rom); free(n); }

void nes_reset(NES* n) {
    Machine* m = &n->m;
    uint8_t keep_buttons[2] = {m->buttons[0], m->buttons[1]};
    memset(m, 0, sizeof(*m));
    m->buttons[0] = keep_buttons[0]; m->buttons[1] = keep_buttons[1];
    m->cpu.s = 0xFD; m->cpu.p = FI | FU;
    m->cpu.pc = rd16(n, 0xFFFC);
    m->apu.noise.lfsr = 1;
    m->apu.dmc.rate = dmc_table[0]; m->apu.dmc.buffer_empty = 1; m->apu.dmc.bits_left = 8;
    m->apu.noise.timer_period = noise_table[0];
    m->ppu.s0_hit_dot = -1;
    m->apu.p1.ones_complement = 1;
}

void nes_set_buttons(NES* n, int port, uint8_t b) {
    if (port < 0 || port > 1) return;
    // the hardware cannot report opposite directions at once; many games misbehave if it does
    if ((b & (NES_BTN_LEFT | NES_BTN_RIGHT)) == (NES_BTN_LEFT | NES_BTN_RIGHT)) b &= (uint8_t)~(NES_BTN_LEFT | NES_BTN_RIGHT);
    if ((b & (NES_BTN_UP | NES_BTN_DOWN)) == (NES_BTN_UP | NES_BTN_DOWN)) b &= (uint8_t)~(NES_BTN_UP | NES_BTN_DOWN);
    n->m.buttons[port] = b;
}
void nes_set_unlimited_sprites(NES* n, int e) { n->unlimited_sprites = e ? 1 : 0; }

void nes_run_frame(NES* n) {
    n->m.ppu.frame_done = 0;
    int guard = 0;
    while (!n->m.ppu.frame_done && guard++ < 200000) {
        int c = cpu_step(n);
        n->m.cpu.cycles += (uint64_t)c;
        ppu_step(n, c * 3);
        apu_step(n, c);
    }
}

const uint32_t* nes_framebuffer(const NES* n) { return n->fb; }
const uint8_t* nes_layer_bg(const NES* n) { return n->layer_bg; }
const uint8_t* nes_layer_spr(const NES* n) { return n->layer_spr; }
const uint8_t* nes_layer_backdrop(const NES* n) { return n->layer_bd; }

void nes_set_sample_rate(NES* n, double r) { if (r > 8000) n->sample_rate = r; }
void nes_set_rate_adjust(NES* n, double ratio) {
    if (ratio < 0.98) ratio = 0.98;
    if (ratio > 1.02) ratio = 1.02;
    n->rate_adjust = ratio;
}
void nes_set_channel_mask(NES* n, uint32_t m) { n->chan_mask = m; }
void nes_set_audio_enabled(NES* n, int e) { n->audio_enabled = e ? 1 : 0; }

int nes_audio_available(NES* n) {
    return (int)(atomic_load_explicit(&n->ring_w, memory_order_acquire) - atomic_load_explicit(&n->ring_r, memory_order_relaxed));
}
int nes_audio_read(NES* n, float* out, int max_frames) {
    uint32_t r = atomic_load_explicit(&n->ring_r, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&n->ring_w, memory_order_acquire);
    int avail = (int)(w - r), cnt = avail < max_frames ? avail : max_frames;
    for (int i = 0; i < cnt; i++) {
        uint32_t idx = (r + (uint32_t)i) % RING;
        out[i * 2] = n->ring[idx * 2];
        out[i * 2 + 1] = n->ring[idx * 2 + 1];
    }
    atomic_store_explicit(&n->ring_r, r + (uint32_t)cnt, memory_order_release);
    return cnt;
}
void nes_set_audio_mode(NES* n, int mode) { n->audio_mode = mode == 1 ? 1 : 0; }
void nes_set_remaster_audio(NES* n, float reverb, float width, float bass, int tone) {
    n->enh_reverb = reverb < 0 ? 0 : (reverb > 1 ? 1 : reverb);
    n->enh_width = width < 0 ? 0 : (width > 1 ? 1 : width);
    n->enh_bass = bass < 0 ? 0 : (bass > 1 ? 1 : bass);
    n->enh_tone = tone < 0 ? 0 : (tone > 2 ? 2 : tone);
}

#define STATE_MAGIC 0x505A4E31u // "PZN1"
size_t nes_state_size(void) { return sizeof(uint32_t) * 2 + sizeof(Machine) + 8192; }
int nes_save_state(const NES* n, void* buf, size_t len) {
    if (len < nes_state_size()) return 0;
    uint8_t* b = (uint8_t*)buf;
    uint32_t hdr[2] = {STATE_MAGIC, (uint32_t)sizeof(Machine)};
    memcpy(b, hdr, sizeof hdr); b += sizeof hdr;
    memcpy(b, &n->m, sizeof(Machine)); b += sizeof(Machine);
    memcpy(b, n->chr, 8192);
    return 1;
}
int nes_load_state(NES* n, const void* buf, size_t len) {
    if (len < nes_state_size()) return 0;
    const uint8_t* b = (const uint8_t*)buf;
    uint32_t hdr[2]; memcpy(hdr, b, sizeof hdr); b += sizeof hdr;
    if (hdr[0] != STATE_MAGIC || hdr[1] != sizeof(Machine)) return 0;
    uint8_t keep[2] = {n->m.buttons[0], n->m.buttons[1]};
    memcpy(&n->m, b, sizeof(Machine)); b += sizeof(Machine);
    if (n->chr_ram) memcpy(n->chr, b, 8192);
    n->m.buttons[0] = keep[0]; n->m.buttons[1] = keep[1];
    return 1;
}
