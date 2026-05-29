#version 330 core
layout (location = 0) in vec2 a_xy;
layout (location = 1) in vec2 a_uv;
layout (location = 2) in vec2 a_st;
layout (location = 3) in vec4 a_col;
layout (location = 4) in vec2 a_frag_size_px;
layout (location = 5) in vec4 a_stroke;
layout (location = 6) in float a_thickness_px;
layout (location = 7) in float a_radius_px;
layout (location = 8) in float a_tex_intensity;
layout (location = 9) in vec4 a_rim_color;
layout (location = 10) in float a_rim_thickness_px;

out vec2 v_uv;
out vec2 v_st;
out vec4 v_col;
out vec2 v_frag_size_px;
out vec4 v_stroke;
out float v_thickness_px;
out float v_radius_px;
out float v_tex_intensity;
out vec4 v_rim_color;
out float v_rim_thickness_px;

void main() {
	gl_Position = vec4(a_xy, 0.0, 1.0);
	v_uv = a_uv;
	v_st = a_st;
	v_col = a_col;
	v_frag_size_px = a_frag_size_px;
	v_stroke = a_stroke;
	v_thickness_px = a_thickness_px;
	v_radius_px = a_radius_px;
	v_tex_intensity = a_tex_intensity;
	v_rim_color = a_rim_color;
	v_rim_thickness_px = a_rim_thickness_px;
}
