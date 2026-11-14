let worldShader = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 center;      // camera centre in tiles
    float2 viewport;    // drawable size in pixels
    float tilesPerPixel;
    float time;
    float daylight;
};

struct VOut { float4 position [[position]]; };

vertex VOut worldVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VOut o;
    o.position = float4(p * 2 - 1, 0, 1);
    return o;
}

static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3 - 2 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * noise(p);
        p = p * 2.03 + float2(17.1, 9.2);
        a *= 0.5;
    }
    return v;
}

fragment float4 worldFragment(VOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> mask [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    const float2 size = float2(2160, 1080);
    float2 p = u.center + (in.position.xy - u.viewport / 2) * u.tilesPerPixel;
    float lod = max(0.0, log2(u.tilesPerPixel));

    // Break up the tile grid so the coast reads as a natural shoreline.
    float2 warp = (float2(fbm(p * 0.45), fbm(p * 0.45 + 31.7)) - 0.5) * 1.5;
    float2 uv = (p + warp) / size;
    float2 e = 0.75 / size;
    float2 sum = 0;
    sum += mask.sample(s, uv + float2( e.x,  e.y), level(lod)).rg;
    sum += mask.sample(s, uv + float2(-e.x,  e.y), level(lod)).rg;
    sum += mask.sample(s, uv + float2( e.x, -e.y), level(lod)).rg;
    sum += mask.sample(s, uv + float2(-e.x, -e.y), level(lod)).rg;
    float m = sum.r / 4, rough = sum.g / 4;

    float aa = max(u.tilesPerPixel * 0.9, 0.05);
    float land = smoothstep(0.5 - aa, 0.5 + aa, m);
    float nearCoast = mask.sample(s, uv, level(4.0)).r;
    float broadCoast = mask.sample(s, uv, level(6.0)).r;
    float lat = abs(p.y / size.y - 0.5) * 2;

    // Sea
    float depth = saturate(nearCoast * 1.5 + broadCoast * 0.8);
    float3 sea = mix(float3(0.035, 0.145, 0.30), float3(0.06, 0.36, 0.50), depth);
    sea = mix(sea, float3(0.13, 0.56, 0.60), smoothstep(0.32, 0.5, m) * 0.55);
    sea = mix(sea, sea * float3(0.82, 0.92, 1.05), smoothstep(0.55, 0.95, lat));
    float t = u.time;
    float swell = fbm(p * 0.32 + float2(t * 0.09, t * 0.05));
    float chop = fbm(p * 1.5 + float2(-t * 0.28, t * 0.20));
    float ripple = sin((p.x + p.y * 0.6) * 1.3 + chop * 7 + t * 1.1);
    float detail = saturate(1.6 - u.tilesPerPixel * 2.5);
    sea *= 1 + (swell - 0.5) * 0.22 * detail;
    sea += float3(0.40, 0.55, 0.62) * smoothstep(0.86, 1.0, ripple * chop * 1.75) * 0.2 * detail;

    float foamWave = sin(m * 30 - t * 1.4 + swell * 11) * 0.5 + 0.5;
    float foam = smoothstep(0.30, 0.47, m) * (1 - smoothstep(0.47, 0.52, m)) * foamWave;
    sea = mix(sea, float3(0.86, 0.94, 0.95), foam * 0.62 * detail);

    // Land
    float zoomDetail = saturate(1.15 - u.tilesPerPixel * 2.2);
    float grain = fbm(p * 0.035 + 3.1);
    float fine = mix(0.5, fbm(p * 0.8), zoomDetail);
    float3 temperate = mix(float3(0.27, 0.40, 0.21), float3(0.36, 0.45, 0.25), grain);
    float3 tropic = mix(float3(0.15, 0.36, 0.18), float3(0.22, 0.42, 0.20), grain);
    float3 arid = mix(float3(0.71, 0.61, 0.40), float3(0.62, 0.49, 0.31), grain);
    float3 tundra = mix(float3(0.50, 0.53, 0.47), float3(0.68, 0.70, 0.66), grain);
    float3 ice = float3(0.90, 0.94, 0.97);
    float3 ground = mix(tropic, temperate, smoothstep(0.17, 0.30, lat));
    float dry = smoothstep(0.50, 0.72, grain + (1 - abs(lat - 0.36) * 5.5) * 0.26);
    ground = mix(ground, arid, dry * smoothstep(0.12, 0.2, lat) * (1 - smoothstep(0.56, 0.66, lat)));
    ground = mix(ground, tundra, smoothstep(0.60, 0.74, lat + (grain - 0.5) * 0.12));
    ground = mix(ground, ice, smoothstep(0.82, 0.92, lat + (grain - 0.5) * 0.12));
    ground = mix(ground, float3(0.50, 0.45, 0.40), smoothstep(0.06, 0.30, rough));
    ground = mix(float3(0.82, 0.74, 0.54), ground, smoothstep(0.54, 0.70, m));

    float hillshade = (fbm(p * 0.22 + float2(0.7, 0.7)) - fbm(p * 0.22)) * (0.9 + rough * 2.0) * zoomDetail;
    ground *= 0.98 + clamp(hillshade, -0.16, 0.16) + (fine - 0.5) * 0.12;

    float3 color = mix(sea, ground, land);
    color *= 1 - smoothstep(0.42, 0.72, fbm(p * 0.035 + float2(t * 0.018, 3))) * 0.13;   // cloud shade

    float2 c = in.position.xy / u.viewport - 0.5;
    color *= 1 - dot(c, c) * 0.42;
    color = mix(color * float3(0.32, 0.38, 0.62), color, u.daylight);
    return float4(color, 1);
}
""";

/// The original sea view (docs/re/seamap.md): every world tile is one of 128 16×16 chips, coloured
/// by the 16-colour palette of the time of day. No water animation, as in the original.
let classicShader = """
#include <metal_stdlib>
using namespace metal;

struct ClassicUniforms {
    float2 center;
    float2 viewport;
    float tilesPerPixel;
    float pad0, pad1, pad2;
    float4 palette[16];
};

struct VOut { float4 position [[position]]; };

vertex VOut classicVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VOut o;
    o.position = float4(p * 2 - 1, 0, 1);
    return o;
}

fragment float4 classicFragment(VOut in [[stage_in]],
                                constant ClassicUniforms &u [[buffer(0)]],
                                texture2d<uint> chips [[texture(0)]],
                                texture2d<uint> atlas [[texture(1)]]) {
    float2 p = u.center + (in.position.xy - u.viewport / 2) * u.tilesPerPixel;
    if (p.y < 0 || p.y >= 1080) return float4(0, 0, 0, 1);
    float x = p.x - floor(p.x / 2160) * 2160;
    uint2 tile = uint2(min(x, 2159.0), p.y);
    uint chip = chips.read(tile).r & 127;
    uint2 local = uint2(fract(float2(x, p.y)) * 16);
    uint index = atlas.read(uint2(local.x, chip * 16 + local.y)).r & 15;
    return float4(u.palette[index].rgb, 1);
}
""";
