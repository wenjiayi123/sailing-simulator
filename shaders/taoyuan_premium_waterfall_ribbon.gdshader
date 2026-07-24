shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_prepass_alpha, shadows_disabled;

uniform vec4 water_color : source_color = vec4(0.62, 0.86, 0.96, 1.0);
uniform vec4 foam_color : source_color = vec4(0.94, 0.98, 1.0, 1.0);
uniform vec4 flow_tint : source_color = vec4(0.48, 0.82, 1.0, 1.0);
uniform float alpha = 0.56;
uniform float edge_fade = 0.30;
uniform float flow_speed = 0.145;
uniform float flow_strength = 0.42;
uniform float shimmer_strength = 0.36;
uniform float horizontal_suppression = 0.72;
uniform float emission_strength = 0.05;
uniform float core_strength = 0.16;
uniform float mist_strength = 0.48;
uniform float thread_strength = 0.22;
uniform float pulse_strength = 1.0;
uniform float pulse_speed = 1.0;
uniform float tail_fade_start = 0.66;
uniform float head_fade = 0.035;
uniform float flow_time = 0.0;
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


float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}


float blue_white_intensity_from_color(vec3 color) {
	float brightness = dot(color, vec3(0.299, 0.587, 0.114));
	float coolness = color.b - color.r;
	float bright_blue = smoothstep(0.46, 0.96, brightness) * smoothstep(-0.02, 0.24, coolness);
	float white_foam = smoothstep(0.78, 0.99, brightness) * smoothstep(-0.10, 0.10, coolness);
	return clamp(max(bright_blue, white_foam), 0.0, 1.0);
}


float falling_ribbon_pulse(float y, float anim_time, float speed, float lane_speed, float lane_phase) {
	float broad = fract(y * 5.4 - anim_time * speed * 7.2 * lane_speed + lane_phase);
	float broad_band = smoothstep(0.01, 0.16, broad) * (1.0 - smoothstep(0.30, 0.92, broad));
	float fine = fract(y * 18.0 - anim_time * speed * 16.0 * lane_speed + lane_phase * 1.37);
	float fine_band = smoothstep(0.02, 0.12, fine) * (1.0 - smoothstep(0.20, 0.72, fine));
	return clamp(broad_band * 0.72 + fine_band * 0.36, 0.0, 1.0);
}


float soft_vertical_strand(float x, float center, float width) {
	return 1.0 - smoothstep(0.0, width, abs(x - center));
}


float silky_water_strands(vec2 uv, float anim_time, float speed, float seed) {
	float side_drift = sin(uv.y * 2.1 + anim_time * 0.24 + seed) * 0.018;
	side_drift += sin(uv.y * 8.7 - anim_time * 0.11 + seed * 1.7) * 0.006;
	float x = clamp(uv.x + side_drift, 0.0, 1.0);

	float width_profile = 1.0 - abs(uv.x * 2.0 - 1.0);
	width_profile = smoothstep(0.0, 1.0, width_profile);

	float line_a = soft_vertical_strand(x, 0.22 + sin(seed * 1.3) * 0.025, 0.060);
	float line_b = soft_vertical_strand(x, 0.39 + sin(seed * 2.1) * 0.018, 0.048);
	float line_c = soft_vertical_strand(x, 0.50 + sin(seed * 0.8) * 0.014, 0.075);
	float line_d = soft_vertical_strand(x, 0.64 + sin(seed * 2.7) * 0.020, 0.052);
	float line_e = soft_vertical_strand(x, 0.80 + sin(seed * 1.9) * 0.023, 0.052);
	float strands = clamp(line_a * 0.54 + line_b * 0.68 + line_c * 1.05 + line_d * 0.72 + line_e * 0.50, 0.0, 1.35);

	float falling_wave = sin(uv.y * 34.0 - anim_time * speed * 46.0 + seed * 5.1) * 0.5 + 0.5;
	float long_wave = sin(uv.y * 7.5 - anim_time * speed * 10.0 + seed * 2.4) * 0.5 + 0.5;
	float smooth_fall = smoothstep(0.08, 0.88, falling_wave) * 0.36 + smoothstep(0.18, 0.92, long_wave) * 0.28 + 0.48;
	float center_gain = 0.72 + width_profile * 0.56;
	return clamp(strands * smooth_fall * center_gain, 0.0, 1.45);
}


float silky_pulse_ripples(vec2 uv, float anim_time, float speed, float seed, float strand_mask) {
	float width_profile = 1.0 - abs(uv.x * 2.0 - 1.0);
	width_profile = smoothstep(0.0, 1.0, width_profile);

	float drifted_y = uv.y + sin(uv.x * 5.8 + seed) * 0.018;
	float effective_speed = max(speed, 0.035) * max(pulse_speed, 0.05);
	float broad_wave = sin(drifted_y * 18.0 - anim_time * effective_speed * 42.0 + seed * 3.1) * 0.5 + 0.5;
	float fine_wave = sin(drifted_y * 42.0 - anim_time * effective_speed * 82.0 + seed * 7.4 + uv.x * 2.2) * 0.5 + 0.5;
	float slow_swell = sin(drifted_y * 6.2 - anim_time * effective_speed * 13.0 + seed * 1.8) * 0.5 + 0.5;

	float broad_pulse = smoothstep(0.42, 0.96, broad_wave);
	float fine_pulse = smoothstep(0.62, 0.99, fine_wave);
	float swell = smoothstep(0.18, 0.88, slow_swell);
	float vertical_fade = smoothstep(0.02, 0.14, uv.y) * (1.0 - smoothstep(0.88, 1.0, uv.y));
	float pulse = clamp(broad_pulse * 0.48 + fine_pulse * 0.34 + swell * 0.22, 0.0, 1.0);
	float strand_gate = smoothstep(0.08, 0.95, strand_mask);
	return pulse * strand_gate * (0.58 + width_profile * 0.62) * vertical_fade;
}


vec4 static_water_pattern(vec2 uv) {
	float broad_mist = noise2(uv * vec2(4.0, 12.0) + vec2(0.11, 3.70));
	float fine_mist = noise2(uv * vec2(12.0, 34.0) + vec2(4.20, 1.30));
	float width_profile = 1.0 - abs(uv.x * 2.0 - 1.0);
	width_profile = smoothstep(0.0, 1.0, width_profile);
	float vertical_lane_a = sin(uv.x * 22.0 + broad_mist * 2.4) * 0.5 + 0.5;
	float vertical_lane_b = sin(uv.x * 56.0 + fine_mist * 3.2) * 0.5 + 0.5;
	float vertical_lane_c = sin(uv.x * 118.0 + fine_mist * 4.6) * 0.5 + 0.5;
	float center_core = smoothstep(0.36, 0.98, width_profile);
	float lane = smoothstep(0.26, 0.96, width_profile * 0.58 + (vertical_lane_a * 0.56 + vertical_lane_b * 0.30 + vertical_lane_c * 0.14) * 0.42);
	float lane_core = smoothstep(0.64, 0.98, width_profile * 0.70 + vertical_lane_a * 0.20 + vertical_lane_b * 0.10);
	float foam = lane * thread_strength + smoothstep(0.70, 1.0, fine_mist) * mist_strength + center_core * core_strength + lane_core * core_strength * 0.76;
	foam = clamp(foam, 0.0, 1.0);

	vec3 color = mix(water_color.rgb, foam_color.rgb, foam);
	float coverage = clamp(0.12 + broad_mist * 0.22 + lane * 0.28 + foam * 0.46, 0.0, 0.86);
	return vec4(color, alpha * coverage);
}


void fragment() {
	float anim_time = TIME + flow_time;
	float edge = smoothstep(0.0, edge_fade, UV.x) * smoothstep(0.0, edge_fade, 1.0 - UV.x);
	float head = smoothstep(0.0, head_fade, UV.y);
	float tail = 1.0 - smoothstep(tail_fade_start, 1.0, UV.y);
	edge *= head * tail;

	vec4 base = static_water_pattern(UV);
	float lane_count = max(flow_lane_count, 1.0);
	float lane_coord = random_lane_coord(UV.x, lane_count, flow_lane_randomness, 17.0);
	float stream_lane = floor(lane_coord);
	float lane_hash = hash21(vec2(stream_lane, 1.0));
	float lane_hash_b = hash21(vec2(stream_lane, 5.0));
	float lane_phase = lane_hash * 1.73;
	float lane_speed = mix(0.62, 1.42, lane_hash_b);
	float t = anim_time * flow_speed * lane_speed + lane_phase;
	float bend_window = smoothstep(0.03, 0.16, UV.y) * (1.0 - smoothstep(0.90, 1.02, UV.y));
	float natural_bend = sin(UV.y * 5.8 + anim_time * 0.07 + lane_phase * 6.283) * mix(0.0025, 0.0065, lane_hash_b);
	natural_bend += sin(UV.y * 14.0 - anim_time * 0.05 + lane_hash * 9.7) * mix(0.0010, 0.0028, lane_hash);
	natural_bend *= bend_window * clamp(flow_bend_amount, 0.0, 20.0);
	vec2 bent_uv = UV + vec2(natural_bend, 0.0);
	float side_drift = sin(UV.x * 18.0 + anim_time * 0.16 + lane_phase * 6.283) * mix(0.0012, 0.004, lane_hash_b);
	side_drift += natural_bend * 0.45;
	vec2 flow_uv = UV + vec2(side_drift, -t);
	vec2 flow_uv_fast = UV + vec2(side_drift * 1.65, -t * 1.82 - lane_hash_b * 0.43);
	vec3 flow_sample_slow = static_water_pattern(flow_uv).rgb;
	vec3 flow_sample_fast = static_water_pattern(flow_uv_fast).rgb;
	vec3 flow_sample = mix(flow_sample_slow, flow_sample_fast, 0.38);

	float base_brightness = dot(base.rgb, vec3(0.299, 0.587, 0.114));
	float flow_brightness = dot(flow_sample, vec3(0.299, 0.587, 0.114));
	float fast_brightness = dot(flow_sample_fast, vec3(0.299, 0.587, 0.114));
	float coolness = max(base.b - base.r, flow_sample.b - flow_sample.r);
	float bright_water = smoothstep(0.15, 0.64, max(base_brightness, flow_brightness));
	float cool_water = smoothstep(-0.36, 0.04, coolness);
	float water_mask = bright_water * max(0.9, cool_water);
	float blue_white_intensity = max(blue_white_intensity_from_color(base.rgb), blue_white_intensity_from_color(flow_sample_fast));

	float bent_lane_coord = random_lane_coord(bent_uv.x, lane_count, flow_lane_randomness, 31.0);
	float vertical_thread_a = sin(bent_lane_coord * 1.88 + lane_phase * 6.283) * 0.5 + 0.5;
	float vertical_thread_b = sin(bent_lane_coord * 4.03 + lane_hash_b * 6.283) * 0.5 + 0.5;
	float vertical_thread_c = sin(bent_lane_coord * 7.38 + lane_hash * 11.7) * 0.5 + 0.5;
	float lane_local = fract(bent_lane_coord + lane_hash * 0.27 + sin(UV.y * 4.2 + lane_phase * 6.283) * 0.035);
	float lane_profile = 1.0 - abs(lane_local * 2.0 - 1.0);
	lane_profile = smoothstep(0.0, 1.0, lane_profile);
	float thread_mix = vertical_thread_a * 0.50 + vertical_thread_b * 0.32 + vertical_thread_c * 0.18;
	float soft_vertical_line = smoothstep(0.06, 0.76, lane_profile * 0.66 + thread_mix * 0.34);
	float line_core = smoothstep(0.58, 0.98, lane_profile * 0.78 + thread_mix * 0.22);
	line_core *= line_core;
	float continuous_threads = smoothstep(0.18, 0.80, thread_mix * 0.44 + soft_vertical_line * 0.56);
	float lane_strength = mix(0.70, 1.18, lane_hash_b);
	float falling_phase = fract(UV.y * 7.5 - anim_time * flow_speed * 6.8 * lane_speed + lane_phase);
	float falling_pulse = smoothstep(0.02, 0.22, falling_phase) * (1.0 - smoothstep(0.48, 0.92, falling_phase));
	float ribbon_pulse = falling_ribbon_pulse(UV.y, anim_time, flow_speed, lane_speed, lane_phase);
	float silk_strands = silky_water_strands(bent_uv, anim_time, flow_speed, lane_phase);
	float silk_core = silk_strands * silk_strands;
	float pulse_ripples = silky_pulse_ripples(bent_uv, anim_time, flow_speed, lane_phase, silk_strands) * pulse_strength;
	float stream_mask = water_mask * continuous_threads * lane_strength * (0.28 + blue_white_intensity * 0.72);
	stream_mask = clamp(max(stream_mask, silk_strands * (0.34 + thread_strength * 0.86 + core_strength * 0.76)), 0.0, 1.4);
	stream_mask = clamp(max(stream_mask, pulse_ripples * 0.86), 0.0, 1.5);
	float non_vertical_water = water_mask * (1.0 - continuous_threads);
	float vertical_motion = smoothstep(0.006, 0.14, abs(fast_brightness - base_brightness));
	float moving_glint = stream_mask * max(max(vertical_motion, ribbon_pulse), max(silk_core * 0.68, max(pulse_ripples, falling_pulse * (0.24 + line_core * 0.76))));
	float falling_flow = stream_mask * ribbon_pulse * (0.42 + line_core * 0.68 + blue_white_intensity * 0.42);

	vec3 color = base.rgb;
	vec3 water_line_color = mix(water_color.rgb, foam_color.rgb, line_core);
	vec3 silk_line_color = mix(water_color.rgb, foam_color.rgb, clamp(silk_core * 0.92 + line_core * 0.32, 0.0, 1.0));
	color = mix(color, color * vec3(0.48, 0.58, 0.62), non_vertical_water * horizontal_suppression);
	color = mix(color, flow_sample, stream_mask * shimmer_strength * (1.20 + blue_white_intensity * 2.20));
	color = mix(color, water_line_color, clamp(stream_mask * (0.08 + soft_vertical_line * 0.26 + line_core * 0.36) * (0.42 + blue_white_intensity * 0.72), 0.0, 0.72));
	color = mix(color, silk_line_color, clamp(silk_strands * (0.30 + core_strength * 0.90 + shimmer_strength * 0.20), 0.0, 0.88));
	color = mix(color, foam_color.rgb, clamp(pulse_ripples * (0.30 + core_strength * 0.60), 0.0, 0.78));
	color += flow_tint.rgb * stream_mask * flow_strength * (0.26 + soft_vertical_line * 0.44 + blue_white_intensity * 0.52);
	color += flow_tint.rgb * falling_flow * flow_strength * 0.72;
	color += flow_tint.rgb * silk_strands * flow_strength * (0.28 + core_strength * 0.54);
	color += flow_tint.rgb * pulse_ripples * flow_strength * 0.68;
	color += foam_color.rgb * moving_glint * max(shimmer_strength, 0.34) * (0.46 + line_core * 0.86 + silk_core * 0.74 + pulse_ripples * 0.82 + blue_white_intensity * 0.42);

	ALBEDO = color;
	EMISSION = color * emission_strength + flow_tint.rgb * moving_glint * max(shimmer_strength, 0.34) * (0.10 + silk_core * 0.18 + pulse_ripples * 0.22 + blue_white_intensity * 0.10);
	ALPHA = base.a * edge * clamp(0.82 + silk_strands * 0.32 + pulse_ripples * 0.34 + blue_white_intensity * 0.18 + ribbon_pulse * shimmer_strength * 0.26 + falling_pulse * shimmer_strength * 0.10, 0.0, 1.0);
}
