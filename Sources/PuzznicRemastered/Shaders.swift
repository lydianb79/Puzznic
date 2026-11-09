// Metal shader source, compiled at launch with MTLDevice.makeLibrary(source:).
// Kept in Swift so the Swift Package builds without an Xcode Metal build step.

enum ShaderSource {
    static let metal = #"""
#include <metal_stdlib>
using namespace metal;

constexpr sampler linClamp(coord::normalized, filter::linear, address::clamp_to_edge);
constexpr sampler mipClamp(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);

constant float2 NES_SIZE = float2(256.0, 240.0);

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fsVert(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float4 hash42(float2 p) {
    float4 p4 = fract(float4(p.xyxy) * float4(0.1031, 0.1030, 0.0973, 0.1099));
    p4 += dot(p4, p4.wzxy + 33.33);
    return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

// ---------------------------------------------------------------------------
// Pass 1: height maps at native resolution (soft "extrusion" of every layer)
//   aux.r = background height, aux.g = sprite height, aux.b = sprite-behind-background flag
// ---------------------------------------------------------------------------
kernel void heightMaps(texture2d<uint, access::read> layers [[texture(0)]],
                       texture2d<half, access::write> aux [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= 256u || gid.y >= 240u) return;
    float hb = 0.0, hs = 0.0, ws = 0.0, behindN = 0.0;
    for (int dy = -3; dy <= 3; dy++) {
        for (int dx = -3; dx <= 3; dx++) {
            int2 t = clamp(int2(gid) + int2(dx, dy), int2(0), int2(255, 239));
            uint2 v = layers.read(uint2(t)).rg;
            float w = exp(-float(dx * dx + dy * dy) * 0.5);
            hb += w * (v.r != 0u ? 1.0 : 0.0);
            hs += w * ((v.g & 0x7Fu) != 0u ? 1.0 : 0.0);
            ws += w;
            if (abs(dx) <= 1 && abs(dy) <= 1 && (v.g & 0x80u) != 0u) behindN = 1.0;
        }
    }
    uint own = layers.read(gid).g;
    float behind = (own & 0x7Fu) != 0u ? ((own & 0x80u) != 0u ? 1.0 : 0.0) : behindN;
    aux.write(half4(half(hb / ws), half(hs / ws), half(behind), 1.0h), gid);
}

// ---------------------------------------------------------------------------
// Pass 2: resolution-independent reconstruction of the pixel art.
// Every output texel looks at the 4x4 surrounding NES pixels, builds a smooth
// coverage field (Gaussian kernel) and thresholds it with anti-aliasing. Colours
// are chosen by sharpened per-colour weights, so edges stay crisp but stair-steps
// become clean diagonals and curves.
// ---------------------------------------------------------------------------
struct UpscaleU { float4 p; }; // x = scale, y = sigma, z = edge softness

static half4 resolveLayer(thread const uint* ids, thread const float* w, constant float4* pal, float edge) {
    float tot = 0.0, op = 0.0;
    for (int j = 0; j < 16; j++) { tot += w[j]; if (ids[j] != 0u) op += w[j]; }
    float f = op / max(tot, 1e-6);
    float cov = smoothstep(0.5 - edge, 0.5 + edge, f);
    if (cov <= 0.0) return half4(0.0h);
    float3 col = float3(0.0);
    float ksum = 0.0;
    for (int j = 0; j < 16; j++) {
        if (ids[j] == 0u) continue;
        float cw = 0.0;
        for (int k = 0; k < 16; k++) if (ids[k] == ids[j]) cw += w[k];
        float k4 = cw * cw; k4 *= k4;
        col += k4 * pal[min(ids[j] - 1u, 63u)].rgb;
        ksum += k4;
    }
    col /= max(ksum, 1e-9);
    return half4(half3(col * cov), half(cov));
}

kernel void upscaleLayers(texture2d<uint, access::read> layers [[texture(0)]],
                          texture2d<half, access::read> aux [[texture(1)]],
                          texture2d<half, access::write> outBG [[texture(2)]],
                          texture2d<half, access::write> outSP [[texture(3)]],
                          texture2d<half, access::write> outAux [[texture(4)]],
                          constant float4* pal [[buffer(0)]],
                          constant UpscaleU& u [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outBG.get_width() || gid.y >= outBG.get_height()) return;
    float S = u.p.x;
    float2 p = (float2(gid) + 0.5) / S;
    float2 fp = p - 0.5;
    int2 base = int2(floor(fp)) - 1;
    float2 t = fp - floor(fp);
    float2 t2 = t * t, t3 = t2 * t;
    // cubic B-spline weights for a C2-smooth height field
    float2 b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float2 b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float2 b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float2 b3 = t3 / 6.0;
    float bx[4] = { b0.x, b1.x, b2.x, b3.x };
    float by[4] = { b0.y, b1.y, b2.y, b3.y };

    float w[16]; uint ib[16]; uint is[16];
    float inv = 1.0 / (2.0 * u.p.y * u.p.y);
    float4 h = float4(0.0);
    for (int j = 0; j < 16; j++) {
        int2 o = int2(j & 3, j >> 2);
        int2 tt = base + o;
        uint2 tc = uint2(clamp(tt, int2(0), int2(255, 239)));
        float2 d = p - (float2(tt) + 0.5);
        w[j] = exp(-dot(d, d) * inv);
        uint2 v = layers.read(tc).rg;
        ib[j] = v.r;
        is[j] = v.g & 0x7Fu;
        h += float4(aux.read(tc)) * (bx[o.x] * by[o.y]);
    }
    outBG.write(resolveLayer(ib, w, pal, u.p.z), gid);
    outSP.write(resolveLayer(is, w, pal, u.p.z), gid);
    outAux.write(half4(h), gid);
}

// ---------------------------------------------------------------------------
// Pass 3: scene (remastered lighting, classic pixels or CRT)
// ---------------------------------------------------------------------------
struct SceneU {
    float4 view;   // xy = target size, z = time, w = mode (0 remastered, 1 classic, 2 crt)
    float4 rect;   // game rectangle in target pixels (x, y, w, h)
    float4 style;  // x = background style, y = border style, z = particles, w = overscan crop lines
    float4 light;  // x = lighting, y = specular, z = shadows, w = rim light
    float4 crt;    // x = scanlines, y = mask, z = curvature, w = sharp pixels
    float4 extra;  // xy = light direction, z = upscale factor, w = unused
};

static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(i), b = hash12(i + float2(1.0, 0.0));
    float c = hash12(i + float2(0.0, 1.0)), d = hash12(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * vnoise(p); p = p * 2.03 + float2(17.1, 9.7); a *= 0.5; }
    return v;
}

// Animated "Aurora" backdrop: deep indigo sky, drifting aurora curtains and rising light motes.
// It only shows where the game draws its backdrop colour (playfield interior, HUD, title screen),
// so blocks and walls keep their original layout.
static float3 backdropColor(float3 base, float2 gp, float t, constant SceneU& u) {
    int style = int(u.style.x + 0.5);
    if (style == 0) return base;
    float2 n = gp / NES_SIZE;
    float3 deep = mix(float3(0.016, 0.008, 0.04), float3(0.002, 0.006, 0.016), float3(n.y));
    float3 col = base * 0.85 + deep;
    if (style == 1) {
        // aurora curtains
        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            float warp = fbm(float2(n.x * 2.2 + t * 0.045 + fk * 3.7, fk * 1.9 + t * 0.02));
            float y0 = 0.18 + 0.24 * fk + 0.07 * sin(n.x * 4.0 + t * 0.23 + fk * 2.1) + 0.16 * (warp - 0.5);
            float dy = n.y - y0;
            float curtain = exp(-dy * dy / (dy < 0.0 ? 0.010 : 0.0025));
            float rays = 0.45 + 0.55 * vnoise(float2(n.x * 48.0 + warp * 6.0 + t * 0.35, fk * 7.0));
            float hueT = saturate(fk * 0.45 + 0.25 * sin(t * 0.11 + n.x * 2.4 + fk));
            float3 tint = mix(float3(0.10, 0.95, 0.70), float3(0.75, 0.22, 1.00), hueT);
            col += tint * curtain * rays * 0.055;
        }
        // faint starfield
        float2 sc = floor(gp / 3.0);
        float sh = hash12(sc + 91.0);
        if (sh > 0.985) {
            float tw = 0.5 + 0.5 * sin(t * (1.5 + sh * 3.0) + sh * 40.0);
            float2 sp = sc * 3.0 + 1.5;
            col += float3(0.6, 0.7, 1.0) * exp(-dot(gp - sp, gp - sp) * 2.0) * tw * 0.12;
        }
        // rising light motes
        float amt = u.style.z;
        if (amt > 0.0) {
            for (int layer = 0; layer < 2; layer++) {
                float cellSz = layer == 0 ? 22.0 : 38.0;
                float speed = layer == 0 ? 6.0 : 11.0;
                float2 q = gp + float2(sin(gp.y * 0.04 + t * 0.7 + float(layer)) * 3.0, t * speed);
                float2 cell = floor(q / cellSz);
                float4 h = hash42(cell + float(layer) * 17.0);
                if (h.x > 0.70) {
                    float r = 0.7 + h.w * (layer == 0 ? 1.0 : 1.8);
                    float2 ctr = cell * cellSz + 4.0 + h.yz * (cellSz - 8.0);
                    float d = length(q - ctr);
                    float core = exp(-d * d / (r * r * 0.35));
                    float halo = exp(-d * d / (r * r * 4.0));
                    float tw = 0.6 + 0.4 * sin(t * (2.0 + h.y * 3.0) + h.z * 30.0);
                    float3 mc = mix(float3(0.45, 1.0, 0.85), float3(1.0, 0.55, 0.95), h.w);
                    col += mc * (core * 0.22 + halo * 0.05) * tw * amt;
                }
            }
        }
    }
    return col;
}

static float3 shadeLayer(float3 col, float2 grad, constant SceneU& u, float3 L, float3 H, float k) {
    float3 n = normalize(float3(-grad * k, 1.0));
    float diff = saturate(dot(n, L));
    float spec = pow(saturate(dot(n, H)), 40.0);
    float rim = 1.0 - n.z;
    float3 lit = col * (0.55 + 0.65 * diff) + spec * 0.55 * u.light.y + col * rim * 0.4 * u.light.w;
    return mix(col, lit, float3(u.light.x));
}

static float3 remaster(float2 gp, constant SceneU& u, constant float4* pal, constant uchar* bd,
                       texture2d<float> upBG, texture2d<float> upSP, texture2d<float> upAux) {
    float t = u.view.z;
    float2 uv = gp / NES_SIZE;
    float4 b = upBG.sample(linClamp, uv);
    float4 s = upSP.sample(linClamp, uv);
    float4 a = upAux.sample(linClamp, uv);
    float3 bgc = b.a > 1e-4 ? b.rgb / b.a : float3(0.0);
    float3 spc = s.a > 1e-4 ? s.rgb / s.a : float3(0.0);

    float e = 1.0 / max(u.extra.z, 1.0);
    float2 ex = float2(e, 0.0) / NES_SIZE, ey = float2(0.0, e) / NES_SIZE;
    float4 ax1 = upAux.sample(linClamp, uv + ex), ax0 = upAux.sample(linClamp, uv - ex);
    float4 ay1 = upAux.sample(linClamp, uv + ey), ay0 = upAux.sample(linClamp, uv - ey);
    float2 gB = float2(ax1.r - ax0.r, ay1.r - ay0.r) / (2.0 * e);
    float2 gS = float2(ax1.g - ax0.g, ay1.g - ay0.g) / (2.0 * e);

    float2 ld = u.extra.xy;
    float3 L = normalize(float3(ld, 0.66));
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));
    float3 bgL = shadeLayer(bgc, gB, u, L, H, 2.2);
    float3 spL = shadeLayer(spc, gS, u, L, H, 2.6);

    int line = clamp(int(gp.y), 0, 239);
    float3 back = backdropColor(pal[bd[line]].rgb, gp, t, u);
    if (u.light.z > 0.0) {
        float shB = upAux.sample(linClamp, uv + ld * 2.2 / NES_SIZE).r;
        float shS = upAux.sample(linClamp, uv + ld * 3.6 / NES_SIZE).g;
        back *= 1.0 - u.light.z * 0.75 * saturate(max(shB, shS) * 1.3);
        bgL *= 1.0 - u.light.z * 0.6 * saturate(shS * 1.3);
    }
    float behind = a.b;
    float3 col = back;
    col = mix(col, spL, float3(s.a * behind));
    col = mix(col, bgL, float3(b.a));
    col = mix(col, spL, float3(s.a * (1.0 - behind)));
    return col;
}

static float3 sampleClassic(texture2d<float> fb, float2 gp, float pxScale, float sharp) {
    float2 tx = gp;
    if (sharp > 0.5) {
        float2 i = floor(tx - 0.5);
        float2 f = saturate((fract(tx - 0.5) - 0.5) * pxScale + 0.5);
        tx = i + 0.5 + f;
    }
    return fb.sample(linClamp, tx / NES_SIZE).rgb;
}

static float3 crtSample(texture2d<float> fb, float2 gp, constant SceneU& u, float2 pix) {
    float fy = fract(gp.y) - 0.5;
    float cy = floor(gp.y) + 0.5;
    float cy2 = cy + (fy > 0.0 ? 1.0 : -1.0);
    float3 c1 = fb.sample(linClamp, float2(gp.x, cy) / NES_SIZE).rgb;
    float3 c2 = fb.sample(linClamp, float2(gp.x, cy2) / NES_SIZE).rgb;
    float3 lw = float3(0.2126, 0.7152, 0.0722);
    float d1 = abs(fy), d2 = 1.0 - abs(fy);
    float s1 = mix(0.22, 0.42, saturate(dot(c1, lw)));
    float s2 = mix(0.22, 0.42, saturate(dot(c2, lw)));
    float w1 = exp(-d1 * d1 / (2.0 * s1 * s1));
    float w2 = exp(-d2 * d2 / (2.0 * s2 * s2));
    float3 beam = c1 * w1 + c2 * w2;
    float3 col = mix(c1, beam * 1.25, float3(u.crt.x));
    int m = int(pix.x) % 3;
    float3 mask = float3(1.0 - u.crt.y * 0.55);
    mask[m] = 1.0;
    return col * mask * (1.0 + u.crt.y * 0.35);
}

fragment float4 sceneFrag(VOut in [[stage_in]],
                          texture2d<float> fb [[texture(0)]],
                          texture2d<float> upBG [[texture(1)]],
                          texture2d<float> upSP [[texture(2)]],
                          texture2d<float> upAux [[texture(3)]],
                          constant SceneU& u [[buffer(0)]],
                          constant float4* pal [[buffer(1)]],
                          constant uchar* bd [[buffer(2)]]) {
    float2 pix = in.pos.xy;
    float2 uvRaw = (pix - u.rect.xy) / u.rect.zw;
    float2 uvG = uvRaw;
    int mode = int(u.view.w + 0.5);
    if (mode == 2 && u.crt.z > 0.0) {
        float2 cc = uvG * 2.0 - 1.0;
        cc *= 1.0 + dot(cc, cc) * u.crt.z * 0.06;
        uvG = cc * 0.5 + 0.5;
    }
    bool inside = all(uvG >= 0.0) && all(uvG <= 1.0);
    if (!inside) {
        if (u.style.y > 0.5) {
            float2 c = clamp(uvRaw, float2(0.0), float2(1.0));
            float d = length((uvRaw - c) * u.rect.zw / u.rect.w);
            float3 amb = fb.sample(mipClamp, c, level(5.0)).rgb;
            return float4(amb * 0.35 * exp(-d * 3.0), 1.0);
        }
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float crop = u.style.w;
    float vis = 240.0 - 2.0 * crop;
    float2 gp = float2(uvG.x * 256.0, crop + uvG.y * vis);
    float pxScale = u.rect.w / vis;
    float3 col;
    if (mode == 1) {
        col = sampleClassic(fb, gp, pxScale, u.crt.w);
    } else if (mode == 2) {
        col = crtSample(fb, gp, u, pix);
        float2 edge = smoothstep(float2(0.0), float2(0.008), uvG) * smoothstep(float2(0.0), float2(0.008), float2(1.0) - uvG);
        col *= edge.x * edge.y;
    } else {
        col = remaster(gp, u, pal, bd, upBG, upSP, upAux);
    }
    return float4(col, 1.0);
}

// ---------------------------------------------------------------------------
// Pass 4: bloom (dual filter: soft-threshold downsample chain + tent upsample)
// ---------------------------------------------------------------------------
static float3 s0(texture2d<float, access::sample> t, float2 uv) {
    return t.sample(linClamp, uv, level(0.0)).rgb;
}

kernel void bloomDown(texture2d<float, access::sample> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float4& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint W = dst.get_width(), H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 uv = (float2(gid) + 0.5) / float2(float(W), float(H));
    float2 ts = 1.0 / float2(float(src.get_width()), float(src.get_height()));
    float3 c = s0(src, uv + ts * float2(-1.0, -1.0))
             + s0(src, uv + ts * float2( 1.0, -1.0))
             + s0(src, uv + ts * float2(-1.0,  1.0))
             + s0(src, uv + ts * float2( 1.0,  1.0));
    c *= 0.25;
    if (p.x >= 0.0) {
        float br = max(c.r, max(c.g, c.b));
        float knee = max(p.y, 1e-3);
        float soft = clamp(br - p.x + knee, 0.0, 2.0 * knee);
        soft = soft * soft / (4.0 * knee + 1e-4);
        float contrib = max(soft, br - p.x) / max(br, 1e-4);
        c *= contrib;
    }
    dst.write(float4(c, 1.0), gid);
}

kernel void bloomUp(texture2d<float, access::sample> low [[texture(0)]],
                    texture2d<float, access::sample> cur [[texture(1)]],
                    texture2d<float, access::write> dst [[texture(2)]],
                    constant float4& p [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    uint W = dst.get_width(), H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 uv = (float2(gid) + 0.5) / float2(float(W), float(H));
    float2 ts = 1.0 / float2(float(low.get_width()), float(low.get_height()));
    float3 s = s0(low, uv + ts * float2(-1.0, -1.0))
             + s0(low, uv + ts * float2( 0.0, -1.0)) * 2.0
             + s0(low, uv + ts * float2( 1.0, -1.0))
             + s0(low, uv + ts * float2(-1.0,  0.0)) * 2.0
             + s0(low, uv) * 4.0
             + s0(low, uv + ts * float2( 1.0,  0.0)) * 2.0
             + s0(low, uv + ts * float2(-1.0,  1.0))
             + s0(low, uv + ts * float2( 0.0,  1.0)) * 2.0
             + s0(low, uv + ts * float2( 1.0,  1.0));
    s /= 16.0;
    dst.write(float4(s0(cur, uv) + s * p.x, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Pass 5: composite to screen
// ---------------------------------------------------------------------------
struct PostU {
    float4 a; // x exposure, y bloom intensity, z vignette, w chromatic aberration
    float4 b; // x grain, y saturation, z contrast, w time
    float4 c; // x tonemap, y bloom enabled
};

static float3 aces(float3 x) {
    const float A = 2.51, B = 0.03, C = 2.43, D = 0.59, E = 0.14;
    return saturate((x * (A * x + B)) / (x * (C * x + D) + E));
}

fragment float4 compositeFrag(VOut in [[stage_in]],
                              texture2d<float> scene [[texture(0)]],
                              texture2d<float> bloom [[texture(1)]],
                              constant PostU& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 d = uv - 0.5;
    float ca = u.a.w * 0.003;
    float3 col;
    if (ca > 0.0) {
        col.r = scene.sample(linClamp, uv - d * ca).r;
        col.g = scene.sample(linClamp, uv).g;
        col.b = scene.sample(linClamp, uv + d * ca).b;
    } else {
        col = scene.sample(linClamp, uv).rgb;
    }
    if (u.c.y > 0.5) col += bloom.sample(linClamp, uv).rgb * u.a.y;
    col *= u.a.x;
    if (u.c.x > 0.5) col = aces(col * 1.1);
    float l = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = max(mix(float3(l), col, float3(u.b.y)), float3(0.0));
    col = max(mix(float3(0.18), col, float3(u.b.z)), float3(0.0));
    col *= 1.0 - u.a.z * 0.35 * dot(d, d) * 2.2;
    if (u.b.x > 0.0) {
        float n = hash12(in.pos.xy + fract(u.b.w * 13.7) * 1000.0) - 0.5;
        col += n * u.b.x * 0.04;
    }
    return float4(max(col, float3(0.0)), 1.0);
}
"""#
}
