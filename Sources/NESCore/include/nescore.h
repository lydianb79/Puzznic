// NESCore — compact, cycle-counted NES runtime used by the Puzznic Remastered app.
// The original game code runs unchanged; the PPU additionally exports per-pixel
// colour "layers" (background / sprites / backdrop) so the Metal renderer can
// rebuild the picture at any resolution with modern lighting.
#ifndef NESCORE_H
#define NESCORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NES_W 256
#define NES_H 240

// Controller bits (standard NES order)
enum {
    NES_BTN_A      = 1 << 0,
    NES_BTN_B      = 1 << 1,
    NES_BTN_SELECT = 1 << 2,
    NES_BTN_START  = 1 << 3,
    NES_BTN_UP     = 1 << 4,
    NES_BTN_DOWN   = 1 << 5,
    NES_BTN_LEFT   = 1 << 6,
    NES_BTN_RIGHT  = 1 << 7,
};

typedef struct NES NES;

// Creates a machine from an iNES image. Returns NULL and writes a message to err on failure.
NES*  nes_create(const uint8_t* rom, size_t len, char* err, int errlen);
void  nes_destroy(NES* nes);
void  nes_reset(NES* nes);

void  nes_set_buttons(NES* nes, int port, uint8_t buttons);
// Removes the hardware 8-sprites-per-line limit (no flicker). Default off.
void  nes_set_unlimited_sprites(NES* nes, int enabled);

// Runs emulation until the next vertical blank (one video frame).
void  nes_run_frame(NES* nes);

// 256x240 RGBA8 (little-endian 0xAABBGGRR) image of the last frame, original look.
const uint32_t* nes_framebuffer(const NES* nes);
// Per-pixel layers of the last frame (256x240 bytes each).
//  bg:  0 = transparent, otherwise 1 + NES colour (0..63)
//  spr: 0 = transparent, otherwise (1 + NES colour) | 0x80 if sprite is behind background
const uint8_t*  nes_layer_bg(const NES* nes);
const uint8_t*  nes_layer_spr(const NES* nes);
// 240 entries, NES colour of the backdrop on each scanline.
const uint8_t*  nes_layer_backdrop(const NES* nes);

// Audio. Interleaved stereo float32 frames (L, R), produced while frames run.
void  nes_set_sample_rate(NES* nes, double rate);
// Fine rate adjust (1.0 = nominal). Used for dynamic rate control against the audio clock.
void  nes_set_rate_adjust(NES* nes, double ratio);
// Thread-safe single-consumer read into out[2*max_frames]. Returns number of frames written.
int   nes_audio_read(NES* nes, float* out, int max_frames);
int   nes_audio_available(NES* nes); // frames queued
void  nes_set_channel_mask(NES* nes, uint32_t mask); // bit0..4 = pulse1,pulse2,tri,noise,dmc
// When disabled no samples are queued (used while fast-forwarding).
void  nes_set_audio_enabled(NES* nes, int enabled);
// 0 = original 2A03 sound, 1 = "Remastered": the same music re-performed live from the APU
// registers with band-limited instruments, stereo chorus and reverb.
void  nes_set_audio_mode(NES* nes, int mode);
// Remastered parameters: reverb 0..1, stereo width 0..1, bass 0..1, lead tone 0 clean / 1 warm / 2 supersaw.
void  nes_set_remaster_audio(NES* nes, float reverb, float width, float bass, int tone);

// Save states (fixed-size blob).
size_t nes_state_size(void);
int    nes_save_state(const NES* nes, void* buf, size_t len);
int    nes_load_state(NES* nes, const void* buf, size_t len);

// Builds a 64-entry RGB palette (floats 0..1, 3 per entry) using an NTSC model.
// saturation/hue/contrast/brightness: 1,0,1,0 are neutral. gamma typically 2.2.
void  nes_build_palette(float* out192, float saturation, float hueDegrees,
                        float contrast, float brightness, float gamma);
// Swaps the palette used for the classic framebuffer.
void  nes_set_palette(NES* nes, const float* rgb192);

#ifdef __cplusplus
}
#endif
#endif
