shader_type spatial;

render_mode unshaded, cull_disabled, blend_mix, depth_prepass_alpha, specular_schlick_ggx;

uniform sampler2D lake_texture : source_color, repeat_enable;
uniform vec4 shallow_tint : source_color = vec4(0.34, 0.88, 0.86, 1.0);
uniform vec4 deep_tint : source_color = vec4(0.02, 0.23, 0.34, 1.0);
uniform vec4 surface_tint : source_color = vec4(0.30, 0.78, 1.0, 1.0);
uniform float texture_scale = 1.0;
uniform vec2 flow_direction = vec2(0.82, 0.34);
uniform float flow_speed = 0.035;
uniform float wave_speed = 0.22;
uniform float directional_wave_frequency = 31.0;
uniform float directional_wave_strength = 0.34;
uniform float distortion_strength = 0.015;
uniform float caustic_strength = 0.34;
uniform float shimmer_strength = 0.26;
uniform float transparent_layer_alpha = 0.44;
uniform float depth_contrast = 0.42;
uniform float normal_strength = 0.62;
uniform float emission_strength = 0.20;
uniform float vertex_wave_height = 0.18;
uniform float vertex_wave_scale = 0.045;

vec2 safe_normalize(vec2 value) {
	float value_length = max(length(value), 0.0001);
	return value / value_length;
}

void vertex() {
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 direction = safe_normalize(flow_direction);
	vec2 cross_direction = vec2(-direction.y, direction.x);
	float time_value = TIME * wave_speed;
	float long_wave = sin(dot(world_position.xz, direction) * vertex_wave_scale + time_value * 6.28318);
	float cross_wave = sin(dot(world_position.xz, cross_direction) * vertex_wave_scale * 0.54 - time_value * 4.2);
	VERTEX.y += (long_wave * 0.68 + cross_wave * 0.32) * vertex_wave_height;
}

void fragment() {
	vec2 uv = UV * texture_scale;
	vec2 direction = safe_normalize(flow_direction);
	vec2 cross_direction = vec2(-direction.y, direction.x);
	float t = TIME * wave_speed;

	float directional_wave = sin(dot(uv, direction) * directional_wave_frequency + t * 7.4);
	float broad_swell = sin(dot(uv, direction) * 9.0 + dot(uv, cross_direction) * 2.4 + t * 2.8);
	float cross_ripple = sin(dot(uv, cross_direction) * 24.0 - t * 5.1);
	vec2 ripple = (cross_direction * directional_wave + direction * cross_ripple * 0.42) * distortion_strength;
	ripple += cross_direction * broad_swell * distortion_strength * 0.52;

	vec2 flow_uv = uv + direction * TIME * flow_speed + ripple;
	vec2 counter_uv = uv - direction * TIME * flow_speed * 0.38 - ripple * 0.58;
	vec3 base_fast = texture(lake_texture, flow_uv).rgb;
	vec3 base_slow = texture(lake_texture, counter_uv).rgb;
	vec3 base = mix(base_fast, base_slow, 0.30);
	float lightness = dot(base, vec3(0.299, 0.587, 0.114));
	float shallow_mask = smoothstep(0.18, 0.82, lightness);
	vec3 water_tint = mix(deep_tint.rgb, shallow_tint.rgb, shallow_mask);

	float caustic_a = sin(dot(uv, direction + cross_direction * 0.54) * 34.0 + TIME * 1.7);
	float caustic_b = sin(dot(uv, direction - cross_direction * 0.72) * 29.0 - TIME * 1.18);
	float caustic = pow(max(caustic_a * caustic_b, 0.0), 2.0);
	float wave_crest = smoothstep(0.72, 0.98, directional_wave * 0.5 + 0.5);
	float shimmer_scan = sin(dot(uv, cross_direction) * 92.0 + TIME * 4.6);
	float shimmer_gate = smoothstep(0.76, 0.99, sin(dot(uv, direction) * 18.0 - TIME * 1.5) * 0.5 + 0.5);
	float shimmer = pow(max(shimmer_scan, 0.0), 12.0) * shimmer_gate;

	float depth_shadow = (1.0 - shallow_mask) * depth_contrast;
	vec3 color = mix(base, base * water_tint, 0.58);
	color += vec3(0.36, 0.92, 0.95) * caustic * caustic_strength;
	color += surface_tint.rgb * wave_crest * directional_wave_strength * (0.45 + shallow_mask * 0.55);
	color += vec3(0.92, 0.98, 1.0) * shimmer * shimmer_strength;
	color -= vec3(0.02, 0.08, 0.10) * depth_shadow;

	ALBEDO = color;
	EMISSION = color * emission_strength;
	ALPHA = clamp(transparent_layer_alpha * (0.56 + wave_crest * 0.26 + caustic * 0.18 + shimmer * 0.18), 0.08, 0.78);
	ROUGHNESS = 0.24;
	SPECULAR = 0.55;
	NORMAL_MAP = normalize(vec3(ripple.x, ripple.y, 1.0));
	NORMAL_MAP_DEPTH = normal_strength;
}
