package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

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
	Tag,
	Name,
	Sprite,
}

LABEL_NAMES := [Label]string {
	.Tag    = "Tag",
	.Name   = "Name",
	.Sprite = "Sprite",
}

Var :: enum {
	Pos_X,
	Pos_Y,
	Size,
}

VAR_NAMES := [Var]string {
	.Pos_X = "Pos_X",
	.Pos_Y = "Pos_Y",
	.Size  = "Size",
}

Flag :: enum {
	IsDebug,
}

FLAG_NAMES := [Flag]string {
	.IsDebug = "IsDebug",
}

Vars :: [Var]f32

Thing :: struct {
	id:              ThId,
	labels:          [Label]string,
	vars:            Vars,
	flags:           bit_set[Flag],
	movement_target: ThId,
}

Things :: struct {
	blob:    [THINGS_BLOB_SIZE]byte,
	entries: [NUM_THINGS]Thing,
}

Tick_Ctx :: struct {
	tick_num:    u64,
	alloc:       mem.Allocator,
	old_things:  []Thing,
	new_things:  []Thing,
	selected_id: ThId,
	camera:      Camera,
	world_graph: World_Graph,
}

Tick_Output :: struct {
	draw_commands: []Draw_Command,
	click_boxes:   []Click_Box,
}

get_thing :: proc(ctx: Tick_Ctx, id: ThId) -> ^Thing {
	if thid_is_valid(id) {
		parts := thid_parts(id)
		thing := &ctx.old_things[parts.ix]
		if thing.id == id {return thing}
	}
	return &ctx.old_things[0]
}

world_graph_cell_of_thing :: proc(ctx: Tick_Ctx, id: ThId) -> World_Cell_Id {
	vars := get_thing(ctx, id).vars
	pos: [2]int = {int(math.round(vars[.Pos_X])), int(math.round(vars[.Pos_Y]))}
	return world_graph_pos_to_id(ctx.world_graph, pos)
}

lerp :: proc(a: f32, b: f32, t: f32) -> f32 {
	t := clamp01(t)
	return a + (b - a) * t
}
lerp2 :: proc(a: [2]f32, b: [2]f32, t: f32) -> [2]f32 {
	t := clamp01(t)
	return a + (b - a) * t
}

magnitude :: proc(v: [2]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

calculate_next_position :: proc(current: [2]f32, destination: [2]f32, speed: f32) -> [2]f32 {
	speed := speed * 0.01
	if current == destination || speed <= 0 {return current}
	displacement := destination - current
	dist := magnitude(displacement)
	if speed >= dist {return destination}
	change := (displacement / dist) * speed
	return current + change
}

things_tick :: proc(arena: mem.Allocator, ctx: Tick_Ctx) -> Tick_Output {
	scratch := get_scratch(arena)
	defer release_scratch(scratch)

	// "Write pass"
	num_visible := 0
	num_labels := 0
	for ix in 1 ..< NUM_THINGS {
		old := ctx.old_things[ix]
		new := &ctx.new_things[ix]

		new.id = old.id

		// Assume most lables are copied most of the time
		for label in Label {
			new.labels[label] = strings.clone(old.labels[label], ctx.alloc)
		}
		new.vars = old.vars
		new.flags = old.flags

		current_pos: [2]f32 = {new.vars[.Pos_X], new.vars[.Pos_Y]}
		move_to_pos: [2]f32 = current_pos

		{
			movement_target: ThId
			if old.vars[.Size] == 1 {
				// Target thid = 3
				movement_target = thid_make(3, 1)
			}

			if thid_is_valid(movement_target) {
				target := get_thing(ctx, movement_target)
				start_id := world_graph_cell_of_thing(ctx, new.id)
				end_id := world_graph_cell_of_thing(ctx, movement_target)
				if start_id == end_id {
					move_to_pos = {target.vars[.Pos_X], target.vars[.Pos_Y]}
				} else {
					path := world_graph_pathfind(scratch.arena, ctx.world_graph, start_id, end_id)
					if len(path) >= 2 {
						next_cell := path[1]
						move_to_pos = cast([2]f32)(world_graph_id_to_pos(
								ctx.world_graph,
								next_cell,
							))
					}
				}
			}

			new.movement_target = movement_target
		}

		if len(new.labels[.Name]) != 0 do num_labels += 1
		if new.vars[.Size] != 0 do num_visible += 1

		// Interpolate positions (temporary idea)
		{
			speed: f32 = new.vars[.Size] <= 1 ? 1 : 0
			if speed >= 0 {
				cell_id := world_graph_cell_of_thing(ctx, new.id)
				// Adjust speed by traversal speed.
				// Give a maximum penalty of 90%, to make sure we don't get stuck when 'clipping edges'
				speed *= max(ctx.world_graph.cells[cell_id].traverse_speed, 0.1)
			}
			next_pos := calculate_next_position(current_pos, move_to_pos, speed)
			new.vars[.Pos_X] = next_pos.x
			new.vars[.Pos_Y] = next_pos.y
		}
	}

	// Presentation
	draw_commands: [dynamic]Draw_Command = make(
		[dynamic]Draw_Command,
		0,
		num_visible + num_labels,
		arena,
	)
	click_boxes: [dynamic]Click_Box = make([dynamic]Click_Box, 0, num_visible, arena)

	for ix in 1 ..< NUM_THINGS {
		this := &ctx.new_things[ix]
		size := this.vars[.Size]
		pos_x := this.vars[.Pos_X] - size * 0.5
		pos_y := this.vars[.Pos_Y] - size * 0.5
		if size <= 0 || len(this.labels[.Sprite]) == 0 {continue}
		is_selected := this.id == ctx.selected_id

		{
			cmd: Draw_Command
			cmd.bounds = {pos_x, pos_y, size, size}
			cmd.texture.name = this.labels[.Sprite]
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

