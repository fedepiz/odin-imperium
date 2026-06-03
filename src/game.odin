package main

import "core:fmt"
import "core:mem"
import "core:strings"

Camera :: struct {
	center:      [2]f32,
	world_to_px: f32,
	zoom:        f32,
}

Camera_Input :: struct {
	dtranslate: [2]f32,
	dzoom:      f32,
}

Frame_Input :: struct {
	mouse_pos:        [2]f32,
	framebuffer_size: [2]f32,
	scroll_delta:     [2]f32,
	mouse_pressed:    bool,
	mouse_clicked:    bool,
	camera:           Camera_Input,
	delta:            f32,
}

Draw_Text_Alignment :: enum {
	Center,
	Left,
	Top_Left,
}

Draw_Text_Wrapping :: enum {
	Truncate,
	Wrap,
}

Draw_Text :: struct {
	text:         string,
	color:        Color,
	pixel_height: f32,
	alignment:    Draw_Text_Alignment,
	wrapping:     Draw_Text_Wrapping,
}

Draw_Border :: struct {
	color:         Color_Rect,
	thickness:     f32,
	corner_radius: f32,
}

Draw_Texture_Mapping :: enum {
	Stretch,
	Tile,
}

Draw_Texture :: struct {
	color:     Color_Rect,
	name:      string,
	intensity: f32,
	mapping:   Draw_Texture_Mapping,
}

Draw_Command :: struct {
	bounds:  Rect,
	clip:    Rect,
	texture: Draw_Texture,
	border:  Draw_Border,
	text:    Draw_Text,
}

Click_Box :: struct {
	id:     ThId,
	bounds: Rect,
}

Frame_Output :: struct {
	camera:              Camera,
	board_draw_commands: []Draw_Command,
	ui_draw_commands:    []Draw_Command,
}

Game_State :: struct {
	camera:      Camera,
	tick_num:    u64,
	things:      [2]Things,
	selected_id: ThId,
}

GAME: Game_State

camera_screen_per_world_px :: proc(camera: Camera) -> f32 {
	world_to_px := camera.world_to_px
	if world_to_px <= 0 {
		world_to_px = 1
	}

	zoom := camera.zoom
	if zoom <= 0 {
		zoom = 1
	}

	return world_to_px * zoom
}

camera_world_to_screen_pos :: proc(camera: Camera, pos, framebuffer_size: [2]f32) -> [2]f32 {
	_ = framebuffer_size
	screen_per_world_px := camera_screen_per_world_px(camera)
	return {
		(pos[0] - camera.center[0]) * screen_per_world_px,
		(pos[1] - camera.center[1]) * screen_per_world_px,
	}
}

camera_screen_to_world_pos :: proc(camera: Camera, pos, framebuffer_size: [2]f32) -> [2]f32 {
	_ = framebuffer_size
	screen_per_world_px := camera_screen_per_world_px(camera)
	return {
		camera.center[0] + pos[0] / screen_per_world_px,
		camera.center[1] + pos[1] / screen_per_world_px,
	}
}

camera_world_to_screen_rect :: proc(camera: Camera, rect: Rect, framebuffer_size: [2]f32) -> Rect {
	pos := camera_world_to_screen_pos(camera, rect_corner(rect), framebuffer_size)
	screen_per_world_px := camera_screen_per_world_px(camera)
	return {
		x = pos[0],
		y = pos[1],
		w = rect.w * screen_per_world_px,
		h = rect.h * screen_per_world_px,
	}
}

camera_center_on :: proc(camera: ^Camera, pos, framebuffer_size: [2]f32) {
	screen_per_world_px := camera_screen_per_world_px(camera^)
	camera.center[0] = pos[0] - framebuffer_size[0] * 0.5 / screen_per_world_px
	camera.center[1] = pos[1] - framebuffer_size[1] * 0.5 / screen_per_world_px
}

camera_update :: proc(camera: ^Camera, dtranslate: [2]f32, dzoom: f32, framebuffer_size: [2]f32) {
	if camera.world_to_px <= 0 {
		camera.world_to_px = 1
	}
	if camera.zoom <= 0 {
		camera.zoom = 1
	}

	screen_per_world_px := camera_screen_per_world_px(camera^)
	camera.center += dtranslate / screen_per_world_px

	view_center := framebuffer_size * 0.5
	world_center := camera_screen_to_world_pos(camera^, view_center, framebuffer_size)
	camera.zoom *= 1 + dzoom
	if camera.zoom < 0.1 {
		camera.zoom = 0.1
	}
	camera_center_on(camera, world_center, framebuffer_size)
}

game_init :: proc() {
	ui_init()
	GAME = {}
	GAME.camera.world_to_px = 10
	GAME.camera.zoom = 1
}

game_build_ui :: proc(
	allocator: mem.Allocator,
	out: ^Frame_Output,
	input: Frame_Input,
) -> (
	mouse_over: bool,
) {
	ui_begin_frame(input)

	ui_unit := f32(30)
	ui_base_color := color_rgba8(207, 185, 151, 255)
	ui_border := color_mix(ui_base_color, BLACK, 0.5)

	ui_style_push_color(allocator, .Fill_Cold, ui_base_color)
	ui_style_push_color(allocator, .Fill_Hover, color_rgba8(255, 0, 0, 255))
	ui_style_push_color(allocator, .Fill_Held, color_rgba(0, 0.75, 0, 1))
	ui_style_push_color(allocator, .Item_Border, ui_border)
	ui_style_push_number(allocator, .Unit, ui_unit)
	ui_style_push_color(allocator, .Text_Color, BLACK)
	ui_style_push_number(allocator, .Text_Size, 26)
	ui_style_push_number(allocator, .Heading_Size, 36)
	ui_style_push_number(allocator, .Thickness, 4)
	ui_style_push_color(allocator, .Panel_Fill, ui_base_color)
	ui_style_push_color(allocator, .Panel_Border, ui_border)

	{
		_ = ui_panel_begin("###Panel", {0, 0})
		ui_set_texture("widget", 0.25)
		ui_heading("Test Panel", 11)
		ui_vsep()
		{
			ui_row_begin()
			ui_hsep()
			_ = ui_button("Hello", 4)
			ui_hsep()
			_ = ui_button("Bye", 4)
			ui_hsep()
			ui_widget_end()
		}
		ui_space(0, 1)
		{
			ui_row_begin()
			ui_hsep()
			_ = ui_button("Goodbye", 4)
			ui_hsep()
			ui_widget_end()
		}
		ui_vsep()
		ui_widget_end()
	}

	out.camera = GAME.camera
	out.ui_draw_commands = ui_end_frame(allocator)

	return ui_is_mouse_over_area()
}

update_and_render :: proc(allocator: mem.Allocator, input: Frame_Input) -> Frame_Output {
	if GAME.tick_num == 0 {
		GAME.camera.zoom = 4
		camera_center_on(&GAME.camera, {300, 250}, input.framebuffer_size)
	}

	GAME.tick_num += 1

	camera_update(
		&GAME.camera,
		input.camera.dtranslate,
		input.camera.dzoom,
		input.framebuffer_size,
	)

	tick_result: Tick_Output
	{
		// Tick here
		new_things := &GAME.things[GAME.tick_num % 2]
		old_things := &GAME.things[1 - GAME.tick_num % 2]

		if GAME.tick_num == 1 {
			things_init(old_things)
		}

		arena: mem.Arena
		mem.arena_init(&arena, new_things.blob[:])

		ctx: Tick_Ctx
		ctx.tick_num = GAME.tick_num
		ctx.alloc = mem.arena_allocator(&arena)
		ctx.old_things = old_things.entries[:]
		ctx.new_things = new_things.entries[:]
		ctx.selected_id = GAME.selected_id
		ctx.camera = GAME.camera

		tick_result = things_tick(allocator, ctx)
	}

	out: Frame_Output

	out.board_draw_commands = tick_result.draw_commands
	mouse_over_ui := game_build_ui(allocator, &out, input)

	// Handle on click
	if !mouse_over_ui && input.mouse_clicked {
		mouse_pos := camera_screen_to_world_pos(
			GAME.camera,
			input.mouse_pos,
			input.framebuffer_size,
		)
		picked_id: ThId
		cbs := tick_result.click_boxes
		for ix in 1 ..= len(cbs) {
			click_box := cbs[len(cbs) - ix]
			if rect_contains_point(click_box.bounds, mouse_pos) {
				picked_id = click_box.id
			}
		}
		GAME.selected_id = picked_id
	}
	return out
}

THINGS_BLOB_SIZE :: 20_000_000

NUM_THINGS :: 65000

ThId :: distinct u32
ThId_Parts :: struct {
	ix:         u16,
	generation: u16,
}

thid_make :: #force_inline proc(ix: u16, generation: u16) -> ThId {
	return ThId(u32(ix) | u32(generation) << 16)
}

thid_parts :: #force_inline proc(id: ThId) -> ThId_Parts {
	id := u32(id)
	return {ix = u16(id), generation = u16(id >> 16)}
}

thid_is_valid :: #force_inline proc(id: ThId) -> bool {
	parts := thid_parts(id)
	return parts.ix != 0 && parts.generation % 2 == 1
}

thid_bump_generation :: proc(id: ThId) -> ThId {
	parts := thid_parts(id)
	return thid_make(parts.ix, parts.generation + 1)
}

Label :: enum {
	Name,
}

Var :: enum {
	Pos_X,
	Pos_Y,
	Size,
}

Thing :: struct {
	id:     ThId,
	sprite: string,
	labels: [Label]string,
	vars:   [Var]f32,
}

Things :: struct {
	blob:    [THINGS_BLOB_SIZE]byte,
	entries: [NUM_THINGS]Thing,
}

things_init :: proc(things: ^Things) {
	for ix in 0 ..< NUM_THINGS {
		thing: Thing
		thing.id = thid_make(u16(ix), 0)
		things.entries[ix] = thing
	}

	// Create the first thing...just as an example
	{
		thing := &things.entries[1]
		// Marking this alive...
		thing.id = thid_bump_generation(thing.id)
		thing.labels[.Name] = "Ansoaldus"
		thing.sprite = "soldier"
		thing.vars[.Pos_X] = 300
		thing.vars[.Pos_Y] = 250
		thing.vars[.Size] = 1
	}
}

Tick_Ctx :: struct {
	tick_num:    u64,
	alloc:       mem.Allocator,
	old_things:  []Thing,
	new_things:  []Thing,
	selected_id: ThId,
	camera:      Camera,
}

Tick_Output :: struct {
	draw_commands: []Draw_Command,
	click_boxes:   []Click_Box,
}

things_tick :: proc(arena: mem.Allocator, ctx: Tick_Ctx) -> Tick_Output {
	// "Write pass"
	num_visible := 0
	num_labels := 0
	for ix in 1 ..< NUM_THINGS {
		old := ctx.old_things[ix]
		new := &ctx.new_things[ix]

		new.id = old.id
		new.sprite = old.sprite

		// Assume most lables are copied most of the time
		for label in Label {
			new.labels[label] = strings.clone(old.labels[label], ctx.alloc)
		}
		new.vars = old.vars

		if len(new.labels[.Name]) != 0 do num_labels += 1
		if new.vars[.Size] != 0 do num_visible += 1
	}

	draw_commands: [dynamic]Draw_Command = make(
		[dynamic]Draw_Command,
		0,
		num_visible + num_labels,
		arena,
	)
	click_boxes: [dynamic]Click_Box = make([dynamic]Click_Box, 0, num_visible, arena)

	for ix in 1 ..< NUM_THINGS {
		this := &ctx.new_things[ix]
		pos_x := this.vars[.Pos_X]
		pos_y := this.vars[.Pos_Y]
		size := this.vars[.Size]
		if size <= 0 || len(this.sprite) == 0 {continue}
		is_selected := this.id == ctx.selected_id

		{
			cmd: Draw_Command
			cmd.bounds = {pos_x, pos_y, size, size}
			cmd.texture.name = this.sprite
			cmd.texture.color = color_rect_uniform(WHITE)
			cmd.texture.intensity = 1

			if is_selected {
				cmd.border.color = color_rect_uniform(YELLOW)
				cmd.border.thickness = 2
			}

			append(&draw_commands, cmd)

			cb: Click_Box
			cb.id = this.id
			cb.bounds = cmd.bounds
			append(&click_boxes, cb)
		}

		name := this.labels[.Name]
		if len(name) != 0 {
			// Draw label
			label_pixel_height := f32(22)
			label_padding_px := f32(4)
			label_gap_px := f32(2)
			world_per_screen_px := 1 / camera_screen_per_world_px(ctx.camera)
			text_measure := measure_text(name, label_pixel_height)
			label_w := (text_measure.size[0] + label_padding_px * 2) * world_per_screen_px
			label_h := (text_measure.size[1] + label_padding_px * 2) * world_per_screen_px
			label_x := pos_x + (size - label_w) * 0.5
			label_y := pos_y + size + label_gap_px * world_per_screen_px

			label_cmd: Draw_Command
			label_cmd.bounds = {label_x, label_y, label_w, label_h}
			label_cmd.texture.color = color_rect_uniform(color_rgba(0, 0, 0, 0.6))
			label_cmd.text.text = name
			label_cmd.text.color = WHITE
			if is_selected {
				label_cmd.text.color = YELLOW
			}
			label_cmd.text.pixel_height = label_pixel_height
			label_cmd.text.alignment = .Center
			label_cmd.text.wrapping = .Truncate

			append(&draw_commands, label_cmd)
		}
	}

	out: Tick_Output
	out.draw_commands = draw_commands[:]
	out.click_boxes = click_boxes[:]
	return out
}
