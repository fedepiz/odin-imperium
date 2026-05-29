package main

import "core:mem"

UI_MAX_WIDGETS :: 1024
UI_NIL_KEY     :: u64(0)
UI_AXIS_COUNT  :: 2

ui_Axis :: enum int {
	X = 0,
	Y = 1,
	Count = 2,
}

ui_flip_axis :: proc(axis: ui_Axis) -> ui_Axis {
	return ui_Axis(1 - int(axis))
}

ui_Text_Layout :: enum int {
	Left,
	Center,
	Wrap,
}

ui_Signal :: struct {
	hovered: bool,
	clicked: bool,
	held:    bool,
	scroll:  [2]f32,
	drag:    [2]f32,
}

ui_Style_Var :: enum int {
	Fill_Cold,
	Fill_Hover,
	Fill_Held,
	Item_Border,
	Panel_Fill,
	Panel_Border,
	Unit,
	Text_Size,
	Text_Color,
	Heading_Size,
	Thickness,
	Count,
}

ui_Size_Kind :: enum int {
	Pixels,
	Children_Sum,
	Children_Max,
}

ui_Logical_Size :: struct {
	kind:  ui_Size_Kind,
	value: f32,
}

ui_Widget_Text :: struct {
	string:       string,
	color:        Color,
	pixel_height: f32,
	layout:       ui_Text_Layout,
}

ui_Widget_Key :: u64

ui_Widget :: struct {
	logical_size:      [UI_AXIS_COUNT]ui_Logical_Size,
	layout_axes:       [UI_AXIS_COUNT]f32,
	center_axis:       [UI_AXIS_COUNT]f32,
	absolute_pos:      [UI_AXIS_COUNT]f32,
	child_offset:      [UI_AXIS_COUNT]f32,
	parent:            ^ui_Widget,
	first_child:       ^ui_Widget,
	last_child:        ^ui_Widget,
	sibling:           ^ui_Widget,
	fill:              Color,
	border:            Color,
	relief:            f32,
	thickness:         f32,
	corner_radius:     f32,
	text:              ui_Widget_Text,
	texture_name:      string,
	texture_intensity: f32,
	computed_size:     [UI_AXIS_COUNT]f32,
	computed_pos:      [UI_AXIS_COUNT]f32,
	computed_clip:     Rect,
	clip_to_bounds:    bool,
	key:               ui_Widget_Key,
}

ui_Widget_Cache_Entry :: struct {
	key:          ui_Widget_Key,
	content_size: [2]f32,
}

ui_Style_Value :: struct {
	color:  Color,
	number: f32,
	next:   ^ui_Style_Value,
}

ui_Style :: struct {
	stack_tops: [int(ui_Style_Var.Count)]^ui_Style_Value,
}

ui_Scroll_State :: struct {
	scroll:            f32,
	out_percent_begin: f32,
	out_percent_end:   f32,
}

ui_Context :: struct {
	widgets:            [UI_MAX_WIDGETS]ui_Widget,
	widget_count:       int,
	active_widget:      ^ui_Widget,
	style:              ui_Style,
	hovered:            ui_Widget_Key,
	clicked:            ui_Widget_Key,
	held:               ui_Widget_Key,
	dragged:            ui_Widget_Key,
	under_mouse:        [UI_MAX_WIDGETS]ui_Widget_Key,
	under_mouse_count:  int,
	has_mouse_over_area:bool,
	scroll_delta:       [2]f32,
	mouse_delta:        [2]f32,
	old_mouse_pos:      [2]f32,
	widget_cache:       [UI_MAX_WIDGETS]ui_Widget_Cache_Entry,
	widget_cache_count: int,
}

UI: ui_Context

color_rgba :: proc(r, g, b, a: f32) -> Color {
	return {r, g, b, a}
}

color_rgba8 :: proc(r, g, b, a: u8) -> Color {
	return color_rgba(f32(r)/255, f32(g)/255, f32(b)/255, f32(a)/255)
}

color_mix :: proc(a, b: Color, t: f32) -> Color {
	return {
		r = a.r + (b.r-a.r)*t,
		g = a.g + (b.g-a.g)*t,
		b = a.b + (b.b-a.b)*t,
		a = a.a,
	}
}

color_rect_corners :: proc(c1, c2, c3, c4: Color) -> Color_Rect {
	return Color_Rect{corners = [4]Color{c1, c2, c3, c4}}
}

clamp01 :: proc(x: f32) -> f32 {
	return clamp(x, 0, 1)
}

color_rect_relief :: proc(base: Color, relief, light_strength, dark_strength: f32) -> Color_Rect {
	if relief == 0 {
		return color_rect_uniform(base)
	}

	amount := clamp01(abs(relief))
	light_amount := light_strength * amount
	dark_amount := dark_strength * amount
	light := color_mix(base, WHITE, light_amount)
	soft_light := color_mix(base, WHITE, light_amount*0.6)
	dark := color_mix(base, BLACK, dark_amount)
	soft_dark := color_mix(base, BLACK, dark_amount*0.6)

	if relief < 0 {
		return color_rect_corners(dark, soft_dark, light, soft_light)
	}
	return color_rect_corners(light, soft_light, dark, soft_dark)
}

rect_contains_point :: proc(rect: Rect, point: [2]f32) -> bool {
	return point[0] >= rect.x && point[1] >= rect.y && point[0] <= rect.x+rect.w && point[1] <= rect.y+rect.h
}

ui_rect_infinity :: proc() -> Rect {
	return {-1_000_000_000, -1_000_000_000, 2_000_000_000, 2_000_000_000}
}

ui_rect_intersection :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x+a.w, b.x+b.w)
	y1 := min(a.y+a.h, b.y+b.h)
	return {x0, y0, max(0, x1-x0), max(0, y1-y0)}
}

ui_widget_bounds :: proc(widget: ^ui_Widget) -> Rect {
	return {
		x = widget.computed_pos[int(ui_Axis.X)],
		y = widget.computed_pos[int(ui_Axis.Y)],
		w = max(widget.computed_size[int(ui_Axis.X)], 0),
		h = max(widget.computed_size[int(ui_Axis.Y)], 0),
	}
}

ui_v2_axis :: proc(v: [2]f32, axis: ui_Axis) -> f32 {
	return v[int(axis)]
}

ui_widget_key_from_text :: proc(text: string) -> ui_Widget_Key {
	key := ui_Widget_Key(0)
	for ch in text {
		key += key*13 + ui_Widget_Key(ch)*17
	}
	return key
}

ui_visible_text :: proc(text: string) -> string {
	for i := 0; i+1 < len(text); i += 1 {
		if text[i] == '#' && text[i+1] == '#' {
			return text[:i]
		}
	}
	return text
}

ui_default_color :: proc(v: ui_Style_Var) -> Color {
	#partial switch v {
	case .Fill_Cold:
		return color_rgba8(64, 74, 92, 255)
	case .Fill_Hover:
		return color_rgba8(84, 98, 122, 255)
	case .Fill_Held:
		return color_rgba8(47, 57, 74, 255)
	case .Item_Border:
		return color_rgba8(190, 198, 210, 255)
	case .Panel_Fill:
		return color_rgba8(28, 34, 45, 230)
	case .Panel_Border:
		return color_rgba8(120, 132, 150, 255)
	case .Text_Color:
		return WHITE
	}
	return TRANSPARENT
}

ui_default_number :: proc(v: ui_Style_Var) -> f32 {
	#partial switch v {
	case .Unit:
		return 24
	case .Text_Size:
		return 18
	case .Heading_Size:
		return 28
	case .Thickness:
		return 2
	}
	return 0
}

ui_style_color :: proc(v: ui_Style_Var) -> Color {
	value := UI.style.stack_tops[int(v)]
	if value != nil {
		return value.color
	}
	return ui_default_color(v)
}

ui_style_number :: proc(v: ui_Style_Var) -> f32 {
	value := UI.style.stack_tops[int(v)]
	if value != nil {
		return value.number
	}
	return ui_default_number(v)
}

ui_calculate_sizes :: proc() {
	for axis := 0; axis < UI_AXIS_COUNT; axis += 1 {
		for i := UI.widget_count - 1; i >= 0; i -= 1 {
			widget := &UI.widgets[i]
			size := f32(0)
			switch widget.logical_size[axis].kind {
			case .Pixels:
				size = widget.logical_size[axis].value
			case .Children_Sum:
				for child := widget.first_child; child != nil; child = child.sibling {
					size += child.computed_size[axis]
				}
			case .Children_Max:
				for child := widget.first_child; child != nil; child = child.sibling {
					size = max(size, child.computed_size[axis])
				}
			}
			widget.computed_size[axis] = size
		}
	}
}

ui_center_child_on_axis :: proc(parent, child: ^ui_Widget, axis: ui_Axis) -> f32 {
	difference := parent.computed_size[int(axis)] - child.computed_size[int(axis)]
	if difference < 0 {
		difference = 0
	}
	return difference * 0.5 * parent.center_axis[int(axis)]
}

ui_layout_recursive :: proc(widget: ^ui_Widget, cursor_x, cursor_y: f32, parent_clip: Rect) {
	x := cursor_x + widget.absolute_pos[int(ui_Axis.X)]
	y := cursor_y + widget.absolute_pos[int(ui_Axis.Y)]

	widget.computed_pos[int(ui_Axis.X)] = x
	widget.computed_pos[int(ui_Axis.Y)] = y

	clip := parent_clip
	if widget.clip_to_bounds {
		clip = ui_rect_intersection(clip, ui_widget_bounds(widget))
	}
	widget.computed_clip = clip

	x -= widget.child_offset[int(ui_Axis.X)]
	y -= widget.child_offset[int(ui_Axis.Y)]

	for child := widget.first_child; child != nil; child = child.sibling {
		child_x := x + ui_center_child_on_axis(widget, child, .X)
		child_y := y + ui_center_child_on_axis(widget, child, .Y)
		ui_layout_recursive(child, child_x, child_y, clip)
		x += child.computed_size[int(ui_Axis.X)] * widget.layout_axes[int(ui_Axis.X)]
		y += child.computed_size[int(ui_Axis.Y)] * widget.layout_axes[int(ui_Axis.Y)]
	}
}

ui_layout_positions :: proc() {
	for i := 0; i < UI.widget_count; i += 1 {
		widget := &UI.widgets[i]
		if widget.parent == nil {
			ui_layout_recursive(widget, 0, 0, ui_rect_infinity())
		}
	}
}

ui_update_widget_cache :: proc() {
	UI.widget_cache_count = 0
	for i := 0; i < UI.widget_count; i += 1 {
		widget := &UI.widgets[i]
		if widget.key == UI_NIL_KEY || UI.widget_cache_count >= UI_MAX_WIDGETS {
			continue
		}

		content_size := [2]f32{}
		for child := widget.first_child; child != nil; child = child.sibling {
			if widget.layout_axes[int(ui_Axis.X)] > 0 {
				content_size[0] += child.computed_size[int(ui_Axis.X)]
			} else {
				content_size[0] = max(content_size[0], child.computed_size[int(ui_Axis.X)])
			}
			if widget.layout_axes[int(ui_Axis.Y)] > 0 {
				content_size[1] += child.computed_size[int(ui_Axis.Y)]
			} else {
				content_size[1] = max(content_size[1], child.computed_size[int(ui_Axis.Y)])
			}
		}

		entry := &UI.widget_cache[UI.widget_cache_count]
		UI.widget_cache_count += 1
		entry.key = widget.key
		entry.content_size = content_size
	}
}

ui_widget_cache_lookup :: proc(key: string) -> ui_Widget_Cache_Entry {
	id := ui_widget_key_from_text(key)
	for i := 0; i < UI.widget_cache_count; i += 1 {
		if UI.widget_cache[i].key == id {
			return UI.widget_cache[i]
		}
	}
	return {}
}

ui_text_alignment :: proc(layout: ui_Text_Layout) -> Draw_Text_Alignment {
	switch layout {
	case .Left:
		return .Left
	case .Center:
		return .Center
	case .Wrap:
		return .Top_Left
	}
	return .Left
}

ui_text_wrapping :: proc(layout: ui_Text_Layout) -> Draw_Text_Wrapping {
	if layout == .Wrap {
		return .Wrap
	}
	return .Truncate
}

ui_draw_command_from_widget :: proc(widget: ^ui_Widget) -> Draw_Command {
	command: Draw_Command
	command.bounds = ui_widget_bounds(widget)
	command.clip = widget.computed_clip
	command.texture.fill = color_rect_relief(widget.fill, widget.relief, 0.45, 0.55)
	command.texture.name = widget.texture_name
	command.texture.intensity = widget.texture_intensity
	command.texture.mapping = .Tile
	command.border.color = color_rect_relief(widget.border, widget.relief, 0.45, 0.55)
	command.border.thickness = widget.thickness
	command.border.corner_radius = widget.corner_radius
	command.text.text = widget.text.string
	command.text.color = widget.text.color
	command.text.pixel_height = widget.text.pixel_height
	command.text.alignment = ui_text_alignment(widget.text.layout)
	command.text.wrapping = ui_text_wrapping(widget.text.layout)
	return command
}

ui_emit_draw_commands_recursive :: proc(commands: ^[dynamic]Draw_Command, widget: ^ui_Widget) {
	append_or_panic(commands, ui_draw_command_from_widget(widget))
	for child := widget.first_child; child != nil; child = child.sibling {
		ui_emit_draw_commands_recursive(commands, child)
	}
}

ui_init :: proc() {
	UI = {}
}

ui_is_mouse_over_area :: proc() -> bool {
	return UI.has_mouse_over_area
}

ui_begin_frame :: proc(input: Frame_Input) {
	hovered := ui_Widget_Key(UI_NIL_KEY)
	UI.under_mouse_count = 0
	UI.has_mouse_over_area = false

	for idx := UI.widget_count - 1; idx >= 0; idx -= 1 {
		widget := &UI.widgets[idx]
		hit_bounds := ui_rect_intersection(ui_widget_bounds(widget), widget.computed_clip)
		if !rect_contains_point(hit_bounds, input.mouse_pos) {
			continue
		}

		UI.has_mouse_over_area = true
		if widget.key == UI_NIL_KEY {
			continue
		}
		if UI.under_mouse_count < UI_MAX_WIDGETS {
			UI.under_mouse[UI.under_mouse_count] = widget.key
			UI.under_mouse_count += 1
		}
		if hovered == UI_NIL_KEY {
			hovered = widget.key
		}
	}

	if !input.mouse_pressed {
		UI.dragged = UI_NIL_KEY
	} else if UI.dragged == UI_NIL_KEY {
		UI.dragged = UI.hovered
	}
	if UI.dragged != UI_NIL_KEY {
		hovered = UI.dragged
	}

	UI.hovered = hovered
	if input.mouse_clicked {
		UI.clicked = hovered
	} else {
		UI.clicked = UI_NIL_KEY
	}
	if input.mouse_pressed {
		UI.held = hovered
	} else {
		UI.held = UI_NIL_KEY
	}
	UI.scroll_delta = input.scroll_delta
	UI.mouse_delta = input.mouse_pos - UI.old_mouse_pos
	UI.old_mouse_pos = input.mouse_pos

	UI.widget_count = 0
	UI.active_widget = nil
}

ui_end_frame :: proc(allocator: mem.Allocator) -> []Draw_Command {
	ui_calculate_sizes()
	ui_update_widget_cache()
	ui_layout_positions()

	commands := make([dynamic]Draw_Command, 0, UI.widget_count, allocator) or_else panic("failed to allocate ui draw commands")
	for i := 0; i < UI.widget_count; i += 1 {
		widget := &UI.widgets[i]
		if widget.parent == nil {
			ui_emit_draw_commands_recursive(&commands, widget)
		}
	}

	UI.style = {}
	return commands[:]
}

ui_widget_begin :: proc() {
	if UI.widget_count >= UI_MAX_WIDGETS {
		return
	}
	widget := &UI.widgets[UI.widget_count]
	UI.widget_count += 1
	widget^ = {}
	if UI.active_widget != nil {
		widget.parent = UI.active_widget
	}
	UI.active_widget = widget
}

ui_widget_end :: proc() {
	widget := UI.active_widget
	if widget == nil {
		return
	}

	parent := widget.parent
	if parent != nil {
		if parent.last_child != nil {
			parent.last_child.sibling = widget
		} else {
			parent.first_child = widget
		}
		parent.last_child = widget
	}
	UI.active_widget = parent
}

ui_set_layout_axis :: proc(axis: ui_Axis) {
	if UI.active_widget == nil {
		return
	}
	UI.active_widget.layout_axes[int(axis)] = 1
	UI.active_widget.layout_axes[int(ui_flip_axis(axis))] = 0
}

ui_set_centering_axis :: proc(axis: ui_Axis) {
	if UI.active_widget == nil {
		return
	}
	UI.active_widget.center_axis[int(axis)] = 1
	UI.active_widget.center_axis[int(ui_flip_axis(axis))] = 0
}

ui_children_sized :: proc() {
	if UI.active_widget == nil {
		return
	}
	for axis := 0; axis < UI_AXIS_COUNT; axis += 1 {
		if UI.active_widget.layout_axes[axis] > 0 {
			UI.active_widget.logical_size[axis].kind = .Children_Sum
		} else {
			UI.active_widget.logical_size[axis].kind = .Children_Max
		}
	}
}

ui_set_pixel_size :: proc(w, h: f32) {
	ui_set_pixel_size_for_axis(.X, w)
	ui_set_pixel_size_for_axis(.Y, h)
}

ui_set_pixel_size_for_axis :: proc(axis: ui_Axis, size: f32) {
	if UI.active_widget == nil {
		return
	}
	UI.active_widget.logical_size[int(axis)].kind = .Pixels
	UI.active_widget.logical_size[int(axis)].value = size
}

ui_set_absolute_offset :: proc(x, y: f32) {
	if UI.active_widget == nil {
		return
	}
	UI.active_widget.absolute_pos = {x, y}
}

ui_set_child_offset :: proc(x, y: f32) {
	if UI.active_widget == nil {
		return
	}
	UI.active_widget.child_offset = {x, y}
}

ui_clip_to_bounds :: proc() {
	if UI.active_widget != nil {
		UI.active_widget.clip_to_bounds = true
	}
}

ui_set_fill :: proc(color: Color) {
	if UI.active_widget != nil {
		UI.active_widget.fill = color
	}
}

ui_set_relief :: proc(relief: f32) {
	if UI.active_widget != nil {
		UI.active_widget.relief = relief
	}
}

ui_set_border :: proc(color: Color, thickness, corner_radius: f32) {
	if UI.active_widget == nil {
		return
	}
	UI.active_widget.border = color
	UI.active_widget.thickness = thickness
	UI.active_widget.corner_radius = corner_radius
}

ui_set_text :: proc(text: string, pixel_height: f32, layout: ui_Text_Layout) {
	if UI.active_widget == nil {
		return
	}
	UI.active_widget.text.string = ui_visible_text(text)
	UI.active_widget.text.color = ui_style_color(.Text_Color)
	UI.active_widget.text.pixel_height = pixel_height
	UI.active_widget.text.layout = layout
}

ui_set_texture :: proc(name: string, intensity: f32) {
	if UI.active_widget == nil {
		return
	}
	UI.active_widget.texture_name = name
	UI.active_widget.texture_intensity = intensity
}

ui_widget_key_is_under_mouse :: proc(key: ui_Widget_Key) -> bool {
	for i := 0; i < UI.under_mouse_count; i += 1 {
		if UI.under_mouse[i] == key {
			return true
		}
	}
	return false
}

ui_set_key :: proc(text: string) -> ui_Signal {
	out: ui_Signal
	if UI.active_widget == nil {
		return out
	}

	key := ui_widget_key_from_text(text)
	UI.active_widget.key = key
	out.hovered = UI.hovered == key
	out.clicked = UI.clicked == key
	out.held = UI.held == key
	if ui_widget_key_is_under_mouse(key) {
		out.scroll = UI.scroll_delta
	}
	if UI.dragged == key {
		out.drag = UI.mouse_delta
	}
	return out
}

ui_style_pop :: proc(v: ui_Style_Var) {
	value := UI.style.stack_tops[int(v)]
	if value != nil {
		UI.style.stack_tops[int(v)] = value.next
	}
}

ui_style_push_number :: proc(allocator: mem.Allocator, v: ui_Style_Var, number: f32) {
	value := new(ui_Style_Value, allocator) or_else panic("failed to allocate ui style value")
	value.number = number
	value.next = UI.style.stack_tops[int(v)]
	UI.style.stack_tops[int(v)] = value
}

ui_style_push_color :: proc(allocator: mem.Allocator, v: ui_Style_Var, color: Color) {
	value := new(ui_Style_Value, allocator) or_else panic("failed to allocate ui style value")
	value.color = color
	value.next = UI.style.stack_tops[int(v)]
	UI.style.stack_tops[int(v)] = value
}

ui_box_begin :: proc(axis: ui_Axis, center: bool) {
	ui_widget_begin()
	ui_set_layout_axis(axis)
	if center {
		ui_set_centering_axis(ui_flip_axis(axis))
	}
	ui_children_sized()
}

ui_row_begin :: proc() {
	ui_box_begin(.X, false)
}

ui_col_begin :: proc() {
	ui_box_begin(.Y, false)
}

ui_space :: proc(width, height: f32) {
	ui_widget_begin()
	unit := ui_style_number(.Unit)
	ui_set_pixel_size(width*unit, height*unit)
	ui_widget_end()
}

ui_vsep :: proc() {
	ui_space(0, 1)
}

ui_hsep :: proc() {
	ui_space(1, 0)
}

ui_heading :: proc(text: string, width: f32) {
	ui_widget_begin()
	unit := ui_style_number(.Unit)
	ui_set_pixel_size(width*unit, 2*unit)
	ui_set_text(text, ui_style_number(.Heading_Size), .Center)
	ui_widget_end()
}

ui_label :: proc(text: string, width: f32) {
	ui_widget_begin()
	unit := ui_style_number(.Unit)
	ui_set_pixel_size(width*unit, 2*unit)
	ui_set_text(text, ui_style_number(.Text_Size), .Center)
	ui_widget_end()
}

ui_line :: proc(text: string, width: f32) {
	ui_widget_begin()
	unit := ui_style_number(.Unit)
	ui_set_pixel_size(width*unit, 2*unit)
	ui_set_text(text, ui_style_number(.Text_Size), .Left)
	ui_widget_end()
}

ui_multiline :: proc(text: string, width, height: f32) {
	ui_widget_begin()
	unit := ui_style_number(.Unit)
	ui_set_pixel_size(width*unit, height*unit)
	ui_set_text(text, ui_style_number(.Text_Size), .Wrap)
	ui_widget_end()
}

ui_button_generic :: proc(text: string, width, height: f32) -> bool {
	ui_widget_begin()
	signal := ui_set_key(text)

	unit := ui_style_number(.Unit)
	height_px := height * unit
	ui_set_pixel_size(width*unit, height_px)

	color_var := ui_Style_Var.Fill_Cold
	if signal.held {
		color_var = .Fill_Held
	} else if signal.hovered {
		color_var = .Fill_Hover
	}

	ui_set_fill(ui_style_color(color_var))
	ui_set_border(ui_style_color(.Item_Border), ui_style_number(.Thickness), height_px*0.2)
	ui_set_relief(1)
	if signal.held {
		ui_set_relief(-1)
	}
	ui_set_text(text, ui_style_number(.Text_Size), .Center)
	ui_widget_end()
	return signal.clicked
}

ui_button :: proc(text: string, width: f32) -> bool {
	return ui_button_generic(text, width, 2)
}

ui_button_slim :: proc(text: string, width: f32) -> bool {
	return ui_button_generic(text, width, 1.5)
}

ui_toggle :: proc(key: string, value: bool, width, height: f32) -> bool {
	new_value := value
	unit := ui_style_number(.Unit)
	height_px := height * unit

	ui_widget_begin()
	signal := ui_set_key(key)
	ui_set_pixel_size(width*unit, height_px)
	ui_set_border(ui_style_color(.Item_Border), ui_style_number(.Thickness)*0.5, height_px*0.05)

	fill := ui_style_color(.Fill_Held)
	if new_value {
		ui_set_fill(fill)
	} else if signal.hovered {
		fill.a = 0.5
		ui_set_fill(fill)
	}

	if signal.clicked {
		new_value = !new_value
	}
	ui_widget_end()
	return new_value
}

ui_take_space :: proc(desired: f32, available: ^f32) -> f32 {
	taken := min(desired, available^)
	available^ -= taken
	return taken
}

ui_check_box :: proc(text: string, width: f32, value: bool) -> bool {
	available := width
	space1 := ui_take_space(0.5, &available)
	box_size := ui_take_space(1.0, &available)
	space2 := ui_take_space(0.5, &available)
	space3 := ui_take_space(0.5, &available)
	text_width := available
	unit := ui_style_number(.Unit)
	height_px := 2 * unit
	new_value := value

	ui_box_begin(.X, true)
	ui_set_fill(ui_style_color(.Fill_Cold))
	ui_set_relief(1)
	ui_set_border(ui_style_color(.Item_Border), ui_style_number(.Thickness), height_px*0.2)
	ui_space(space1, 0)
	new_value = ui_toggle(text, new_value, box_size, 1)
	ui_space(space2, 0)
	ui_widget_begin()
	ui_set_pixel_size(text_width*unit, height_px)
	ui_set_text(text, ui_style_number(.Text_Size), .Left)
	ui_widget_end()
	ui_space(space3, 0)
	ui_widget_end()
	return new_value
}

ui_panel_begin :: proc(id: string, pos: [2]f32) -> ui_Signal {
	ui_box_begin(.Y, false)
	signal := ui_set_key(id)
	ui_set_absolute_offset(pos[0], pos[1])
	ui_set_fill(ui_style_color(.Panel_Fill))
	ui_set_border(ui_style_color(.Panel_Border), ui_style_number(.Thickness), 0)
	return signal
}

ui_scroll_state_from_scroll :: proc(scroll: f32) -> ui_Scroll_State {
	return ui_Scroll_State{scroll = scroll}
}

ui_scroll_area_begin :: proc(id: string, width, height: f32, state: ^ui_Scroll_State) {
	ui_widget_begin()
	signal := ui_set_key(id)
	unit := ui_style_number(.Unit)
	width_px := width * unit
	height_px := height * unit
	ui_set_pixel_size(width_px, height_px)
	ui_set_layout_axis(.Y)
	ui_clip_to_bounds()

	if state != nil {
		cached := ui_widget_cache_lookup(id)
		state.scroll -= signal.scroll[1] * unit
		overflow := max(cached.content_size[1]-height_px, 0)
		state.scroll = clamp(state.scroll, 0, overflow)
		ui_set_child_offset(0, state.scroll)

		if cached.content_size[1] > 0 && overflow > 0 {
			state.out_percent_begin = state.scroll / cached.content_size[1]
			state.out_percent_end = (state.scroll + height_px) / cached.content_size[1]
		} else {
			state.out_percent_begin = 0
			state.out_percent_end = 1
		}
	}
}

ui_v_scroll_bar :: proc(width, height, percent_start, percent_end: f32) {
	start := clamp01(percent_start)
	end := clamp01(percent_end)
	start = min(start, end)

	unit := ui_style_number(.Unit)
	width_px := width * unit
	height_px := height * unit
	thumb_y := start * height_px
	thumb_h := max((end-start)*height_px, 0)

	ui_widget_begin()
	ui_set_pixel_size(width_px, height_px)
	ui_set_border(ui_style_color(.Item_Border), ui_style_number(.Thickness)*0.5, width_px*0.5)

	ui_widget_begin()
	ui_set_pixel_size(width_px, thumb_h)
	ui_set_absolute_offset(0, thumb_y)
	ui_set_fill(ui_style_color(.Fill_Held))
	ui_set_border(ui_style_color(.Item_Border), ui_style_number(.Thickness)*0.25, width_px*0.5)
	ui_widget_end()

	ui_widget_end()
}
