shader_type spatial;

render_mode unshaded, cull_disabled, depth_prepass_alpha, blend_mix;

uniform sampler2D cliff_texture : source_color, repeat_enable;
uniform vec4 flow_tint : source_color = vec4(0.48, 0.82, 1.0, 1.0);
uniform float flow_speed = 0.145;
uniform float flow_strength = 0.18;
uniform float shimmer_strength = 0.18;
uniform float horizontal_suppression = 0.72;
uniform float flow_bend_amount = 1.0;
uniform float flow_lane_randomness = 1.0;
uniform float flow_lane_count = 34.0;


float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}


float random_lane_coord(float x, float scale, float randomness, float seed) {
	float coord = x * scale;
	float cell = floor(coord);
	float local = fract(coord);
	float eased = local * local * (3.0 - 2.0 * local);
	float left = hash21(vec2(cell, seed)) - 0.5;
	float right = hash21(vec2(cell + 1.0, seed)) - 0.5;
	float warp = mix(left, right, eased);
	return coord + warp * clamp(randomness, 0.0, 8.0) * 0.52;
}


void fragment() {
	vec4 base = texture(cliff_texture, UV);
	if (base.a < 0.02) {
		discard;
	}

	float lane_count = max(flow_lane_count, 1.0);
	float lane_coord = random_lane_coord(UV.x, lane_count, flow_lane_randomness, 17.0);
	float stream_lane = floor(lane_coord);
	float lane_hash = hash21(vec2(stream_lane, 1.0));
	float lane_hash_b = hash21(vec2(stream_lane, 5.0));
	float lane_phase = lane_hash * 1.73;
	float lane_speed = mix(0.62, 1.42, lane_hash_b);
	float t = TIME * flow_speed * lane_speed + lane_phase;
	float bend_window = smoothstep(0.04, 0.18, UV.y) * (1.0 - smoothstep(0.92, 1.06, UV.y));
	float natural_bend = sin(UV.y * 5.8 + TIME * 0.07 + lane_phase * 6.283) * mix(0.0025, 0.0065, lane_hash_b);
	natural_bend += sin(UV.y * 14.0 - TIME * 0.05 + lane_hash * 9.7) * mix(0.0010, 0.0028, lane_hash);
	natural_bend *= bend_window * clamp(flow_bend_amount, 0.0, 20.0);
	vec2 bent_uv = UV + vec2(natural_bend, 0.0);
	float side_drift = sin(UV.x * 18.0 + TIME * 0.16 + lane_phase * 6.283) * mix(0.0012, 0.004, lane_hash_b);
	side_drift += natural_bend * 0.45;
	vec2 flow_uv = UV + vec2(side_drift, -t);
	vec2 flow_uv_fast = UV + vec2(side_drift * 1.65, -t * 1.82 - lane_hash_b * 0.43);
	vec3 flow_sample_slow = texture(cliff_texture, flow_uv).rgb;
	vec3 flow_sample_fast = texture(cliff_texture, flow_uv_fast).rgb;
	vec3 flow_sample = mix(flow_sample_slow, flow_sample_fast, 0.38);

	float base_brightness = dot(base.rgb, vec3(0.299, 0.587, 0.114));
	float flow_brightness = dot(flow_sample, vec3(0.299, 0.587, 0.114));
	float fast_brightness = dot(flow_sample_fast, vec3(0.299, 0.587, 0.114));
	float coolness = max(base.b - base.r, flow_sample.b - flow_sample.r);
	float bright_water = smoothstep(0.15, 0.64, max(base_brightness, flow_brightness));
	float cool_water = smoothstep(-0.36, 0.04, coolness);
	float water_mask = bright_water * max(0.9, cool_water);

	float bent_lane_coord = random_lane_coord(bent_uv.x, lane_count, flow_lane_randomness, 31.0);
	float vertical_thread_a = sin(bent_lane_coord * 1.88 + lane_phase * 6.283) * 0.5 + 0.5;
	float vertical_thread_b = sin(bent_lane_coord * 4.03 + lane_hash_b * 6.283) * 0.5 + 0.5;
	float vertical_thread_c = sin(bent_lane_coord * 7.38 + lane_hash * 11.7) * 0.5 + 0.5;
	float continuous_threads = smoothstep(0.28, 0.82, vertical_thread_a * 0.50 + vertical_thread_b * 0.32 + vertical_thread_c * 0.18);
	float lane_strength = mix(0.70, 1.18, lane_hash_b);
	float stream_mask = water_mask * continuous_threads * lane_strength;
	float non_vertical_water = water_mask * (1.0 - continuous_threads);
	float vertical_motion = smoothstep(0.006, 0.14, abs(fast_brightness - base_brightness));
	float moving_glint = stream_mask * vertical_motion;

	vec3 color = base.rgb;
	color = mix(color, color * vec3(0.48, 0.58, 0.62), non_vertical_water * horizontal_suppression);
	color = mix(color, flow_sample, stream_mask * shimmer_strength * 2.15);
	color += flow_tint.rgb * stream_mask * flow_strength * 1.05;
	color += vec3(0.82, 0.95, 1.0) * moving_glint * shimmer_strength * 0.45;

	ALBEDO = color;
	ALPHA = base.a;
}
