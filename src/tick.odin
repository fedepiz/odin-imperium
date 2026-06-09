package main

import "core:math"
import "core:mem"
import "core:slice"
import "core:sort"

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
	Layer,
	VisionRadius,
}

VAR_NAMES := [Var]string {
	.Pos_X        = "Pos_X",
	.Pos_Y        = "Pos_Y",
	.Size         = "Size",
	.Layer        = "Layer",
	.VisionRadius = "VisionRadius",
}

Flag :: enum {
	IsPerson,
	IsFarmer,
	IsSettlement,
	IsFaction,
	IsPlayer,
	HasWalls,
	HasMarket,
	IsInside,
	IsDebug,
}

FLAG_NAMES := [Flag]string {
	.IsDebug      = "IsDebug",
	.IsPerson     = "IsPerson",
	.IsFarmer     = "IsFarmer",
	.IsSettlement = "IsSettlement",
	.IsPlayer     = "IsPlayer",
	.IsFaction    = "IsFaction",
	.HasWalls     = "HasWalls",
	.HasMarket    = "HasMarket",
	.IsInside     = "IsInside",
}

Vars :: [Var]f32

Relation :: enum {
	HomeOf,
	FactionOf,
	ContainerOf,
}

RELATION_NAMES := [Relation]string {
	.HomeOf      = "HomeOf",
	.FactionOf   = "FactionOf",
	.ContainerOf = "ContainerOf",
}

Relation_Type :: enum {
	Forward,
	Backward,
}

Reland :: struct {
	id:       ThId,
	relation: Relation,
	type:     Relation_Type,
}

Relations :: [dynamic]Reland

relation_get_one :: proc(
	thing: Thing,
	rel: Relation,
	typ: Relation_Type = .Forward,
) -> (
	ThId,
	bool,
) #optional_ok {
	for entry in thing.relations {
		if entry.relation == rel && entry.type == typ {
			return entry.id, true
		}
	}
	return {}, false
}

relation_extract :: proc(
	out: ^[dynamic]ThId,
	thing: Thing,
	rel: Relation,
	typ: Relation_Type = .Forward,
) {
	for entry in thing.relations {
		if entry.relation == rel && entry.type == typ {
			append(out, entry.id)
		}
	}
}

Thing :: struct {
	id:        ThId,
	labels:    [Label]string,
	vars:      Vars,
	flags:     bit_set[Flag],
	path:      Nav_Path,
	relations: Relations,
}

Nav_Path :: struct {
	steps: []World_Cell_Id,
}

Things :: struct {
	blob:    [THINGS_BLOB_SIZE]byte,
	entries: [NUM_THINGS]Thing,
}

Sim_Ctx :: struct {
	tick_num:    u64,
	alloc:       mem.Allocator,
	old_things:  []Thing,
	new_things:  []Thing,
	selected_id: ThId,
	world_graph: World_Graph,
}

Tick_Output :: struct {
	draw_commands:  [dynamic]Draw_Command,
	click_boxes:    [dynamic]Click_Box,
	selected_panel: Gui_Selected_Panel,
}

get_thing :: proc(ctx: Sim_Ctx, id: ThId) -> (^Thing, bool) #optional_ok {
	if thid_is_valid(id) {
		parts := thid_parts(id)
		thing := &ctx.old_things[parts.ix]
		if thing.id == id {return thing, true}
	}
	return &ctx.old_things[0], false
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
	BASE_SPEED_MULT :: 0.020
	speed := speed * BASE_SPEED_MULT
	if current == destination || speed <= 0 {return current}
	displacement := destination - current
	dist := magnitude(displacement)
	if speed >= dist {return destination}
	change := (displacement / dist) * speed
	return current + change
}

CHUNK_SIZE :: 1000
NUM_CHUNKS :: NUM_THINGS / CHUNK_SIZE

chunk_of_id :: #force_inline proc(id: ThId) -> int {
	return int(thid_parts(id).ix) / CHUNK_SIZE
}

things_simulate :: proc(ctx: Sim_Ctx) {
	assert(NUM_THINGS % CHUNK_SIZE == 0)
	scratch := get_scratch()
	defer release_scratch(scratch)

	// Calculate spatial map on old things
	spatial_map: Spatial_Map = spatial_map_init(
		ctx.alloc,
		ctx.world_graph.grid_size.x,
		ctx.world_graph.grid_size.y,
		32,
	)

	// Analysis pre-pass
	for ix in 1 ..< NUM_THINGS {
		this := ctx.old_things[ix]
		if !thid_is_valid(this.id) do continue
		if this.vars[.Size] >= 0 {
			pos := thing_pos(this)
			spatial_map_insert(spatial_map, this.id, pos)
		}
	}

	Mailbox :: struct {
		movement_target: ThId,
	}

	mailboxes: []Mailbox = make([]Mailbox, NUM_THINGS, scratch.arena)


	// Information processing pass
	for ix in 1 ..< NUM_THINGS {
		this := ctx.old_things[ix]
		if !thid_is_valid(this.id) do continue
		if .IsPerson in this.flags {
			intent := person_ai(ctx, this, spatial_map)

			if intent.enter_target {
				// What to do?
			}

			mailboxes[ix].movement_target = intent.movement_target
		}
	}

	// "Write pass"
	for chunk_idx in 0 ..< NUM_CHUNKS {
		chunk_start := max(1, chunk_idx * CHUNK_SIZE)
		chunk_end := (chunk_idx + 1) * CHUNK_SIZE
		for ix in chunk_start ..< chunk_end {
			old := ctx.old_things[ix]
			new := &ctx.new_things[ix]

			// Basic copy
			new.id = old.id

			if !thid_is_valid(new.id) {continue}

			mailbox := &mailboxes[ix]

			new.labels = old.labels
			new.vars = old.vars
			new.flags = old.flags

			// The new relations should have twice as much capacity as the length of the old
			// This is to pre-empt reallocations, at the cost of a bit of memory
			new.relations = make([dynamic]Reland, 0, len(old.relations) * 2, ctx.alloc)
			append(&new.relations, ..old.relations[:])

			// Determine sprite
			determine_sprite(new)

			// Detections and nearby collisions
			detections := spatial_map_lookup(
				scratch.arena,
				spatial_map,
				thing_pos(old),
				// Detection is either the vision, or the size for collisions
				max(old.vars[.VisionRadius], old.vars[.Size]),
			)

			current_pos: [2]f32 = {new.vars[.Pos_X], new.vars[.Pos_Y]}
			move_to_pos: [2]f32 = current_pos
			if .IsPerson in new.flags {
				// Pathfinding towards movement target
				if thid_is_valid(mailbox.movement_target) {
					target := get_thing(ctx, mailbox.movement_target)
					next_pos, cached_path := pathfind(ctx, old, target^)
					move_to_pos = next_pos
					new.path = cached_path
				}
			}

			// Interpolate positions (temporary idea)
			speed: f32 = new.vars[.Size] <= 1 ? 1 : 0
			if speed >= 0 && move_to_pos != current_pos {
				cell_id := world_graph_cell_of_thing(ctx, new.id)
				// Adjust speed by traversal speed.
				// Give a maximum penalty of 90%, to make sure we don't get stuck when 'clipping edges'
				speed *= max(ctx.world_graph.cells[cell_id].traverse_speed, 0.1)
				next_pos := calculate_next_position(current_pos, move_to_pos, speed)
				new.vars[.Pos_X] = next_pos.x
				new.vars[.Pos_Y] = next_pos.y
			}
		}
	}
}

@(private = "file")
determine_sprite :: proc(this: ^Thing) {
	if .IsSettlement in this.flags {
		sprite := this.labels[.Sprite]
		sprite = "celtic_village"
		if .HasMarket in this.flags && .HasWalls in this.flags {
			sprite = "celtic_town"
		} else if .HasWalls in this.flags {
			sprite = "celtic_castle"
		}
		this.labels[.Sprite] = sprite

	} else if .IsPerson in this.flags {
		if .IsFarmer in this.flags {
			this.labels[.Sprite] = "person"
		} else {
			this.labels[.Sprite] = "soldier"
		}
	}
}

@(private = "file")
Spatial_Map :: struct {
	width:       int,
	height:      int,
	bucket_size: int,
	buckets:     [][dynamic]Spatial_Map_Entry,
}

@(private = "file")
Spatial_Map_Entry :: struct {
	id:  ThId,
	pos: [2]f32,
}

@(private = "file")
spatial_map_init :: proc(
	alloc: mem.Allocator,
	width, height: int,
	bucket_size: int,
) -> Spatial_Map {
	smap: Spatial_Map
	smap.width = width / bucket_size + 1
	smap.height = height / bucket_size + 1
	smap.bucket_size = bucket_size
	smap.buckets = make_slice([][dynamic]Spatial_Map_Entry, smap.width * smap.height, alloc)
	for idx in 0 ..< len(smap.buckets) {
		smap.buckets[idx] = make([dynamic]Spatial_Map_Entry, 0, 0, alloc)
	}
	return smap
}

@(private = "file")
spatial_map_bucket_id :: proc(sm: Spatial_Map, pos: [2]f32) -> int {
	x := int(math.floor(pos.x / f32(sm.bucket_size)))
	y := int(math.floor(pos.y / f32(sm.bucket_size)))
	x = clamp(x, 0, sm.width - 1)
	y = clamp(y, 0, sm.height - 1)
	return y * sm.width + x
}

@(private = "file")
spatial_map_insert :: proc(sm: Spatial_Map, id: ThId, pos: [2]f32) {
	bucket_id := spatial_map_bucket_id(sm, pos)
	bucket := &sm.buckets[bucket_id]
	append(bucket, Spatial_Map_Entry{id, pos})
}

@(private = "file")
Spatial_Map_Hit :: struct {
	id:    ThId,
	pos:   [2]f32,
	range: f32,
}

@(private = "file")
spatial_map_lookup :: proc(
	arena: mem.Allocator,
	sm: Spatial_Map,
	focus: [2]f32,
	range: f32,
) -> []Spatial_Map_Hit {
	if range <= 0.0 {return {}}
	// Lookup spatial map buckets and return all the results
	// (Pre-count the bins contents, allocate the return dynamic array, and return slice)
	radius_sq := range * range
	min_x := clamp(int(math.floor((focus.x - range) / f32(sm.bucket_size))), 0, sm.width - 1)
	max_x := clamp(int(math.floor((focus.x + range) / f32(sm.bucket_size))), 0, sm.width - 1)
	min_y := clamp(int(math.floor((focus.y - range) / f32(sm.bucket_size))), 0, sm.height - 1)
	max_y := clamp(int(math.floor((focus.y + range) / f32(sm.bucket_size))), 0, sm.height - 1)

	num_hits := 0
	for y in min_y ..= max_y {
		for x in min_x ..= max_x {
			bucket_id := y * sm.width + x
			for entry in sm.buckets[bucket_id] {
				delta := entry.pos - focus
				dist_sq := delta.x * delta.x + delta.y * delta.y
				if dist_sq <= radius_sq {
					num_hits += 1
				}
			}
		}
	}

	// There are no hits, lets leave
	if num_hits == 0 {return {}}

	hits :=
		make([]Spatial_Map_Hit, num_hits, arena) or_else panic(
			"failed to allocate spatial map hits",
		)
	write_idx := 0
	for y in min_y ..= max_y {
		for x in min_x ..= max_x {
			bucket_id := y * sm.width + x
			for entry in sm.buckets[bucket_id] {
				delta := entry.pos - focus
				dist_sq := delta.x * delta.x + delta.y * delta.y
				if dist_sq <= radius_sq {
					hits[write_idx] = Spatial_Map_Hit {
						id    = entry.id,
						pos   = entry.pos,
						range = math.sqrt(dist_sq),
					}
					write_idx += 1
				}
			}
		}
	}

	return hits
}

@(private = "file")
thing_pos :: #force_inline proc(thing: Thing) -> [2]f32 {
	return {thing.vars[.Pos_X], thing.vars[.Pos_Y]}
}

world_graph_cell_of_thing :: proc(ctx: Sim_Ctx, id: ThId) -> World_Cell_Id {
	vars := get_thing(ctx, id).vars
	pos: [2]int = {int(math.round(vars[.Pos_X])), int(math.round(vars[.Pos_Y]))}
	return world_graph_pos_to_id(ctx.world_graph, pos)
}

@(private = "file")
pathfind :: proc(ctx: Sim_Ctx, old: Thing, target: Thing) -> ([2]f32, Nav_Path) {
	start_id := world_graph_cell_of_thing(ctx, old.id)
	end_id := world_graph_cell_of_thing(ctx, target.id)

	if start_id == end_id {
		return thing_pos(target), {}
	}

	// Check if we currently have a path cached towards the current destination
	old_path_len := len(old.path.steps)
	if old_path_len > 0 && old.path.steps[old_path_len - 1] == end_id {
		next_cell: World_Cell_Id
		found_current_cell := false
		for idx in 0 ..< len(old.path.steps) - 1 {
			if old.path.steps[idx] == start_id {
				next_cell = old.path.steps[idx + 1]
				found_current_cell = true
				break
			}
		}

		if found_current_cell {
			dest := cast([2]f32)(world_graph_id_to_pos(ctx.world_graph, next_cell))

			// We used this cached path, so we persist it onto the next frame
			new_path: Nav_Path = {
				steps = slice.clone(
					old.path.steps,
					ctx.alloc,
				) or_else panic("failed to allocate cached path"),
			}

			return dest, new_path
		}
	}

	path := world_graph_pathfind(ctx.alloc, ctx.world_graph, start_id, end_id)

	dest: [2]f32 = thing_pos(old)
	if len(path) >= 2 {
		next_cell := path[1]
		dest = cast([2]f32)(world_graph_id_to_pos(ctx.world_graph, next_cell))
	}

	cached_path: Nav_Path = {
		steps = path,
	}
	return dest, cached_path
}

Present_Ctx :: struct {
	things:      []Thing,
	selected_id: ThId,
	camera:      Camera,
}

things_present :: proc(arena: mem.Allocator, ctx: Present_Ctx) -> Tick_Output {
	out: Tick_Output
	num_labels := 0
	num_visible := 0

	// Pass #1: Inspection
	for ix in 1 ..< NUM_THINGS {
		this := &ctx.things[ix]
		if len(this.labels[.Name]) != 0 do num_labels += 1
		if this.vars[.Size] != 0 do num_visible += 1
	}

	out.draw_commands = make([dynamic]Draw_Command, 0, num_visible + num_labels, arena)
	out.click_boxes = make([dynamic]Click_Box, 0, num_visible, arena)

	for ix in 1 ..< NUM_THINGS {
		this := &ctx.things[ix]

		if this.id == ctx.selected_id {
			panel: Gui_Selected_Panel
			panel.visible = true
			panel.info_text = this.labels[.Name]
			out.selected_panel = panel
		}

		size := this.vars[.Size]
		if size > 0 && !(.IsInside in this.flags) && len(this.labels[.Sprite]) > 0 {
			pos_x := this.vars[.Pos_X] - size * 0.5
			pos_y := this.vars[.Pos_Y] - size * 0.5
			is_selected := this.id == ctx.selected_id
			layer := int(this.vars[.Layer])
			bounds: Rect = {pos_x, pos_y, size, size}

			cb: Click_Box
			cb.id = this.id
			cb.bounds = bounds
			cb.layer = layer
			append(&out.click_boxes, cb)

			cmd: Draw_Command
			cmd.bounds = bounds
			cmd.texture.name = this.labels[.Sprite]
			cmd.texture.color = color_rect_uniform(WHITE)
			cmd.texture.intensity = 1
			cmd.layer = layer

			if is_selected {
				cmd.border.color = color_rect_uniform(YELLOW)
				cmd.border.thickness = 2
			}

			append(&out.draw_commands, cmd)

			name := this.labels[.Name]
			if len(name) != 0 {
				// Draw label
				pixel_height := f32(22)
				padding_px := f32(4)
				gap_px := f32(2)
				world_per_screen_px := 1 / camera_screen_per_world_px(ctx.camera)
				text_measure := measure_text(name, pixel_height)
				w := (text_measure.size[0] + padding_px * 2) * world_per_screen_px
				h := (text_measure.size[1] + padding_px * 2) * world_per_screen_px
				x := pos_x + (size - w) * 0.5
				y := pos_y + size + gap_px * world_per_screen_px

				cmd: Draw_Command
				cmd.bounds = {x, y, w, h}
				cmd.texture.color = color_rect_uniform(color_rgba(0, 0, 0, 0.6))
				cmd.text.text = name
				cmd.text.color = WHITE
				if is_selected {
					cmd.text.color = YELLOW
				}
				cmd.text.pixel_height = pixel_height
				cmd.text.alignment = .Center
				cmd.layer = layer

				append(&out.draw_commands, cmd)
			}
		}
	}


	sort.quick_sort_proc(
		out.draw_commands[:][:],
		proc(x: Draw_Command, y: Draw_Command) -> int {return x.layer - y.layer},
	)
	sort.quick_sort_proc(
		out.click_boxes[:][:],
		proc(x: Click_Box, y: Click_Box) -> int {return y.layer - x.layer},
	)

	return out
}

@(private = "file")
Person_Intent :: struct {
	movement_target: ThId,
	enter_target:    bool,
}

@(private = "file")
person_ai :: proc(ctx: Sim_Ctx, this: Thing, spatial_map: Spatial_Map) -> Person_Intent {
	intent: Person_Intent
	// Temporary test functionality
	if this.labels[.Name] == "Ansoaldus" {
		// Target thid = 3
		intent.movement_target = thid_make(3, 1)
	} else if this.labels[.Name] == "Raginwaldus" {
		if ctx.tick_num < 500 {
			intent.movement_target = thid_make(4, 1)
		} else {
			intent.movement_target = thid_make(2, 1)
		}
	} else {
		home, has_home := relation_get_one(this, .HomeOf, .Backward)
		if has_home {
			intent.movement_target = home
			if thing_pos(this) == thing_pos(get_thing(ctx, home)^) {
				intent.enter_target = true
			}
		}
	}
	return intent
}
