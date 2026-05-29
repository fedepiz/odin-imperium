package main

import "core:c"
import "core:fmt"
import gl "vendor:OpenGL"
import "vendor:glfw"

WINDOW_TITLE :: "imperium"
WINDOW_WIDTH :: 1600
WINDOW_HEIGHT :: 900
OPENGL_MAJOR :: 3
OPENGL_MINOR :: 3

APP: struct {
	mouse_pos:              [2]f64,
	keys_down_now:          [glfw.KEY_LAST]bool,
	keys_down_prev:         [glfw.KEY_LAST]bool,
	mouse_button_down_now:  [glfw.MOUSE_BUTTON_LAST]bool,
	mouse_button_down_prev: [glfw.MOUSE_BUTTON_LAST]bool,
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	_ = window
	gl.Viewport(0, 0, cast(i32)width, cast(i32)height)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	APP.keys_down_now[key] = action == glfw.PRESS
}

mouse_btn_callback :: proc "c" (window: glfw.WindowHandle, btn, action, mods: c.int) {
	_ = mods

	APP.mouse_button_down_now[btn] = action == glfw.PRESS
}

cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x: f64, y: f64) {
	APP.mouse_pos = {x, y}
}

is_key_pressed :: proc(key: int) -> bool {
	return APP.keys_down_now[key] && !APP.keys_down_prev[key]
}

is_mouse_button_pressed :: proc(button: int) -> bool {
	return APP.mouse_button_down_now[button] && !APP.mouse_button_down_prev[button]
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

	gl.load_up_to(OPENGL_MAJOR, OPENGL_MINOR, glfw.gl_set_proc_address)

	framebuffer_width, framebuffer_height := glfw.GetFramebufferSize(window)
	gl.Viewport(0, 0, cast(i32)framebuffer_width, cast(i32)framebuffer_height)

	fmt.printf("OpenGL %s\n", string(gl.GetString(gl.VERSION)))

	for !glfw.WindowShouldClose(window) {
		if is_key_pressed(glfw.KEY_ESCAPE) {
			glfw.SetWindowShouldClose(window, true)
		}


		gl.ClearColor(0.08, 0.10, 0.14, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		glfw.SwapBuffers(window)
		glfw.PollEvents()
	}
}

