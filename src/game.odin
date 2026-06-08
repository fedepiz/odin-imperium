package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:time"

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
	speed_up:         bool,
}

Draw_Text_Alignment :: enum {
	Center,
	Left,
	Top_Left,
}

Draw_Text_Wrapping :: enum {
	Nil,
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
	layer:   int,
}

Click_Box :: struct {
	id:     ThId,
	bounds: Rect,
	layer:  int,
}

Frame_Output :: struct {
	camera:              Camera,
	board_draw_commands: []Draw_Command,
	ui_draw_commands:    []Draw_Command,
}

Game_Timer :: struct {
	accumulated: f32,
	speed:       f32,
}

@(private = "file")
PERSISTENT_BLOB_SIZE :: 10_000_000

@(private = "file")
Persistent_Memory :: struct {
	blob:  [PERSISTENT_BLOB_SIZE]byte,
	arena: mem.Arena,
	alloc: mem.Allocator,
}

@(private = "file")
persistent_memory_init :: proc(memory: ^Persistent_Memory) {
	mem.arena_init(&memory.arena, memory.blob[:])
	memory.alloc = mem.arena_allocator(&memory.arena)
}


Game_State :: struct {
	persistent_memory: Persistent_Memory,
	timer:             Game_Timer,
	camera:            Camera,
	world_graph:       World_Graph,
	tick_num:          u64,
	things:            [2]Things,
	selected_id:       ThId,
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

game_init :: proc(world_graph: World_Graph) {
	ui_init()
	GAME = {}
	persistent_memory_init(&GAME.persistent_memory)
	GAME.timer.speed = 120
	GAME.camera.world_to_px = 10
	GAME.camera.zoom = 1
	GAME.world_graph = world_graph
}

Gui_Selected_Panel :: struct {
	visible:   bool,
	info_text: string,
}

game_build_ui :: proc(
	allocator: mem.Allocator,
	out: ^Frame_Output,
	input: Frame_Input,
	selected_panel: Gui_Selected_Panel,
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

	// {
	// 	_ = ui_panel_begin("###Panel", {0.5, 0.5})
	// 	ui_set_texture("widget", 0.25)
	// 	ui_heading("Test Panel", 11)
	// 	ui_vsep()
	// 	{
	// 		ui_row_begin()
	// 		ui_hsep()
	// 		_ = ui_button("Hello", 4)
	// 		ui_hsep()
	// 		_ = ui_button("Bye", 4)
	// 		ui_hsep()
	// 		ui_widget_end()
	// 	}
	// 	ui_space(0, 1)
	// 	{
	// 		ui_row_begin()
	// 		ui_hsep()
	// 		_ = ui_button("Goodbye", 4)
	// 		ui_hsep()
	// 		ui_widget_end()
	// 	}
	// 	ui_vsep()
	// 	ui_widget_end()
	// }

	if selected_panel.visible {
		_ = ui_panel_begin("###SELECTED_PANEL", {0, 0})
		ui_set_texture("widget", 0.25)
		ui_heading("Selected", 11)
		ui_vsep()
		{
			ui_row_begin()
			ui_hsep()
			ui_multiline(selected_panel.info_text, 10, 10)
			ui_hsep()
			ui_widget_end()
		}
		ui_vsep()
		ui_widget_end()
	}

	out.camera = GAME.camera
	out.ui_draw_commands = ui_end_frame(
		allocator,
		rect_from_pos_and_size({}, input.framebuffer_size),
	)

	return ui_is_mouse_over_area()
}

update_and_render :: proc(allocator: mem.Allocator, input: Frame_Input) -> Frame_Output {
	num_ticks: int

	{
		speed_mod: f32 = !input.speed_up ? 1 : 2
		GAME.timer.accumulated += input.delta * GAME.timer.speed * speed_mod
		num_ticks = int(math.floor(GAME.timer.accumulated))
		GAME.timer.accumulated = GAME.timer.accumulated - f32(num_ticks)
		if GAME.tick_num == 0 {
			GAME.camera.zoom = 4
			camera_center_on(&GAME.camera, {300, 250}, input.framebuffer_size)
		}
	}

	camera_update(
		&GAME.camera,
		input.camera.dtranslate,
		input.camera.dzoom,
		input.framebuffer_size,
	)

	if GAME.tick_num == 0 {
		old_things := &GAME.things[1 - GAME.tick_num % 2]
		if !things_setup(THING_INIT_PATH, old_things, GAME.persistent_memory.alloc) {
			panic("failed to load initial things")
		}
		GAME.tick_num += 1
	}

	for tick_idx in 0 ..< num_ticks {
		GAME.tick_num += 1
		// Tick here
		new_things := &GAME.things[GAME.tick_num % 2]
		old_things := &GAME.things[1 - GAME.tick_num % 2]

		phase_arena: mem.Arena
		mem.arena_init(&phase_arena, new_things.blob[:])

		ctx: Sim_Ctx
		ctx.tick_num = GAME.tick_num
		ctx.alloc = mem.arena_allocator(&phase_arena)
		ctx.old_things = old_things.entries[:]
		ctx.new_things = new_things.entries[:]
		ctx.selected_id = GAME.selected_id
		ctx.world_graph = GAME.world_graph

		// watch: time.Stopwatch
		// time.stopwatch_start(&watch)
		things_simulate(ctx)
		// time.stopwatch_stop(&watch)
		// elapsed := time.stopwatch_duration(watch)
		// fmt.printfln("sim tick: %v, time: %v", ctx.tick_num, elapsed)
	}

	tick_output: Tick_Output
	{
		ctx: Present_Ctx
		ctx.camera = GAME.camera
		ctx.selected_id = GAME.selected_id
		ctx.things = (GAME.things[GAME.tick_num % 2]).entries[:]
		tick_output = things_present(allocator, ctx)
	}

	out: Frame_Output

	out.board_draw_commands = tick_output.draw_commands[:]
	mouse_over_ui := game_build_ui(allocator, &out, input, tick_output.selected_panel)

	// Handle on click
	if !mouse_over_ui && input.mouse_clicked {
		mouse_pos := camera_screen_to_world_pos(
			GAME.camera,
			input.mouse_pos,
			input.framebuffer_size,
		)
		picked_id: ThId
		cbs := tick_output.click_boxes
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

