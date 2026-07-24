shader_type spatial;

render_mode unshaded, cull_disabled, depth_draw_alpha_prepass;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);

	float max_color = max(tex.r, max(tex.g, tex.b));
	float min_color = min(tex.r, min(tex.g, tex.b));
	float saturation = max_color - min_color;

	// 去除接近白色的棋盘格
	bool is_white_square = max_color > 0.92 && saturation < 0.05;

	// 去除接近浅灰色的棋盘格
	bool is_gray_square = (
		max_color > 0.76
		&& max_color < 0.92
		&& saturation < 0.05
	);

	if (is_white_square || is_gray_square) {
		discard;
	}

	ALBEDO = tex.rgb;
	ALPHA = tex.a;
}
