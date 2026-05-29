package main

import "core:c"
import "core:fmt"
import "core:mem"
import gl "vendor:OpenGL"
import "vendor:glfw"

WINDOW_TITLE :: "imperium"
WINDOW_WIDTH :: 1600
WINDOW_HEIGHT :: 900
OPENGL_MAJOR :: 3
OPENGL_MINOR :: 3

Platform_State :: struct {
	mouse_pos:              [2]f64,
	scroll_delta:           [2]f64,
	keys_down_now:          [glfw.KEY_LAST + 1]bool,
	keys_down_prev:         [glfw.KEY_LAST + 1]bool,
	mouse_button_down_now:  [glfw.MOUSE_BUTTON_LAST + 1]bool,
	mouse_button_down_prev: [glfw.MOUSE_BUTTON_LAST + 1]bool,
}

Frame_Input :: struct {
	mouse_pos:        [2]f32,
	framebuffer_size: [2]f32,
	scroll_delta:     [2]f32,
	mouse_pressed:    bool,
	mouse_clicked:    bool,
	camera_dtranslate:[2]f32,
	camera_dzoom:     f32,
	delta:            f32,
}

Frame_Output :: struct {
	camera:              Camera,
	board_draw_commands: []Draw_Command,
	ui_draw_commands:    []Draw_Command,
}

Scene_State :: struct {
	initialized: bool,
	camera:      Camera,
}

APP: Platform_State
SCENE: Scene_State

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	_ = window
	gl.Viewport(0, 0, cast(i32)width, cast(i32)height)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	_ = window
	_ = scancode
	_ = mods

	if key < 0 || key > glfw.KEY_LAST {
		return
	}

	switch action {
	case glfw.PRESS:
		APP.keys_down_now[key] = true
	case glfw.RELEASE:
		APP.keys_down_now[key] = false
	}
}

mouse_btn_callback :: proc "c" (window: glfw.WindowHandle, btn, action, mods: c.int) {
	_ = window
	_ = mods

	if btn < 0 || btn > glfw.MOUSE_BUTTON_LAST {
		return
	}

	switch action {
	case glfw.PRESS:
		APP.mouse_button_down_now[btn] = true
	case glfw.RELEASE:
		APP.mouse_button_down_now[btn] = false
	}
}

cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x: f64, y: f64) {
	_ = window
	APP.mouse_pos = {x, y}
}

scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	_ = window
	APP.scroll_delta += {xoffset, yoffset}
}

framebuffer_size :: proc(window: glfw.WindowHandle) -> [2]f32 {
	width, height := glfw.GetFramebufferSize(window)
	return {f32(width), f32(height)}
}

start_frame :: proc() {
	APP.keys_down_prev = APP.keys_down_now
	APP.mouse_button_down_prev = APP.mouse_button_down_now
	APP.scroll_delta = {}
	glfw.PollEvents()
}

end_frame :: proc(window: glfw.WindowHandle) {
	glfw.SwapBuffers(window)
}

is_key_down :: proc(key: int) -> bool {
	return key >= 0 && key <= glfw.KEY_LAST && APP.keys_down_now[key]
}

is_key_pressed :: proc(key: int) -> bool {
	return key >= 0 && key <= glfw.KEY_LAST && APP.keys_down_now[key] && !APP.keys_down_prev[key]
}

is_mouse_button_down :: proc(button: int) -> bool {
	return button >= 0 && button <= glfw.MOUSE_BUTTON_LAST && APP.mouse_button_down_now[button]
}

is_mouse_button_pressed :: proc(button: int) -> bool {
	return button >= 0 && button <= glfw.MOUSE_BUTTON_LAST && APP.mouse_button_down_now[button] && !APP.mouse_button_down_prev[button]
}

camera_center_on :: proc(camera: ^Camera, pos, fb_size: [2]f32) {
	screen_per_world_px := camera_screen_per_world_px(camera^)
	camera.center[0] = pos[0] - fb_size[0]*0.5/screen_per_world_px
	camera.center[1] = pos[1] - fb_size[1]*0.5/screen_per_world_px
}

camera_update :: proc(camera: ^Camera, dtranslate: [2]f32, dzoom: f32, fb_size: [2]f32) {
	if camera.world_to_px <= 0 {
		camera.world_to_px = 1
	}
	if camera.zoom <= 0 {
		camera.zoom = 1
	}

	screen_per_world_px := camera_screen_per_world_px(camera^)
	camera.center += dtranslate / screen_per_world_px

	view_center := fb_size * 0.5
	world_center := camera_screen_to_world_pos(camera^, view_center, fb_size)
	camera.zoom *= 1 + dzoom
	if camera.zoom < 0.1 {
		camera.zoom = 0.1
	}
	camera_center_on(camera, world_center, fb_size)
}

build_frame_input :: proc(window: glfw.WindowHandle, delta: f32) -> Frame_Input {
	input := Frame_Input{
		mouse_pos = {f32(APP.mouse_pos[0]), f32(APP.mouse_pos[1])},
		framebuffer_size = framebuffer_size(window),
		scroll_delta = {f32(APP.scroll_delta[0]), f32(APP.scroll_delta[1])},
		mouse_pressed = is_mouse_button_down(glfw.MOUSE_BUTTON_LEFT),
		mouse_clicked = is_mouse_button_pressed(glfw.MOUSE_BUTTON_LEFT),
		delta = delta,
	}

	Action :: struct {
		key: int,
		dv:  [2]f32,
		dz:  f32,
	}

	actions := [?]Action{
		{glfw.KEY_A, {-1, 0}, 0},
		{glfw.KEY_D, {1, 0}, 0},
		{glfw.KEY_W, {0, -1}, 0},
		{glfw.KEY_S, {0, 1}, 0},
		{glfw.KEY_Q, {0, 0}, 1},
		{glfw.KEY_E, {0, 0}, -1},
	}

	tran_speed := delta * 200.0
	zoom_speed := delta
	if is_key_down(glfw.KEY_LEFT_SHIFT) {
		tran_speed *= 2
		zoom_speed *= 2
	}

	for action in actions {
		if is_key_down(action.key) {
			input.camera_dtranslate += action.dv * tran_speed
			input.camera_dzoom += action.dz * zoom_speed
		}
	}

	return input
}

update_and_render :: proc(input: Frame_Input, allocator: mem.Allocator) -> Frame_Output {
	if !SCENE.initialized {
		SCENE.camera.world_to_px = 10
		SCENE.camera.zoom = 4
		camera_center_on(&SCENE.camera, {300, 250}, input.framebuffer_size)
		SCENE.initialized = true
	}

	camera_update(&SCENE.camera, input.camera_dtranslate, input.camera_dzoom, input.framebuffer_size)

	board_draw_commands := make([dynamic]Draw_Command, 0, 4, allocator) or_else panic("failed to allocate board commands")

	append_or_panic(&board_draw_commands, Draw_Command{
		bounds = Rect{300, 250, 1, 1},
		texture = Draw_Texture{
			fill = color_rect_uniform(WHITE),
			name = "soldier",
			intensity = 1,
			mapping = .Stretch,
		},
	})

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

	ui_draw_commands := ui_end_frame(allocator)

	return Frame_Output{
		camera = SCENE.camera,
		board_draw_commands = board_draw_commands[:],
		ui_draw_commands = ui_draw_commands[:],
	}
}

main :: proc() {
	if !glfw.Init() {
		description, code := glfw.GetError()
		fmt.eprintf("failed to initialize GLFW (%d): %s\n", code, description)
		return
	}
	defer glfw.Terminate()

	glfw.DefaultWindowHints()
	glfw.WindowHint(glfw.CLIENT_API, glfw.OPENGL_API)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, OPENGL_MAJOR)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, OPENGL_MINOR)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	when ODIN_OS == .Darwin {
		glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true)
	}

	window := glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE, nil, nil)
	if window == nil {
		description, code := glfw.GetError()
		fmt.eprintf("failed to create GLFW window (%d): %s\n", code, description)
		return
	}
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	glfw.SwapInterval(1)
	glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)
	glfw.SetKeyCallback(window, key_callback)
	glfw.SetMouseButtonCallback(window, mouse_btn_callback)
	glfw.SetCursorPosCallback(window, cursor_pos_callback)
	glfw.SetScrollCallback(window, scroll_callback)

	gl.load_up_to(OPENGL_MAJOR, OPENGL_MINOR, glfw.gl_set_proc_address)

	fb_size := framebuffer_size(window)
	gl.Viewport(0, 0, cast(i32)fb_size[0], cast(i32)fb_size[1])
	fmt.printf("OpenGL %s\n", string(gl.GetString(gl.VERSION)))

	init()
	ui_init()
	widget_texture := load_texture_from_file("assets/widget.png", .Linear)
	push_sprite("widget", widget_texture, Rect{0, 0, widget_texture.size[0], widget_texture.size[1]})

	last_time := f32(glfw.GetTime())
	for !glfw.WindowShouldClose(window) {
		new_time := f32(glfw.GetTime())
		delta := new_time - last_time
		last_time = new_time

		start_frame()
		if is_key_pressed(glfw.KEY_ESCAPE) {
			glfw.SetWindowShouldClose(window, true)
		}

		gl.ClearColor(0.10, 0.20, 0.30, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		fb_size = framebuffer_size(window)
		gl.Viewport(0, 0, cast(i32)fb_size[0], cast(i32)fb_size[1])

		frame := get_scratch()
		input := build_frame_input(window, delta)
		output := update_and_render(input, frame.arena)

		draw_terrain(output.camera, fb_size)
		draw_commands(output.board_draw_commands, output.camera, fb_size)
		draw_commands(output.ui_draw_commands, Camera{}, fb_size)
		release_scratch(frame)

		end_frame(window)
	}
}
