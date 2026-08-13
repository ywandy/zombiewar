shader_type canvas_item;
// Electric-glitch effect for the boot emblem, in the spirit of the classic
// Godot glitch shaders (slice displacement + RGB split + static). Driven by an
// `intensity` uniform so code can pulse it on the flicker frames.

// 0 = clean emblem, 1 = full interference. Animated from boot.gd.
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
// How far (in UV) a displaced slice can slide sideways.
uniform float slice_strength : hint_range(0.0, 0.2) = 0.06;
// RGB channel separation, in UV.
uniform float rgb_split : hint_range(0.0, 0.05) = 0.012;
// Density of the horizontal scanline static.
uniform float static_strength : hint_range(0.0, 1.0) = 0.35;

float _rand(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	float t = floor(TIME * 24.0); // steppy time so slices jump, not drift

	// Pick a few horizontal bands and shove them sideways this step.
	float band = floor(uv.y * 24.0);
	float band_rnd = _rand(vec2(band, t));
	// Only some bands glitch, and only when intensity is high enough.
	float active = step(1.0 - intensity * 0.6, band_rnd);
	float shift = (band_rnd - 0.5) * 2.0 * slice_strength * active * intensity;
	uv.x += shift;

	// RGB channel split for the chromatic "electric" edge.
	vec2 dir = vec2(rgb_split * intensity, 0.0);
	float r = texture(TEXTURE, uv + dir).r;
	float g = texture(TEXTURE, uv).g;
	float b = texture(TEXTURE, uv - dir).b;
	float a = texture(TEXTURE, uv).a;
	vec4 col = vec4(r, g, b, a);

	// Scanline static: sparse bright/dark speckle that crawls with time.
	float line = floor(uv.y * 320.0);
	float speck = _rand(vec2(line, t + band));
	float stat = (speck - 0.5) * static_strength * intensity;
	col.rgb += stat;

	// Keep the cut-out alpha intact; only tint the visible emblem.
	col.rgb = clamp(col.rgb, 0.0, 1.0);
	COLOR = col * COLOR;
}
