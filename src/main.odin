package main

import "core:c"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
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

APP: Platform_State

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
	return(
		button >= 0 &&
		button <= glfw.MOUSE_BUTTON_LAST &&
		APP.mouse_button_down_now[button] &&
		!APP.mouse_button_down_prev[button] \
	)
}

build_frame_input :: proc(window: glfw.WindowHandle, delta: f32) -> Frame_Input {
	input := Frame_Input {
		mouse_pos        = {f32(APP.mouse_pos[0]), f32(APP.mouse_pos[1])},
		framebuffer_size = framebuffer_size(window),
		scroll_delta     = {f32(APP.scroll_delta[0]), f32(APP.scroll_delta[1])},
		mouse_pressed    = is_mouse_button_down(glfw.MOUSE_BUTTON_LEFT),
		mouse_clicked    = is_mouse_button_pressed(glfw.MOUSE_BUTTON_LEFT),
		delta            = delta,
	}

	Action :: struct {
		key: int,
		dv:  [2]f32,
		dz:  f32,
	}

	actions := [?]Action {
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
			input.camera.dtranslate += action.dv * tran_speed
			input.camera.dzoom += action.dz * zoom_speed
		}
	}

	return input
}

main :: proc() {
	persistent_arena: vmem.Arena
	arena_err := vmem.arena_init_growing(&persistent_arena, 8 * mem.Megabyte)
	if arena_err != nil {
		fmt.eprintf("failed to initialize persistent arena: %v\n", arena_err)
		return
	}
	defer vmem.arena_destroy(&persistent_arena)
	persistent_allocator := vmem.arena_allocator(&persistent_arena)

	context.allocator = mem.nil_allocator()
	context.temp_allocator = mem.nil_allocator()

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

	init(persistent_allocator)

	widget_texture := load_texture_from_file("assets/widget.png", .Linear)
	push_sprite(
		"widget",
		widget_texture,
		Rect{0, 0, widget_texture.size[0], widget_texture.size[1]},
	)

	last_time := f32(glfw.GetTime())
	fps_accum_time: f32
	fps_accum_frames: int
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
		output := update_and_render(frame.arena, input)

		draw_terrain(output.camera, fb_size)
		draw_commands(output.board_draw_commands, output.camera, fb_size)
		draw_commands(output.ui_draw_commands, Camera{}, fb_size)
		release_scratch(frame)

		{
			fps_accum_time += delta
			fps_accum_frames += 1
			if fps_accum_time >= 5 {
				fmt.printf("Average FPS: %.1f\n", f32(fps_accum_frames) / fps_accum_time)
				fps_accum_time = 0
				fps_accum_frames = 0
			}
		}

		end_frame(window)
	}
}

