shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_prepass_alpha;

uniform vec4 foam_color : source_color = vec4(0.92, 0.98, 1.0, 0.82);
uniform float alpha = 1.0;
uniform float seed = 0.0;

float hash(vec2 value) {
	return fract(sin(dot(value, vec2(127.1, 311.7)) + seed * 19.19) * 43758.5453123);
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float length_fade = 1.0 - smoothstep(0.18, 1.0, abs(centered_uv.y));
	float tapered_width = mix(0.22, 0.58, 1.0 - abs(centered_uv.y));
	float soft_edge = 1.0 - smoothstep(tapered_width, tapered_width + 0.22, abs(centered_uv.x));
	float foam_cells = hash(floor(UV * vec2(18.0, 34.0)));
	float broken_foam = mix(0.42, 1.0, smoothstep(0.24, 0.95, foam_cells));
	float center_streak = 1.0 - smoothstep(0.0, 0.44, abs(centered_uv.x));
	float streak_noise = hash(floor(vec2(UV.x * 6.0, UV.y * 44.0)));
	float mask = clamp((soft_edge * length_fade * broken_foam) + (center_streak * length_fade * streak_noise * 0.34), 0.0, 1.0);

	ALBEDO = foam_color.rgb;
	ALPHA = foam_color.a * alpha * mask;
}
