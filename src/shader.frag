#version 330 core
in vec2 v_uv;
in vec2 v_st;
in vec4 v_col;
in vec2 v_frag_size_px;
in vec4 v_stroke;
in float v_thickness_px;
in float v_radius_px;
in float v_tex_intensity;
in vec4 v_rim_color;
in float v_rim_thickness_px;

out vec4 frag_color;

uniform int u_mode;

uniform sampler2D u_texture;
uniform sampler2D u_terrain_keys;
uniform sampler2D u_terrain_atlas;

const int MODE_DEFAULT = 0;
const int MODE_TERRAIN = 1;
const int MAX_RIM_THICKNESS_PX = 8;
const float RIM_ALPHA_THRESHOLD = 0.5;

float rounded_box_sdf(vec2 p, vec2 half_size, float radius) {
  vec2 q = abs(p) - half_size + vec2(radius);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

struct RoundedBoxMasks {
	float fill;
	float stroke;
};

RoundedBoxMasks rounded_box_masks(vec2 p, vec2 half_size, float radius, float thickness) {
	float max_radius = min(half_size.x, half_size.y);
	radius = clamp(radius, 0.0, max_radius);
	thickness = clamp(thickness, 0.0, max_radius);

	float outer_sdf = rounded_box_sdf(p, half_size, radius);
	vec2 inner_half_size = max(half_size - vec2(thickness), vec2(0.0));
	float inner_radius = max(radius - thickness, 0.0);
	float inner_sdf = rounded_box_sdf(p, inner_half_size, inner_radius);

	float outer_aa = max(fwidth(outer_sdf), 0.75);
	float inner_aa = max(fwidth(inner_sdf), 0.75);
	float outer_mask = 1.0 - smoothstep(-outer_aa, outer_aa, outer_sdf);
	float inner_mask = 1.0 - smoothstep(-inner_aa, inner_aa, inner_sdf);

	RoundedBoxMasks masks;
	masks.fill = inner_mask;
	masks.stroke = outer_mask * (1.0 - inner_mask);
	return masks;
}

vec4 sprite_rim(vec2 st) {
	if (v_rim_thickness_px <= 0.0 || v_rim_color.a <= 0.0 || v_tex_intensity <= 0.0) {
		return vec4(0.0);
	}

	float center_alpha = texture(u_texture, st).a;
	if (center_alpha >= RIM_ALPHA_THRESHOLD) {
		return vec4(0.0);
	}

	vec2 texel = 1.0 / vec2(textureSize(u_texture, 0));
	float max_alpha = 0.00;
	float rim_radius = min(v_rim_thickness_px, float(MAX_RIM_THICKNESS_PX));
	int rim_radius_i = int(ceil(rim_radius));

	for (int y = -MAX_RIM_THICKNESS_PX; y <= MAX_RIM_THICKNESS_PX; ++y) {
		if (abs(y) > rim_radius_i) {
			continue;
		}

		for (int x = -MAX_RIM_THICKNESS_PX; x <= MAX_RIM_THICKNESS_PX; ++x) {
			if (abs(x) > rim_radius_i) {
				continue;
			}

			vec2 offset = vec2(float(x), float(y));
			float dist = length(offset);
			if (dist > rim_radius) {
				continue;
			}

			float sample_alpha = step(RIM_ALPHA_THRESHOLD, texture(u_texture, st + offset * texel).a);
			float edge_weight = 1.0 - smoothstep(max(rim_radius - 1.0, 0.0), rim_radius, dist);
			max_alpha = max(max_alpha, sample_alpha * edge_weight);
		}
	}

	return vec4(v_rim_color.rgb, v_rim_color.a * max_alpha);
}

vec4 default_mode() {
	vec2 half_size = v_frag_size_px * 0.5;
	vec2 p = (v_uv - 0.5) * v_frag_size_px;
	RoundedBoxMasks masks = rounded_box_masks(p, half_size, v_radius_px, v_thickness_px);

	vec4 tex = texture(u_texture, v_st);
	vec4 fill = mix(v_col, tex * v_col, v_tex_intensity);

	float fill_alpha = fill.a * masks.fill;
	float stroke_alpha = v_stroke.a * masks.stroke;
	float out_alpha = fill_alpha + stroke_alpha * (1.0 - fill_alpha);

	vec3 out_rgb = vec3(0.0);
	if (out_alpha > 0.0) {
		vec3 fill_rgb = fill.rgb * fill_alpha;
		vec3 stroke_rgb = v_stroke.rgb * stroke_alpha * (1.0 - fill_alpha);
		out_rgb = (fill_rgb + stroke_rgb) / out_alpha;
	}

	vec4 col = vec4(out_rgb, out_alpha);
	vec4 rim = sprite_rim(v_st);
	return col + rim * (1.0 - col.a);
}

ivec2 terrain_tile_coord_from_key(ivec2 key_coord, ivec2 key_size, ivec2 atlas_tile_count) {
	ivec2 clamped_key_coord = clamp(key_coord, ivec2(0, 0), key_size - ivec2(1, 1));
	vec4 key = texelFetch(u_terrain_keys, clamped_key_coord, 0);
	ivec2 tile_coord = ivec2(round(key.rg * 255.0));
	return clamp(tile_coord, ivec2(0, 0), atlas_tile_count - ivec2(1, 1));
}

vec4 sample_terrain_tile(ivec2 tile_coord, vec2 tile_st, vec2 atlas_size, vec2 tile_size) {
	vec2 wrapped_st = fract(tile_st);
	vec2 clamped_st = clamp(wrapped_st, 0.0, 1.0);
	vec2 atlas_px = vec2(tile_coord) * tile_size + clamped_st * (tile_size - 1.0) + 0.5;
	return texture(u_terrain_atlas, atlas_px / atlas_size);
}

vec4 terrain_mode() {
	ivec2 key_size = textureSize(u_terrain_keys, 0);
	vec2 atlas_size = vec2(textureSize(u_terrain_atlas, 0));
	vec2 tile_size = vec2(256.0, 256.0);
	ivec2 atlas_tile_count = ivec2(atlas_size / tile_size);

	vec2 key_pos = v_uv * vec2(key_size) - 0.5;
	ivec2 key_base = ivec2(floor(key_pos));
	vec2 key_blend = fract(key_pos);

	vec4 c00 = sample_terrain_tile(terrain_tile_coord_from_key(key_base + ivec2(0, 0), key_size, atlas_tile_count), v_st, atlas_size, tile_size);
	vec4 c10 = sample_terrain_tile(terrain_tile_coord_from_key(key_base + ivec2(1, 0), key_size, atlas_tile_count), v_st, atlas_size, tile_size);
	vec4 c11 = sample_terrain_tile(terrain_tile_coord_from_key(key_base + ivec2(1, 1), key_size, atlas_tile_count), v_st, atlas_size, tile_size);
	vec4 c01 = sample_terrain_tile(terrain_tile_coord_from_key(key_base + ivec2(0, 1), key_size, atlas_tile_count), v_st, atlas_size, tile_size);

	vec4 cx0 = mix(c00, c10, key_blend.x);
	vec4 cx1 = mix(c01, c11, key_blend.x);
	return mix(cx0, cx1, key_blend.y);
}

void main() {
	if (u_mode == MODE_DEFAULT) {
		frag_color = default_mode();
	} else if (u_mode == MODE_TERRAIN) {
		frag_color = terrain_mode();
	} else {
		frag_color = vec4(1, 0, 0, 1);
	}
}
