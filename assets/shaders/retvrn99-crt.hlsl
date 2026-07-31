// SPDX-License-Identifier: GPL-3.0-only
// Adapted from IzarraVM's CRT presentation shader.

cbuffer Constants : register(b0, space3)
{
    float2 source_size;
    float2 output_scale;
    float scaling_filter;
    float style;
    float time_seconds;
    float padding;
};

Texture2D source_texture : register(t0, space2);
SamplerState source_sampler : register(s0, space2);

struct PSInput
{
    float4 color : COLOR0;
    float2 uv : TEXCOORD0;
    float4 position : SV_POSITION;
};

float3 sample_sharp(float2 uv)
{
    float2 prescale = max(floor(output_scale), 1.0);
    float2 texel = uv * source_size;
    float2 whole = floor(texel);
    float2 center_distance = frac(texel) - 0.5;
    float2 region = 0.5 - 0.5 / prescale;
    float2 fraction = (center_distance - clamp(center_distance, -region, region)) * prescale + 0.5;
    return source_texture.Sample(source_sampler, (whole + fraction) / source_size).rgb;
}

float3 sample_scaled(float2 uv)
{
    if (scaling_filter < 0.5)
    {
        return sample_sharp(uv);
    }
    return source_texture.Sample(source_sampler, uv).rgb;
}

float3 glow(float2 uv, float radius)
{
    float3 result = 0.0;
    float2 step_size = radius / source_size;
    [unroll]
    for (int i = 0; i < 8; ++i)
    {
        float angle = (float)i / 8.0 * 6.2832;
        float3 sample_color = sample_scaled(
            uv + float2(cos(angle), sin(angle)) * step_size
        );
        result += max(sample_color - 0.25, 0.0);
    }
    return result / 8.0;
}

float3 shadow_mask(float3 color, float2 fragment, float pitch, float strength)
{
    float low = 1.0 - strength;
    float row = fmod(floor(fragment.y / (pitch * 1.5)), 2.0);
    float stripe = fmod(floor(fragment.x / pitch + row * 1.5), 3.0);
    float3 mask = low;
    if (stripe < 0.5)
    {
        mask.r = 1.0;
    }
    else if (stripe < 1.5)
    {
        mask.g = 1.0;
    }
    else
    {
        mask.b = 1.0;
    }
    float gap = lerp(1.0, low, 0.5);
    float horizontal_gap = step(
        1.0,
        fmod(floor(fragment.y / (pitch * 0.75)), 2.0)
    ) * 0.6;
    return color * mask * lerp(1.0, gap, horizontal_gap);
}

float hash13(float3 value)
{
    float3 q = frac(value * 0.1031);
    q += dot(q, q.zyx + 31.32);
    return frac((q.x + q.y) * q.z);
}

float4 main(PSInput input) : SV_TARGET
{
    if (style < 0.5)
    {
        float3 color = sample_scaled(input.uv);
        return float4(color, 1.0) * input.color;
    }

    bool strong = style > 1.5;
    float scan_depth = strong ? 0.288 : 0.015;
    float beam = strong ? 0.5 : 0.45;
    float mask_strength = strong ? 0.083 : 0.004;
    float bloom = strong ? 0.3 : 0.16;
    float glow_radius = strong ? 2.0 : 1.3;
    float brightness = strong ? 1.15 : 1.06;
    float curvature = strong ? 0.015 : 0.0;

    float2 uv = input.uv;
    float edge = 1.0;
    if (curvature > 0.0)
    {
        float2 centered = input.uv * 2.0 - 1.0;
        float2 offset = centered.yx * centered.yx * curvature;
        float2 warped = (centered + centered * offset) * 0.5 + 0.5;
        float2 distance_to_edge = min(warped, 1.0 - warped);
        float2 antialias_width = fwidth(warped);
        float2 coverage = clamp(distance_to_edge / max(antialias_width, 1e-6), 0.0, 1.0);
        edge = coverage.x * coverage.y;
        uv = clamp(warped, 0.0, 1.0);
    }

    float3 color = sample_scaled(uv);
    float scan_y = frac(uv.y * source_size.y) - 0.5;
    float scanline = exp(-(scan_y * scan_y) / (2.0 * beam * beam));
    color *= lerp(1.0, scanline, scan_depth);
    color += glow(uv, glow_radius) * bloom * float3(1.12, 0.98, 0.86);
    color = shadow_mask(color, input.position.xy, 1.0, mask_strength);
    color *= brightness;
    if (strong)
    {
        float grain = hash13(float3(input.position.xy, time_seconds * 100.0)) - 0.5;
        color += grain * 0.025;
    }
    color = saturate(color * edge);
    return float4(color, 1.0) * input.color;
}
