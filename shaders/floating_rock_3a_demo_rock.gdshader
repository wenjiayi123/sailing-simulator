shader_type spatial;
render_mode depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.42, 0.40, 0.35, 1.0);
uniform vec4 detail_color : source_color = vec4(0.58, 0.55, 0.47, 1.0);
uniform vec4 accent_color : source_color = vec4(0.25, 0.33, 0.22, 1.0);
uniform float strata_scale = 3.2;
uniform float strata_strength = 0.35;
uniform float noise_scale = 0.72;
uniform float crack_strength = 0.18;
uniform float roughness_value = 0.92;
uniform float specular_value = 0.18;
uniform sampler2D side_texture : source_color, repeat_enable;
uniform float side_texture_strength = 0.0;
uniform float side_texture_alpha_boost = 1.0;
uniform float side_texture_detail_mix = 0.72;
uniform vec2 side_texture_uv_scale = vec2(1.0, 1.0);
uniform vec2 side_texture_uv_offset = vec2(0.0, 0.0);
uniform float side_water_flow_speed = 0.0;
uniform float side_water_flow_strength = 0.0;
uniform float side_water_shimmer_strength = 0.0;
uniform float side_water_surface_sheet_strength = 0.0;
uniform float side_water_surface_sheet_coverage = 0.0;
uniform float side_water_horizontal_suppression = 0.58;
uniform float side_water_extension_strength = 0.0;
uniform float side_water_extension_length = 0.24;
uniform float side_water_soft_line_strength = 0.0;
uniform vec4 side_water_flow_tint : source_color = vec4(0.48, 0.82, 1.0, 1.0);
uniform vec4 side_water_line_edge_color : source_color = vec4(0.52, 0.82, 0.94, 1.0);
uniform vec4 side_water_line_core_color : source_color = vec4(0.88, 0.97, 1.0, 1.0);
uniform float side_water_line_core_strength = 0.0;
uniform float side_water_flow_time = 0.0;
uniform float side_water_bend_amount = 1.0;
uniform float side_water_lane_randomness = 1.0;
uniform float side_water_lane_count = 10.0;
uniform float side_water_channel_edge_softness = 0.0;
uniform float side_water_channel_edge_noise = 0.0;
uniform float side_water_channel_rock_fade = 0.0;

varying vec3 world_pos;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = hash13(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);
	float nxy0 = mix(nx00, nx10, f.y);
	float nxy1 = mix(nx01, nx11, f.y);
	return mix(nxy0, nxy1, f.z);
}

float fbm(vec3 p) {
	float value = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 5; i++) {
		value += noise3(p) * amp;
		p *= 2.03;
		amp *= 0.52;
	}
	return value;
}

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
	return coord + warp * clamp(randomness, 0.0, 8.0) * 0.56;
}

float side_water_mask_from_color(vec3 color) {
	float brightness = dot(color, vec3(0.299, 0.587, 0.114));
	float coolness = color.b - color.r;
	float bright_water = smoothstep(0.15, 0.64, brightness);
	float cool_water = smoothstep(-0.36, 0.04, coolness);
	float white_spray = smoothstep(0.72, 0.96, brightness) * smoothstep(-0.08, 0.10, coolness);
	return clamp(max(bright_water * cool_water, white_spray * 0.62), 0.0, 1.0);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float broad = fbm(world_pos * noise_scale);
	float strata = sin(world_pos.y * strata_scale + fbm(world_pos * 0.55) * 3.4) * 0.5 + 0.5;
	float thin_strata = sin(world_pos.y * strata_scale * 3.7 + broad * 5.0) * 0.5 + 0.5;
	float crack_noise = fbm(world_pos * 8.5 + vec3(19.2, 3.1, 8.7));
	float crack = smoothstep(0.74, 0.95, crack_noise) * crack_strength;
	float color_mix = clamp(broad * 0.34 + strata * strata_strength + thin_strata * 0.09, 0.0, 1.0);

	vec3 albedo = mix(base_color.rgb, detail_color.rgb, color_mix);
	albedo = mix(albedo, accent_color.rgb, smoothstep(0.58, 0.96, broad) * 0.18);
	albedo *= 1.0 - crack;

	vec2 side_uv = UV * side_texture_uv_scale + side_texture_uv_offset;
	vec2 flow_coord = vec2(side_uv.x, clamp(UV.y, 0.0, 1.0));
	float flow_y = flow_coord.y;
	float channel_edge_mask = 1.0;
	if (side_water_channel_edge_softness > 0.001) {
		float edge_distance = min(UV.x, 1.0 - UV.x);
		float edge_noise = fbm(vec3(UV.x * 7.0, UV.y * 3.6, world_pos.y * 0.08));
		float ragged_distance = edge_distance + (edge_noise - 0.5) * side_water_channel_edge_noise;
		float soft_edge = smoothstep(0.0, side_water_channel_edge_softness, ragged_distance);
		float edge_guard = smoothstep(0.0, side_water_channel_edge_softness * 0.45, edge_distance);
		channel_edge_mask = clamp(soft_edge * edge_guard, 0.0, 1.0);
		if (channel_edge_mask < 0.025) {
			discard;
		}
	}
	vec4 side_sample = texture(side_texture, side_uv);
	float side_mask = clamp(side_sample.a * side_texture_alpha_boost * side_texture_strength, 0.0, 1.0);
	side_mask *= mix(1.0, channel_edge_mask, clamp(side_water_channel_rock_fade, 0.0, 1.0));
	float side_visibility = smoothstep(0.03, 0.34, side_mask);
	vec3 side_detail_base = mix(albedo, side_sample.rgb, side_texture_detail_mix);
	vec3 surface_before_water = mix(albedo, side_detail_base, side_mask);
	float wet_surface_mask = 0.0;
	if (side_water_flow_strength > 0.001) {
		float anim_time = TIME + side_water_flow_time;
		float lane_count = max(side_water_lane_count, 1.0);
		float lane_coord = random_lane_coord(flow_coord.x, lane_count, side_water_lane_randomness, 17.0);
		float stream_lane = floor(lane_coord);
		float lane_hash = hash21(vec2(stream_lane, 1.0));
		float lane_hash_b = hash21(vec2(stream_lane, 5.0));
		float lane_phase = lane_hash * 1.73;
		float lane_speed = mix(0.62, 1.42, lane_hash_b);
		float t = anim_time * side_water_flow_speed * lane_speed + lane_phase;
		float bend_window = smoothstep(0.04, 0.18, flow_y);
		float natural_bend = sin(flow_y * 5.6 + anim_time * 0.07 + lane_phase * 6.283) * mix(0.004, 0.010, lane_hash_b);
		natural_bend += sin(flow_y * 13.0 - anim_time * 0.05 + lane_hash * 9.7) * mix(0.0015, 0.004, lane_hash);
		natural_bend *= bend_window * clamp(side_water_bend_amount, 0.0, 20.0);
		vec2 bent_side_uv = flow_coord + vec2(natural_bend, 0.0);
		float side_drift = sin(flow_coord.x * 7.0 + anim_time * 0.14 + lane_phase * 6.283) * mix(0.003, 0.012, lane_hash_b);
		side_drift += natural_bend * 0.35;
		vec2 flow_uv = side_uv + vec2(side_drift, -t);
		vec2 flow_uv_fast = side_uv + vec2(side_drift * 1.65, -t * 1.82 - lane_hash_b * 0.43);
		vec3 flow_sample_slow = texture(side_texture, flow_uv).rgb;
		vec3 flow_sample_fast = texture(side_texture, flow_uv_fast).rgb;
		vec3 flow_sample = mix(flow_sample_slow, flow_sample_fast, 0.38);

		float fast_brightness = dot(flow_sample_fast, vec3(0.299, 0.587, 0.114));
		float base_brightness = dot(side_sample.rgb, vec3(0.299, 0.587, 0.114));
		float surface_water_mask = side_water_mask_from_color(surface_before_water);
		float texture_water_mask = side_water_mask_from_color(side_sample.rgb);
		float flow_water_mask = side_water_mask_from_color(flow_sample) * 0.86;
		float flow_fast_water_mask = side_water_mask_from_color(flow_sample_fast);
		float nearby_water_mask = 0.0;
		nearby_water_mask += side_water_mask_from_color(texture(side_texture, side_uv + vec2(0.0, -0.055)).rgb) * 0.35;
		nearby_water_mask += side_water_mask_from_color(texture(side_texture, side_uv + vec2(0.0, -0.120)).rgb) * 0.26;
		nearby_water_mask += side_water_mask_from_color(texture(side_texture, side_uv + vec2(0.0, 0.070)).rgb) * 0.18;
			float blue_white_distribution = clamp(max(max(texture_water_mask, surface_water_mask), nearby_water_mask) * side_visibility, 0.0, 1.0);
			blue_white_distribution = smoothstep(0.05, 0.72, blue_white_distribution) * channel_edge_mask;
			float water_mask = max(max(texture_water_mask, flow_water_mask), blue_white_distribution * 0.94) * side_visibility;
			water_mask *= channel_edge_mask;
			float blue_white_intensity = max(max(texture_water_mask, flow_fast_water_mask), blue_white_distribution);

		float bent_lane_coord = random_lane_coord(bent_side_uv.x, lane_count, side_water_lane_randomness, 31.0);
		float lane_local = fract(bent_lane_coord + lane_hash * 0.27 + sin(flow_y * 2.2 + lane_phase * 6.283) * 0.06);
		float lane_profile = 1.0 - abs(lane_local * 2.0 - 1.0);
		lane_profile = smoothstep(0.14, 1.0, lane_profile);
		float vertical_thread_a = sin(bent_lane_coord * 2.1 + lane_phase * 6.283) * 0.5 + 0.5;
		float vertical_thread_b = sin(bent_lane_coord * 4.3 + lane_hash_b * 6.283) * 0.5 + 0.5;
		float vertical_thread_c = sin(bent_lane_coord * 7.9 + lane_hash * 11.7) * 0.5 + 0.5;
		float thread_mix = vertical_thread_a * 0.50 + vertical_thread_b * 0.32 + vertical_thread_c * 0.18;
		float soft_vertical_line = smoothstep(0.20, 0.84, lane_profile * 0.72 + thread_mix * 0.28);
		float line_core = smoothstep(0.78, 0.99, lane_profile * 0.84 + thread_mix * 0.16);
		line_core *= line_core;
		float continuous_threads = smoothstep(0.34, 0.92, thread_mix * 0.32 + soft_vertical_line * 0.68);
		float lane_strength = mix(0.54, 0.96, lane_hash_b);
		float extension_len = max(side_water_extension_length, 0.001);
		float trail_mask = 0.0;
		trail_mask += side_water_mask_from_color(texture(side_texture, side_uv + vec2(side_drift * 0.40, -extension_len * 0.22)).rgb) * 0.36;
		trail_mask += side_water_mask_from_color(texture(side_texture, side_uv + vec2(side_drift * 0.55, -extension_len * 0.46)).rgb) * 0.28;
		trail_mask += side_water_mask_from_color(texture(side_texture, side_uv + vec2(side_drift * 0.70, -extension_len * 0.72)).rgb) * 0.20;
		trail_mask += side_water_mask_from_color(texture(side_texture, side_uv + vec2(side_drift * 0.85, -extension_len)).rgb) * 0.14;
		trail_mask *= smoothstep(0.08, 0.20, flow_y);
		trail_mask *= side_water_extension_strength * side_visibility * (0.18 + blue_white_distribution * 0.92) * (0.22 + soft_vertical_line * 0.92);

		float surface_sheet_mask = 0.0;
		float surface_sheet_pulse = 0.0;
		if (side_water_surface_sheet_strength > 0.001 && side_water_surface_sheet_coverage > 0.001) {
			float surface_lane_coord = random_lane_coord(bent_side_uv.x, max(lane_count * 0.52, 1.0), side_water_lane_randomness, 43.0);
			float surface_lane_local = fract(surface_lane_coord + lane_hash * 0.41 + sin(flow_y * 1.75 + lane_phase * 6.283) * 0.10);
			float surface_lane = 1.0 - abs(surface_lane_local * 2.0 - 1.0);
			surface_lane = smoothstep(0.22, 0.88, surface_lane);
			float surface_grain = fbm(vec3(flow_coord * vec2(2.8, 6.0), anim_time * side_water_flow_speed * 0.28 + lane_phase));
			float surface_breakup = smoothstep(0.20, 0.92, surface_grain * 0.68 + broad * 0.22 + surface_lane * 0.22);
			float coverage_threshold = mix(0.92, 0.25, clamp(side_water_surface_sheet_coverage, 0.0, 1.0));
			float coverage_gate = smoothstep(coverage_threshold, 1.0, surface_breakup + surface_lane * 0.28 + blue_white_distribution * 0.20);
			float surface_sheet_phase = fract(flow_y * 4.4 - anim_time * side_water_flow_speed * 3.7 * lane_speed + lane_phase * 0.37);
			surface_sheet_pulse = smoothstep(0.02, 0.24, surface_sheet_phase) * (1.0 - smoothstep(0.54, 0.96, surface_sheet_phase));
			float vertical_gate = smoothstep(0.03, 0.16, flow_y);
			surface_sheet_mask = coverage_gate * surface_lane * vertical_gate * side_visibility * channel_edge_mask;
			surface_sheet_mask *= side_water_surface_sheet_strength * (0.30 + surface_sheet_pulse * 0.55 + soft_vertical_line * 0.28);
		}

		float root_flow_gate = smoothstep(0.54, 0.92, flow_y);
		float root_runoff_mask = root_flow_gate * continuous_threads * lane_strength * side_visibility * channel_edge_mask;
		root_runoff_mask *= (0.16 + side_water_surface_sheet_coverage * 0.34 + side_water_extension_strength * 0.28);
		root_runoff_mask *= (0.34 + soft_vertical_line * 0.56 + line_core * 0.24);
		root_runoff_mask = clamp(root_runoff_mask, 0.0, 1.0);

		float extended_water_mask = clamp(max(max(max(water_mask, trail_mask), surface_sheet_mask * 0.78), root_runoff_mask * 0.82), 0.0, 1.0);
		float falling_phase = fract(flow_y * 7.5 - anim_time * side_water_flow_speed * 6.8 * lane_speed + lane_phase);
		float falling_pulse = smoothstep(0.02, 0.22, falling_phase) * (1.0 - smoothstep(0.48, 0.92, falling_phase));
		float distribution_gate = clamp(0.06 + blue_white_distribution * 1.22 + surface_sheet_mask * 0.42, 0.0, 1.35);
		float stream_mask = extended_water_mask * continuous_threads * lane_strength * distribution_gate * (0.20 + blue_white_intensity * 0.86);
		stream_mask = max(stream_mask, surface_sheet_mask * lane_strength * (0.34 + side_water_flow_strength * 0.32));
		stream_mask = max(stream_mask, root_runoff_mask * (0.42 + side_water_flow_strength * 0.36));
		float non_vertical_water = water_mask * (1.0 - continuous_threads);
		float vertical_motion = smoothstep(0.006, 0.14, abs(fast_brightness - base_brightness));
		float moving_glint = stream_mask * max(vertical_motion, falling_pulse * (0.24 + line_core * 0.76));
		moving_glint = max(moving_glint, surface_sheet_mask * surface_sheet_pulse * side_water_shimmer_strength * 0.44);
		wet_surface_mask = clamp(max(extended_water_mask, stream_mask) * (0.35 + side_water_flow_strength * 0.45), 0.0, 1.0);

		vec3 flowed_side = side_sample.rgb;
		vec3 water_line_color = mix(side_water_line_edge_color.rgb, side_water_line_core_color.rgb, line_core);
		float soft_line_blend = (trail_mask + surface_sheet_mask * 0.58 + root_runoff_mask * 0.46) * side_water_soft_line_strength * (0.12 + soft_vertical_line * 0.36 + blue_white_intensity * 0.28);
		float core_line_blend = (trail_mask + root_runoff_mask * 0.34) * line_core * side_water_line_core_strength * (0.58 + blue_white_intensity * 0.52);
		flowed_side = mix(flowed_side, flowed_side * vec3(0.48, 0.58, 0.62), non_vertical_water * side_water_horizontal_suppression);
		flowed_side = mix(flowed_side, flow_sample, stream_mask * side_water_shimmer_strength * (1.20 + blue_white_intensity * 2.20));
		flowed_side = mix(flowed_side, water_line_color, clamp(soft_line_blend + core_line_blend, 0.0, 0.74));
		flowed_side = mix(flowed_side, mix(flowed_side, side_water_flow_tint.rgb, 0.40), clamp(surface_sheet_mask * side_water_flow_strength * 0.72, 0.0, 0.68));
		flowed_side += side_water_flow_tint.rgb * stream_mask * side_water_flow_strength * (0.20 + soft_vertical_line * 0.40 + blue_white_distribution * 0.74);
		flowed_side += side_water_flow_tint.rgb * surface_sheet_mask * side_water_flow_strength * (0.20 + surface_sheet_pulse * 0.42);
		flowed_side += side_water_line_core_color.rgb * moving_glint * side_water_shimmer_strength * (0.24 + line_core * 0.58 + blue_white_intensity * 0.34);
		side_sample.rgb = mix(side_sample.rgb, flowed_side, clamp(extended_water_mask * 1.25, 0.0, 1.0));
	}

	vec3 side_detail = mix(albedo, side_sample.rgb, side_texture_detail_mix);
	albedo = mix(albedo, side_detail, side_mask);

	ALBEDO = albedo;
	ROUGHNESS = mix(roughness_value, 0.34, wet_surface_mask * 0.48);
	SPECULAR = mix(specular_value, max(specular_value, 0.64), wet_surface_mask * 0.62);
	AO = clamp(0.58 + broad * 0.42 - crack * 0.2, 0.0, 1.0);
}
