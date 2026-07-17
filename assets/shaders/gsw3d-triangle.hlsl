// SPDX-License-Identifier: GPL-3.0-only

cbuffer Target : register(b0, space1)
{
    float4 target_size;
};

struct VSInput
{
    [[vk::location(0)]] float4 position : TEXCOORD0;
    [[vk::location(1)]] float4 color_bgra : TEXCOORD1;
};

struct VSOutput
{
    float4 position : SV_POSITION;
    [[vk::location(0)]] float4 color : TEXCOORD0;
};

VSOutput vs_main(VSInput input)
{
    VSOutput output;
    float2 clip_xy = float2(
        input.position.x * (2.0 / target_size.x) - 1.0,
        1.0 - input.position.y * (2.0 / target_size.y)
    );
    output.position = float4(clip_xy, input.position.z, 1.0);
    output.color = input.color_bgra.bgra;
    return output;
}

float4 ps_main(VSOutput input) : SV_TARGET0
{
    return input.color;
}
