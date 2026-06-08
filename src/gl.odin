package main

import c "core:c"
import encoding_csv "core:encoding/csv"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import opengl "vendor:OpenGL"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"

DEFAULT_SCRATCH_ARENA_CAPACITY :: mem.Megabyte
NUM_SCRATCH_ARENAS :: 2
DEFAULT_MAX_GL_QUADS :: 1024
VERTEX_SHADER_PATH :: "src/shader.vert"
FRAGMENT_SHADER_PATH :: "src/shader.frag"

Rect :: struct {
	x, y, w, h: f32,
}

Color :: struct {
	r, g, b, a: f32,
}

Color_Rect :: struct {
	corners: [4]Color,
}

WHITE :: Color{1, 1, 1, 1}
BLACK :: Color{0, 0, 0, 1}
RED :: Color{1, 0, 0, 1}
GREEN :: Color{0, 1, 0, 1}
BLUE :: Color{0, 0, 1, 1}
YELLOW :: Color{1, 1, 0, 1}
TRANSPARENT :: Color{0, 0, 0, 0}

rect_corner :: proc(rect: Rect) -> [2]f32 {
	return {rect.x, rect.y}
}

rect_size :: proc(rect: Rect) -> [2]f32 {
	return {rect.w, rect.h}
}

rect_from_pos_and_size :: proc(pos: [2]f32, size: [2]f32) -> Rect {
	return {pos.x, pos.y, size.x, size.y}
}

color_rect_uniform :: proc(color: Color) -> Color_Rect {
	return Color_Rect{corners = [4]Color{color, color, color, color}}
}

append_or_panic :: proc(array: ^[dynamic]$T, values: ..T) {
	_ = append(array, ..values) or_else panic("out of memory")
}

@(private = "file")
read_entire_text :: proc(path: string, allocator: mem.Allocator) -> (string, bool) {
	bytes, err := os.read_entire_file(path, allocator)
	if err != nil {
		fmt.eprintf("failed to read %s: %v\n", path, err)
		return "", false
	}
	return string(bytes), true
}

@(private = "file")
parse_f32_or_zero :: proc(text: string) -> f32 {
	value, ok := strconv.parse_f32(text)
	if !ok {
		return 0
	}
	return value
}

@(private = "file")
parse_u8_or_zero :: proc(text: string) -> u8 {
	value, ok := strconv.parse_int(text)
	if !ok || value < 0 || value > 255 {
		return 0
	}
	return u8(value)
}

load_csv_records :: proc(path: string, allocator: mem.Allocator) -> ([][]string, bool) {
	text, ok := read_entire_text(path, allocator)
	if !ok {
		return nil, false
	}

	reader: encoding_csv.Reader
	encoding_csv.reader_init_with_string(&reader, text, allocator)
	defer encoding_csv.reader_destroy(&reader)
	reader.fields_per_record = -1

	records, err := encoding_csv.read_all(&reader, allocator)
	if err != nil {
		fmt.eprintf("failed to parse csv %s: %v\n", path, err)
		return nil, false
	}

	for i := 0; i < len(records); i += 1 {
		for len(records[i]) > 0 && records[i][len(records[i]) - 1] == "" {
			records[i] = records[i][:len(records[i]) - 1]
		}
	}

	return records, true
}

@(private = "file")
APP_Image :: struct {
	pixels:     []u8,
	width:      int,
	height:     int,
	stb_pixels: rawptr,
}

@(private = "file")
Named_Image :: struct {
	name:  string,
	image: APP_Image,
}

@(private = "file")
APP_Image_Atlas :: struct {
	image:         APP_Image,
	region_names:  []string,
	region_bounds: []Rect,
}

@(private = "file")
app_image_empty :: proc(allocator: mem.Allocator, width, height: int) -> APP_Image {
	pixels, err := make([]u8, width * height * 4, allocator)
	if err != nil {
		panic("failed to allocate image pixels")
	}

	return APP_Image{pixels = pixels, width = width, height = height}
}

@(private = "file")
app_image_load_from_file :: proc(path: string) -> APP_Image {
	scratch := get_scratch()
	defer release_scratch(scratch)

	bytes, err := os.read_entire_file(path, scratch.arena)
	if err != nil {
		fmt.eprintf("failed to load image %s: %v\n", path, err)
		return {}
	}

	width, height, channels: c.int
	_ = channels
	pixels := stbi.load_from_memory(
		raw_data(bytes),
		c.int(len(bytes)),
		&width,
		&height,
		&channels,
		4,
	)
	if pixels == nil {
		fmt.eprintf("failed to decode image %s: %s\n", path, string(stbi.failure_reason()))
		return {}
	}

	pixel_count := int(width) * int(height) * 4

	return APP_Image {
		pixels = ([^]u8)(pixels)[:pixel_count],
		width = int(width),
		height = int(height),
		stb_pixels = rawptr(pixels),
	}
}

@(private = "file")
app_image_destroy :: proc(image: APP_Image) {
	if image.stb_pixels != nil {
		stbi.image_free(image.stb_pixels)
	}
}

@(private = "file")
app_image_atlas_make :: proc(
	allocator: mem.Allocator,
	images: []Named_Image,
	padding: int,
) -> APP_Image_Atlas {
	region_names, err := make([]string, len(images), allocator)
	if err != nil {
		panic("failed to allocate atlas names")
	}

	region_bounds, bounds_err := make([]Rect, len(images), allocator)
	if bounds_err != nil {
		panic("failed to allocate atlas bounds")
	}

	max_width := 0
	total_area := 0
	for image_data in images {
		max_width = max(max_width, image_data.image.width)
		if image_data.image.width > 0 && image_data.image.height > 0 {
			total_area += (image_data.image.width + padding) * (image_data.image.height + padding)
		}
	}

	atlas_width := 1
	for atlas_width < max_width {
		atlas_width *= 2
	}
	for atlas_width * atlas_width < total_area {
		atlas_width *= 2
	}

	x := 0
	y := 0
	row_height := 0
	atlas_height := 0

	for image_data, idx in images {
		region_names[idx] = image_data.name
		image := image_data.image
		if image.width == 0 || image.height == 0 {
			continue
		}

		if x > 0 && x + image.width > atlas_width {
			x = 0
			y += row_height + padding
			row_height = 0
		}

		region_bounds[idx] = Rect {
			x = f32(x),
			y = f32(y),
			w = f32(image.width),
			h = f32(image.height),
		}

		x += image.width + padding
		row_height = max(row_height, image.height)
		atlas_height = max(atlas_height, y + image.height)
	}

	atlas := app_image_empty(allocator, atlas_width, atlas_height)
	for image_data, idx in images {
		image := image_data.image
		bounds := region_bounds[idx]
		if image.width == 0 || image.height == 0 {
			continue
		}

		for src_y := 0; src_y < image.height; src_y += 1 {
			src_start := src_y * image.width * 4
			dst_start := ((int(bounds.y) + src_y) * atlas.width + int(bounds.x)) * 4
			copy(
				atlas.pixels[dst_start:][:image.width * 4],
				image.pixels[src_start:][:image.width * 4],
			)
		}
	}

	return APP_Image_Atlas {
		image = atlas,
		region_names = region_names,
		region_bounds = region_bounds,
	}
}

Texture :: struct {
	handle: u32,
	size:   [2]f32,
}

Texture_Filter :: enum {
	Linear,
	Neighbour,
}

@(private = "file")
Sprite :: struct {
	name:    string,
	texture: Texture,
	bounds:  Rect,
}

@(private = "file")
Vertex :: struct {
	xy:               [2]f32,
	uv:               [2]f32,
	st:               [2]f32,
	col:              Color,
	frag_size_px:     [2]f32,
	stroke:           Color,
	thickness_px:     f32,
	radius_px:        f32,
	tex_intensity:    f32,
	rim_color:        Color,
	rim_thickness_px: f32,
}

@(private = "file")
Quad :: struct {
	bounds:        Rect,
	clip:          Rect,
	st_bounds:     Rect,
	fill:          Color_Rect,
	texture:       Texture,
	tex_intensity: f32,
	stroke:        Color_Rect,
	radius_px:     f32,
	thickness_px:  f32,
}

@(private = "file")
Quad_Batch :: struct {
	quads: []Quad,
}

@(private = "file")
Font_Data :: struct {
	chars:        [96]stbtt.bakedchar,
	texture:      Texture,
	min_glyph:    u16,
	num_glyphs:   u16,
	pixel_height: f32,
}

@(private = "file")
State :: struct {
	allocator:       mem.Allocator,
	program:         u32,
	vao:             u32,
	vbo:             u32,
	ebo:             u32,
	default_texture: Texture,
	font:            Font_Data,
	terrain_keys:    Texture,
	terrain_atlas:   Texture,
	sprites:         [dynamic]Sprite,
}

GL: State

@(private = "file")
Shader_Mode :: enum i32 {
	Default = 0,
	Terrain = 1,
}

Text_Measurement :: struct {
	size:          [2]f32,
	bounds_offset: [2]f32,
	baseline_y:    f32,
}

@(private = "file")
Displayable_Text_Line :: struct {
	text:    string,
	measure: Text_Measurement,
}

@(private = "file")
Displayable_Text :: struct {
	lines:       []Displayable_Text_Line,
	measurement: Text_Measurement,
	line_height: f32,
}

QUAD_UV := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}

@(private = "file")
screen_to_ndc :: proc(bounds: Rect, fb_size: [2]f32) -> Rect {
	if fb_size[0] <= 0 || fb_size[1] <= 0 {
		return {}
	}

	x0 := (bounds.x / fb_size[0]) * 2 - 1
	y0 := 1 - (bounds.y / fb_size[1]) * 2
	w := (bounds.w / fb_size[0]) * 2
	h := -(bounds.h / fb_size[1]) * 2

	return Rect{x = x0, y = y0, w = w, h = h}
}

@(private = "file")
vertex_array_push_quad :: proc(vertices: ^[dynamic]Vertex, quad: Quad, fb_size: [2]f32) {
	ndc_bounds := screen_to_ndc(quad.bounds, fb_size)
	ndc_size := rect_size(ndc_bounds)

	for i := 0; i < 4; i += 1 {
		winding := QUAD_UV[i]
		st := winding
		if quad.st_bounds.w != 0 || quad.st_bounds.h != 0 {
			st = rect_corner(quad.st_bounds)
			st += winding * rect_size(quad.st_bounds)
		}

		vertex := Vertex {
			frag_size_px  = rect_size(quad.bounds),
			xy            = rect_corner(ndc_bounds) + winding * ndc_size,
			uv            = winding,
			st            = st,
			col           = quad.fill.corners[i],
			tex_intensity = quad.tex_intensity,
			stroke        = quad.stroke.corners[i],
			radius_px     = quad.radius_px,
			thickness_px  = quad.thickness_px,
		}

		append_or_panic(vertices, vertex)
	}
}

@(private = "file")
quad_batch_calculate :: proc(quads: []Quad, allocator: mem.Allocator) -> []Quad_Batch {
	if len(quads) == 0 {
		return nil
	}

	batches :=
		make([dynamic]Quad_Batch, 0, len(quads), allocator) or_else panic(
			"failed to allocate quad batches",
		)
	start := 0

	for i := 1; i < len(quads); i += 1 {
		if quads[i].texture.handle != quads[start].texture.handle {
			append_or_panic(&batches, Quad_Batch{quads = quads[start:i]})
			start = i
		}
	}

	append_or_panic(&batches, Quad_Batch{quads = quads[start:]})
	return batches[:]
}

@(private = "file")
load_texture_from_image :: proc(image: APP_Image, filter: Texture_Filter) -> Texture {
	texture := Texture {
		size = {f32(image.width), f32(image.height)},
	}
	if image.width <= 0 || image.height <= 0 || len(image.pixels) == 0 {
		return texture
	}

	filter_mode := opengl.LINEAR
	if filter == .Neighbour {
		filter_mode = opengl.NEAREST
	}

	opengl.GenTextures(1, &texture.handle)
	opengl.BindTexture(opengl.TEXTURE_2D, texture.handle)
	opengl.TexParameteri(opengl.TEXTURE_2D, opengl.TEXTURE_MIN_FILTER, i32(filter_mode))
	opengl.TexParameteri(opengl.TEXTURE_2D, opengl.TEXTURE_MAG_FILTER, i32(filter_mode))
	opengl.TexParameteri(opengl.TEXTURE_2D, opengl.TEXTURE_WRAP_S, i32(opengl.REPEAT))
	opengl.TexParameteri(opengl.TEXTURE_2D, opengl.TEXTURE_WRAP_T, i32(opengl.REPEAT))
	opengl.TexImage2D(
		opengl.TEXTURE_2D,
		0,
		i32(opengl.RGBA8),
		i32(image.width),
		i32(image.height),
		0,
		opengl.RGBA,
		opengl.UNSIGNED_BYTE,
		raw_data(image.pixels),
	)

	return texture
}

load_texture_from_file :: proc(filename: string, filter: Texture_Filter) -> Texture {
	image := app_image_load_from_file(filename)
	defer app_image_destroy(image)
	return load_texture_from_image(image, filter)
}

@(private = "file")
load_font :: proc(path: string) -> Font_Data {
	out: Font_Data
	scratch := get_scratch()
	defer release_scratch(scratch)

	atlas_w :: 512
	atlas_h :: 512
	pixel_height :: f32(32)
	min_glyph :: u16(32)
	num_glyphs :: u16(96)

	font_bytes, err := os.read_entire_file(path, scratch.arena)
	if err != nil {
		fmt.eprintf("font load failed %s: %v\n", path, err)
		return out
	}

	atlas_pixels, atlas_err := make([]u8, atlas_w * atlas_h, scratch.arena)
	if atlas_err != nil {
		panic("failed to allocate font atlas")
	}

	rgba_pixels, rgba_err := make([]u8, atlas_w * atlas_h * 4, scratch.arena)
	if rgba_err != nil {
		panic("failed to allocate font rgba atlas")
	}

	bake_result := stbtt.BakeFontBitmap(
		raw_data(font_bytes),
		0,
		pixel_height,
		raw_data(atlas_pixels),
		atlas_w,
		atlas_h,
		c.int(min_glyph),
		c.int(num_glyphs),
		&out.chars[0],
	)
	if bake_result <= 0 {
		fmt.eprintf("font bake failed: %s\n", path)
		return out
	}

	for i := 0; i < atlas_w * atlas_h; i += 1 {
		rgba_pixels[i * 4 + 0] = 255
		rgba_pixels[i * 4 + 1] = 255
		rgba_pixels[i * 4 + 2] = 255
		rgba_pixels[i * 4 + 3] = atlas_pixels[i]
	}

	image := APP_Image {
		pixels = rgba_pixels,
		width  = atlas_w,
		height = atlas_h,
	}
	out.texture = load_texture_from_image(image, .Linear)
	out.min_glyph = min_glyph
	out.num_glyphs = num_glyphs
	out.pixel_height = pixel_height
	return out
}

@(private = "file")
compile_shader :: proc(kind: u32, path: string) -> u32 {
	shader := opengl.CreateShader(kind)
	scratch := get_scratch()
	defer release_scratch(scratch)

	source_bytes, err := os.read_entire_file(path, scratch.arena)
	if err != nil || len(source_bytes) == 0 {
		fmt.eprintf("shader load failed %s: %v\n", path, err)
		opengl.DeleteShader(shader)
		return 0
	}

	source_text := string(source_bytes)
	source_cstr :=
		strings.clone_to_cstring(source_text, scratch.arena) or_else panic(
			"failed to clone shader source",
		)
	sources := [1]cstring{source_cstr}
	lengths := [1]i32{i32(len(source_text))}

	opengl.ShaderSource(shader, 1, &sources[0], &lengths[0])
	opengl.CompileShader(shader)

	did_compile: i32
	opengl.GetShaderiv(shader, opengl.COMPILE_STATUS, &did_compile)
	if did_compile == 0 {
		log: [1024]u8
		log_len: i32
		opengl.GetShaderInfoLog(shader, len(log), &log_len, &log[0])
		fmt.eprintf("shader compile failed %s\n%s\n", path, string(log[:max(0, int(log_len))]))
		opengl.DeleteShader(shader)
		return 0
	}

	return shader
}

@(private = "file")
make_program :: proc(vertex_path, fragment_path: string) -> u32 {
	vertex_shader := compile_shader(opengl.VERTEX_SHADER, vertex_path)
	fragment_shader := compile_shader(opengl.FRAGMENT_SHADER, fragment_path)
	if vertex_shader == 0 || fragment_shader == 0 {
		if vertex_shader != 0 {
			opengl.DeleteShader(vertex_shader)
		}
		if fragment_shader != 0 {
			opengl.DeleteShader(fragment_shader)
		}
		return 0
	}

	program := opengl.CreateProgram()
	opengl.AttachShader(program, vertex_shader)
	opengl.AttachShader(program, fragment_shader)
	opengl.LinkProgram(program)

	did_link: i32
	opengl.GetProgramiv(program, opengl.LINK_STATUS, &did_link)
	if did_link == 0 {
		log: [1024]u8
		log_len: i32
		opengl.GetProgramInfoLog(program, len(log), &log_len, &log[0])
		fmt.eprintf("shader link failed\n%s\n", string(log[:max(0, int(log_len))]))
		opengl.DeleteProgram(program)
		program = 0
	}

	opengl.DeleteShader(vertex_shader)
	opengl.DeleteShader(fragment_shader)
	return program
}

@(private = "file")
uniform_location :: proc(program: u32, name: string) -> i32 {
	scratch := get_scratch()
	defer release_scratch(scratch)
	cname :=
		strings.clone_to_cstring(name, scratch.arena) or_else panic("failed to clone uniform name")
	return opengl.GetUniformLocation(program, cname)
}

@(private = "file")
vertex_attrib :: proc(index: u32, count: int, offset: uintptr) {
	opengl.EnableVertexAttribArray(index)
	opengl.VertexAttribPointer(index, i32(count), opengl.FLOAT, false, size_of(Vertex), offset)
}

Terrain_Type :: struct {
	name:           string,
	movement_speed: f32,
	tile_x:         u8,
	tile_y:         u8,
	elevation:      f32,
}

@(private = "file")
terrain_init :: proc(arena: mem.Allocator) -> World_Graph {
	world_graph: World_Graph


	scratch := get_scratch(arena)
	defer release_scratch(scratch)

	records, ok := load_csv_records("data/terrain_types.csv", scratch.arena)
	if !ok {
		return world_graph
	}

	terrain_types :=
		make([dynamic]Terrain_Type, 0, len(records), scratch.arena) or_else panic(
			"failed to allocate terrain types",
		)
	for row in records {
		if len(row) < 5 {
			continue
		}

		append_or_panic(
			&terrain_types,
			Terrain_Type {
				name = row[0],
				movement_speed = parse_f32_or_zero(row[1]),
				tile_x = parse_u8_or_zero(row[2]),
				tile_y = parse_u8_or_zero(row[3]),
				elevation = parse_f32_or_zero(row[4]),
			},
		)
	}

	heightmap := app_image_load_from_file("assets/britain.png")
	defer app_image_destroy(heightmap)
	if heightmap.width == 0 || heightmap.height == 0 || len(terrain_types) == 0 {
		return world_graph
	}

	terrain_cells, terrain_cells_err := make(
		[]Terrain_Type,
		heightmap.width * heightmap.height,
		scratch.arena,
	)
	if terrain_cells_err != nil {
		panic("failed to allocate terrain cell map")
	}

	terrain_keys := app_image_empty(scratch.arena, heightmap.width, heightmap.height)
	for y := 0; y < heightmap.height; y += 1 {
		for x := 0; x < heightmap.width; x += 1 {
			pixel_idx := (y * heightmap.width + x) * 4
			cell_idx := y * heightmap.width + x
			height := f32(heightmap.pixels[pixel_idx]) / 255.0

			terrain_id := 0
			for i := 0; i < len(terrain_types); i += 1 {
				if terrain_types[i].elevation >= height {
					terrain_id = i
					break
				}
			}

			tt := terrain_types[terrain_id]
			terrain_cells[cell_idx] = tt
			terrain_keys.pixels[pixel_idx + 0] = tt.tile_x
			terrain_keys.pixels[pixel_idx + 1] = tt.tile_y
			terrain_keys.pixels[pixel_idx + 2] = 0
			terrain_keys.pixels[pixel_idx + 3] = 255
		}
	}

	GL.terrain_keys = load_texture_from_image(terrain_keys, .Neighbour)
	return make_world_graph(arena, {heightmap.width, heightmap.height}, terrain_cells)
}

init :: proc(allocator: mem.Allocator) {
	GL.allocator = allocator
	GL.sprites =
		make([dynamic]Sprite, 0, 64, allocator) or_else panic("failed to allocate sprite registry")
	GL.program = make_program(VERTEX_SHADER_PATH, FRAGMENT_SHADER_PATH)

	opengl.Enable(opengl.BLEND)
	opengl.BlendFunc(opengl.SRC_ALPHA, opengl.ONE_MINUS_SRC_ALPHA)

	if GL.program != 0 {
		opengl.UseProgram(GL.program)
		opengl.Uniform1i(uniform_location(GL.program, "u_texture"), 0)
	}

	{
		white_pixel := [4]u8{255, 255, 255, 255}
		image := APP_Image {
			pixels = white_pixel[:],
			width  = 1,
			height = 1,
		}
		GL.default_texture = load_texture_from_image(image, .Neighbour)
	}

	GL.terrain_keys = {}
	GL.terrain_atlas = load_texture_from_file("assets/terrain_types.png", .Linear)
	GL.font = load_font("assets/fonts/default.ttf")

	{
		scratch := get_scratch()
		defer release_scratch(scratch)

		records, ok := load_csv_records("data/pawn_sprites.csv", scratch.arena)
		if ok {
			images :=
				make([dynamic]Named_Image, 0, len(records), scratch.arena) or_else panic(
					"failed to allocate sprite images",
				)
			for row in records {
				if len(row) < 2 {
					continue
				}
				append_or_panic(
					&images,
					Named_Image{name = row[0], image = app_image_load_from_file(row[1])},
				)
			}

			atlas := app_image_atlas_make(scratch.arena, images[:], 4)
			texture := load_texture_from_image(atlas.image, .Linear)

			for i := 0; i < len(atlas.region_names); i += 1 {
				push_sprite(atlas.region_names[i], texture, atlas.region_bounds[i])
			}

			for image_data in images {
				app_image_destroy(image_data.image)
			}
		}
	}

	world_map := terrain_init(allocator)

	opengl.GenVertexArrays(1, &GL.vao)
	opengl.GenBuffers(1, &GL.vbo)
	opengl.GenBuffers(1, &GL.ebo)

	opengl.BindVertexArray(GL.vao)
	opengl.BindBuffer(opengl.ARRAY_BUFFER, GL.vbo)
	opengl.BindBuffer(opengl.ELEMENT_ARRAY_BUFFER, GL.ebo)

	vertex_attrib(0, 2, offset_of(Vertex, xy))
	vertex_attrib(1, 2, offset_of(Vertex, uv))
	vertex_attrib(2, 2, offset_of(Vertex, st))
	vertex_attrib(3, 4, offset_of(Vertex, col))
	vertex_attrib(4, 2, offset_of(Vertex, frag_size_px))
	vertex_attrib(5, 4, offset_of(Vertex, stroke))
	vertex_attrib(6, 1, offset_of(Vertex, thickness_px))
	vertex_attrib(7, 1, offset_of(Vertex, radius_px))
	vertex_attrib(8, 1, offset_of(Vertex, tex_intensity))
	vertex_attrib(9, 4, offset_of(Vertex, rim_color))
	vertex_attrib(10, 1, offset_of(Vertex, rim_thickness_px))


	game_init(world_map)
}

@(private = "file")
draw_call :: proc(vertices: []Vertex, mode: Shader_Mode, texture: Texture) {
	quad_count := len(vertices) / 4
	index_count := quad_count * 6
	if GL.program == 0 || quad_count == 0 {
		return
	}

	scratch := get_scratch()
	defer release_scratch(scratch)

	indices, err := make([]u32, index_count, scratch.arena)
	if err != nil {
		panic("failed to allocate indices")
	}

	for quad_index := 0; quad_index < quad_count; quad_index += 1 {
		base := u32(quad_index * 4)
		index_offset := quad_index * 6
		indices[index_offset + 0] = base + 0
		indices[index_offset + 1] = base + 1
		indices[index_offset + 2] = base + 2
		indices[index_offset + 3] = base + 0
		indices[index_offset + 4] = base + 2
		indices[index_offset + 5] = base + 3
	}

	opengl.UseProgram(GL.program)
	opengl.Uniform1i(uniform_location(GL.program, "u_mode"), i32(mode))

	opengl.Uniform1i(uniform_location(GL.program, "u_texture"), 0)
	opengl.ActiveTexture(opengl.TEXTURE0)
	texture_handle := texture.handle
	if texture_handle == 0 {
		texture_handle = GL.default_texture.handle
	}
	opengl.BindTexture(opengl.TEXTURE_2D, texture_handle)

	opengl.Uniform1i(uniform_location(GL.program, "u_terrain_keys"), 1)
	opengl.ActiveTexture(opengl.TEXTURE1)
	opengl.BindTexture(opengl.TEXTURE_2D, GL.terrain_keys.handle)

	opengl.Uniform1i(uniform_location(GL.program, "u_terrain_atlas"), 2)
	opengl.ActiveTexture(opengl.TEXTURE2)
	opengl.BindTexture(opengl.TEXTURE_2D, GL.terrain_atlas.handle)

	opengl.BindVertexArray(GL.vao)
	opengl.BindBuffer(opengl.ARRAY_BUFFER, GL.vbo)
	opengl.BindBuffer(opengl.ELEMENT_ARRAY_BUFFER, GL.ebo)

	opengl.BufferData(
		opengl.ARRAY_BUFFER,
		len(vertices) * size_of(Vertex),
		raw_data(vertices),
		opengl.DYNAMIC_DRAW,
	)
	opengl.BufferData(
		opengl.ELEMENT_ARRAY_BUFFER,
		len(indices) * size_of(u32),
		raw_data(indices),
		opengl.DYNAMIC_DRAW,
	)
	opengl.DrawElements(opengl.TRIANGLES, i32(index_count), opengl.UNSIGNED_INT, nil)
}

measure_text :: proc(text: string, pixel_height: f32) -> Text_Measurement {
	out: Text_Measurement
	font := GL.font
	texture := font.texture
	if texture.handle == 0 || texture.size[0] <= 0 || texture.size[1] <= 0 {
		return out
	}

	scale := f32(1)
	if font.pixel_height != 0 {
		scale = pixel_height / font.pixel_height
	}

	line_height := font.pixel_height * scale
	x := f32(0)
	y := f32(0)
	min_x := f32(0)
	min_y := f32(0)
	max_x := f32(0)
	max_y := f32(0)
	max_line_advance_x := f32(0)
	has_glyph := false

	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '\n' {
			max_line_advance_x = max(max_line_advance_x, x * scale)
			x = 0
			y += font.pixel_height
			max_y = max(max_y, y * scale)
			continue
		}
		if c < byte(font.min_glyph) || c >= byte(font.min_glyph + font.num_glyphs) {
			continue
		}

		glyph_quad: stbtt.aligned_quad
		stbtt.GetBakedQuad(
			&font.chars[0],
			i32(texture.size[0]),
			i32(texture.size[1]),
			i32(c - byte(font.min_glyph)),
			&x,
			&y,
			&glyph_quad,
			true,
		)

		glyph_x0 := glyph_quad.x0 * scale
		glyph_y0 := glyph_quad.y0 * scale
		glyph_x1 := glyph_quad.x1 * scale
		glyph_y1 := glyph_quad.y1 * scale

		if !has_glyph {
			min_x = glyph_x0
			min_y = glyph_y0
			max_x = glyph_x1
			max_y = glyph_y1
			has_glyph = true
		} else {
			min_x = min(min_x, glyph_x0)
			min_y = min(min_y, glyph_y0)
			max_x = max(max_x, glyph_x1)
			max_y = max(max_y, glyph_y1)
		}

		max_line_advance_x = max(max_line_advance_x, x * scale)
	}

	max_x = max(max_x, max_line_advance_x)
	if has_glyph {
		out.size = {max_x - min_x, max_y - min_y}
		out.bounds_offset = {min_x, min_y}
		out.baseline_y = -min_y
	} else {
		out.size = {max_line_advance_x, line_height}
		out.baseline_y = line_height
	}

	return out
}

@(private = "file")
font_line_height :: proc(pixel_height: f32) -> f32 {
	font := GL.font
	scale := f32(1)
	if font.pixel_height != 0 {
		scale = pixel_height / font.pixel_height
	}
	return font.pixel_height * scale
}

@(private = "file")
append_displayable_text_line :: proc(
	lines: ^[dynamic]Displayable_Text_Line,
	text: string,
	pixel_height: f32,
) {
	append_or_panic(
		lines,
		Displayable_Text_Line{text = text, measure = measure_text(text, pixel_height)},
	)
}

@(private = "file")
truncate_text_to_width :: proc(text: string, pixel_height, max_width: f32) -> string {
	if max_width <= 0 || measure_text(text, pixel_height).size[0] <= max_width {
		return text
	}

	end := 0
	for i := 0; i < len(text); i += 1 {
		candidate := text[:i + 1]
		if measure_text(candidate, pixel_height).size[0] > max_width {
			break
		}
		end = i + 1
	}

	return text[:end]
}

@(private = "file")
append_wrapped_text_range :: proc(
	lines: ^[dynamic]Displayable_Text_Line,
	text: string,
	pixel_height, max_width: f32,
) {
	if len(text) == 0 || max_width <= 0 || measure_text(text, pixel_height).size[0] <= max_width {
		append_displayable_text_line(lines, text, pixel_height)
		return
	}

	line_start := 0
	line_end := 0
	last_break := -1

	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == ' ' || c == '\t' {
			last_break = i
		}

		candidate := text[line_start:i + 1]
		if measure_text(candidate, pixel_height).size[0] <= max_width {
			line_end = i + 1
			continue
		}

		if last_break >= line_start {
			append_displayable_text_line(lines, text[line_start:last_break], pixel_height)
			line_start = last_break + 1
			for line_start < len(text) && text[line_start] == ' ' {
				line_start += 1
			}
			i = line_start - 1
			line_end = line_start
			last_break = -1
		} else if line_end > line_start {
			append_displayable_text_line(lines, text[line_start:line_end], pixel_height)
			line_start = line_end
			i = line_start - 1
			last_break = -1
		} else {
			append_displayable_text_line(lines, text[line_start:i + 1], pixel_height)
			line_start = i + 1
			line_end = line_start
			last_break = -1
		}
	}

	if line_start < len(text) {
		append_displayable_text_line(lines, text[line_start:], pixel_height)
	}
}

@(private = "file")
displayable_text_from_string :: proc(
	text: string,
	pixel_height, max_width: f32,
	wrapping: Draw_Text_Wrapping,
	allocator: mem.Allocator,
) -> Displayable_Text {
	out: Displayable_Text
	out.line_height = font_line_height(pixel_height)
	if len(text) == 0 {
		return out
	}

	lines :=
		make([dynamic]Displayable_Text_Line, 0, 1, allocator) or_else panic(
			"failed to allocate displayable text lines",
		)

	if wrapping == .Nil {
		measure := measure_text(text, pixel_height)
		append_or_panic(&lines, Displayable_Text_Line{text = text, measure = measure})
		out.lines = lines[:]
		out.measurement = measure
		return out
	}

	range_start := 0
	for i := 0; i <= len(text); i += 1 {
		if i != len(text) && text[i] != '\n' {
			continue
		}

		range_text := text[range_start:i]
		#partial switch wrapping {
		case .Wrap:
			append_wrapped_text_range(&lines, range_text, pixel_height, max_width)
		case .Truncate:
			append_displayable_text_line(
				&lines,
				truncate_text_to_width(range_text, pixel_height, max_width),
				pixel_height,
			)
		}
		range_start = i + 1
	}

	max_width := f32(0)
	min_y := f32(0)
	max_y := f32(0)
	has_glyph_bounds := false
	for line, line_index in lines {
		max_width = max(max_width, line.measure.size[0])
		line_y := f32(line_index) * out.line_height
		line_min_y := line_y + line.measure.bounds_offset[1]
		line_max_y := line_min_y + line.measure.size[1]
		if !has_glyph_bounds {
			min_y = line_min_y
			max_y = line_max_y
			has_glyph_bounds = true
		} else {
			min_y = min(min_y, line_min_y)
			max_y = max(max_y, line_max_y)
		}
	}
	out.lines = lines[:]
	if has_glyph_bounds {
		out.measurement.size = {max_width, max_y - min_y}
		out.measurement.bounds_offset = {0, min_y}
		out.measurement.baseline_y = -min_y
	}
	return out
}

@(private = "file")
draw_text_at_pos :: proc(
	quads: ^[dynamic]Quad,
	text: string,
	pos: [2]f32,
	pixel_height: f32,
	color: Color,
) {
	font := GL.font
	texture := font.texture
	if texture.handle == 0 || texture.size[0] <= 0 || texture.size[1] <= 0 {
		return
	}

	scale := f32(1)
	if font.pixel_height != 0 {
		scale = pixel_height / font.pixel_height
	}

	x := pos[0] / scale
	y := pos[1] / scale

	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '\n' {
			x = pos[0] / scale
			y += font.pixel_height
			continue
		}
		if c < byte(font.min_glyph) || c >= byte(font.min_glyph + font.num_glyphs) {
			continue
		}

		glyph_quad: stbtt.aligned_quad
		stbtt.GetBakedQuad(
			&font.chars[0],
			i32(texture.size[0]),
			i32(texture.size[1]),
			i32(c - byte(font.min_glyph)),
			&x,
			&y,
			&glyph_quad,
			true,
		)

		append_or_panic(
			quads,
			Quad {
				bounds = Rect {
					x = glyph_quad.x0 * scale,
					y = glyph_quad.y0 * scale,
					w = (glyph_quad.x1 - glyph_quad.x0) * scale,
					h = (glyph_quad.y1 - glyph_quad.y0) * scale,
				},
				st_bounds = Rect {
					x = glyph_quad.s0,
					y = glyph_quad.t0,
					w = glyph_quad.s1 - glyph_quad.s0,
					h = glyph_quad.t1 - glyph_quad.t0,
				},
				fill = color_rect_uniform(color),
				texture = font.texture,
				tex_intensity = 1,
			},
		)
	}
}

@(private = "file")
draw_displayable_text_in_rect :: proc(
	quads: ^[dynamic]Quad,
	displayable: Displayable_Text,
	bounds: Rect,
	pixel_height: f32,
	alignment: Draw_Text_Alignment,
	color: Color,
) {
	if len(displayable.lines) == 0 {
		return
	}

	baseline_y := bounds.y + displayable.measurement.baseline_y
	switch alignment {
	case .Center, .Left:
		baseline_y += (bounds.h - displayable.measurement.size[1]) / 2
	case .Top_Left:
	}

	for line, line_index in displayable.lines {
		pos := [2]f32{bounds.x, baseline_y + f32(line_index) * displayable.line_height}
		switch alignment {
		case .Center:
			pos[0] += (bounds.w - line.measure.size[0]) / 2 - line.measure.bounds_offset[0]
		case .Left, .Top_Left:
			pos[0] -= line.measure.bounds_offset[0]
		}
		draw_text_at_pos(quads, line.text, pos, pixel_height, color)
	}
}

@(private = "file")
draw_text_in_rect :: proc(
	quads: ^[dynamic]Quad,
	text: string,
	bounds: Rect,
	pixel_height: f32,
	alignment: Draw_Text_Alignment,
	wrapping: Draw_Text_Wrapping,
	color: Color,
	allocator: mem.Allocator,
) {
	displayable := displayable_text_from_string(text, pixel_height, bounds.w, wrapping, allocator)
	draw_displayable_text_in_rect(quads, displayable, bounds, pixel_height, alignment, color)
}

@(private = "file")
interpret_game_draw_commands :: proc(
	out: ^[dynamic]Quad,
	draw_commands: []Draw_Command,
	camera: Camera,
	framebuffer_size: [2]f32,
	allocator: mem.Allocator,
) {
	for cmd in draw_commands {
		sprite := get_sprite_by_name(cmd.texture.name)
		texture := sprite.texture
		screen_bounds := camera_world_to_screen_rect(camera, cmd.bounds, framebuffer_size)
		quad := Quad {
			bounds        = screen_bounds,
			clip          = cmd.clip,
			fill          = cmd.texture.color,
			tex_intensity = cmd.texture.intensity,
			texture       = texture,
			stroke        = cmd.border.color,
			thickness_px  = cmd.border.thickness,
			radius_px     = cmd.border.corner_radius,
		}

		switch cmd.texture.mapping {
		case .Stretch:
			quad.st_bounds = sprite.bounds
		case .Tile:
			if texture.size[0] > 0 {
				quad.st_bounds.w = cmd.bounds.w / texture.size[0]
			}
			if texture.size[1] > 0 {
				quad.st_bounds.h = cmd.bounds.h / texture.size[1]
			}
		}

		append_or_panic(out, quad)
		draw_text_in_rect(
			out,
			cmd.text.text,
			screen_bounds,
			cmd.text.pixel_height,
			cmd.text.alignment,
			cmd.text.wrapping,
			cmd.text.color,
			allocator,
		)
	}
}

draw_commands :: proc(commands: []Draw_Command, camera: Camera, framebuffer_size: [2]f32) {
	scratch := get_scratch()
	defer release_scratch(scratch)

	quads :=
		make([dynamic]Quad, 0, DEFAULT_MAX_GL_QUADS, scratch.arena) or_else panic(
			"failed to allocate quads",
		)
	interpret_game_draw_commands(&quads, commands, camera, framebuffer_size, scratch.arena)

	batches := quad_batch_calculate(quads[:], scratch.arena)
	for batch in batches {
		if len(batch.quads) == 0 {
			continue
		}

		vertices :=
			make([dynamic]Vertex, 0, len(batch.quads) * 4, scratch.arena) or_else panic(
				"failed to allocate vertices",
			)
		for quad in batch.quads {
			vertex_array_push_quad(&vertices, quad, framebuffer_size)
		}

		draw_call(vertices[:], .Default, batch.quads[0].texture)
	}
}

draw_terrain :: proc(camera: Camera, framebuffer_size: [2]f32) {
	terrain_tile_size_px :: f32(40)
	if framebuffer_size[0] <= 0 ||
	   framebuffer_size[1] <= 0 ||
	   GL.terrain_keys.size[0] <= 0 ||
	   GL.terrain_keys.size[1] <= 0 {
		return
	}

	camera := camera
	if camera.world_to_px <= 0 {
		camera.world_to_px = 1
	}
	if camera.zoom <= 0 {
		camera.zoom = 1
	}

	world_to_px := camera.world_to_px
	scratch := get_scratch()
	defer release_scratch(scratch)

	vertices :=
		make([dynamic]Vertex, 0, 4, scratch.arena) or_else panic(
			"failed to allocate terrain vertices",
		)
	screen_points := [4][2]f32 {
		{0, 0},
		{framebuffer_size[0], 0},
		{framebuffer_size[0], framebuffer_size[1]},
		{0, framebuffer_size[1]},
	}

	for screen_point in screen_points {
		world_point := camera_screen_to_world_pos(camera, screen_point, framebuffer_size)
		append_or_panic(
			&vertices,
			Vertex {
				xy = {
					(screen_point[0] / framebuffer_size[0]) * 2 - 1,
					1 - (screen_point[1] / framebuffer_size[1]) * 2,
				},
				uv = {
					(world_point[0] + 0.5) / GL.terrain_keys.size[0],
					(world_point[1] + 0.5) / GL.terrain_keys.size[1],
				},
				st = {
					world_point[0] * world_to_px / terrain_tile_size_px,
					world_point[1] * world_to_px / terrain_tile_size_px,
				},
				col = WHITE,
			},
		)
	}

	draw_call(vertices[:], .Terrain, {})
}

push_sprite :: proc(name: string, texture: Texture, region: Rect) {
	st_bounds: Rect
	if texture.size[0] > 0 && texture.size[1] > 0 {
		st_bounds.x = region.x / texture.size[0]
		st_bounds.y = region.y / texture.size[1]
		st_bounds.w = region.w / texture.size[0]
		st_bounds.h = region.h / texture.size[1]
	}

	cloned_name := strings.clone(name, GL.allocator) or_else panic("failed to clone sprite name")
	append_or_panic(&GL.sprites, Sprite{name = cloned_name, texture = texture, bounds = st_bounds})
}

@(private = "file")
get_sprite_by_name :: proc(name: string) -> Sprite {
	for sprite in GL.sprites {
		if sprite.name == name {
			return sprite
		}
	}
	return {}
}
