package main

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

THING_INIT_PATH :: "data/init.csv"

@(private = "file")
Thing_Load_Ctx :: struct {
	persistent_alloc:   mem.Allocator,
	thing_alloc:        mem.Allocator,
	pass_alloc:         mem.Allocator,
	ids:                map[string]ThId,
	// Maps strings (as loaded) to strings in long etrm allocation
	persistent_strings: map[string]string,
	current:            ^Thing,
	next_ix:            u16,
}

@(private = "file")
label_from_string :: proc(name: string) -> (Label, bool) {
	for label in Label {
		if LABEL_NAMES[label] == name {
			return label, true
		}
	}

	return {}, false
}

@(private = "file")
var_from_string :: proc(name: string) -> (Var, bool) {
	for v in Var {
		if VAR_NAMES[v] == name {
			return v, true
		}
	}

	return {}, false
}

@(private = "file")
flag_from_string :: proc(name: string) -> (Flag, bool) {
	for flag in Flag {
		if FLAG_NAMES[flag] == name {
			return flag, true
		}
	}

	return {}, false
}

@(private = "file")
relation_from_string :: proc(name: string) -> (Relation, bool) {
	for rel in Relation {
		if RELATION_NAMES[rel] == name {
			return rel, true
		}
	}

	return {}, false
}

@(private = "file")
parse_bool :: proc(text: string) -> (bool, bool) {
	switch text {
	case "1", "true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON":
		return true, true
	case "0", "false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF":
		return false, true
	}

	return false, false
}

things_init :: proc(things: ^Things) {
	for ix in 0 ..< NUM_THINGS {
		thing: Thing
		thing.id = thid_make(u16(ix), 0)
		things.entries[ix] = thing
	}
}

@(private = "file")
thing_load_error :: proc(path: string, row_num: int, fmt_string: string, args: ..any) {
	fmt.eprintf("%s:%d: ", path, row_num)
	fmt.eprintf(fmt_string, ..args)
	fmt.eprintf("\n")
}

@(private = "file")
thing_load_require_current :: proc(
	ctx: ^Thing_Load_Ctx,
	path: string,
	row_num: int,
	command: string,
) -> bool {
	if ctx.current != nil {
		return true
	}

	thing_load_error(path, row_num, "%s requires a current thing", command)
	return false
}

@(private = "file")
thing_load_resolve_id :: proc(
	ctx: ^Thing_Load_Ctx,
	path: string,
	row_num: int,
	key: string,
	role: string,
) -> (ThId, bool) {
	if key == "THIS" {
		if ctx.current == nil {
			thing_load_error(path, row_num, "THIS %s requires a current thing", role)
			return {}, false
		}
		return ctx.current.id, true
	}

	id, ok := ctx.ids[key]
	if !ok {
		thing_load_error(path, row_num, "unknown %s thing key %q", role, key)
		return {}, false
	}
	return id, true
}

@(private = "file")
thing_load_set_label :: proc(
	ctx: ^Thing_Load_Ctx,
	path: string,
	row_num: int,
	row: []string,
) -> bool {
	if len(row) != 3 {
		thing_load_error(path, row_num, "label expects 2 arguments")
		return false
	}
	if !thing_load_require_current(ctx, path, row_num, row[0]) {
		return false
	}

	label, ok := label_from_string(row[1])
	if !ok {
		thing_load_error(path, row_num, "unknown label %q", row[1])
		return false
	}


	persistent, exists := ctx.persistent_strings[row[2]]
	if !exists {
		// Clone to persistent memory and insert
		persistent = strings.clone(row[2], ctx.persistent_alloc) or_else panic(
			"failed to allocate persistent thing label",
		)
		key := strings.clone(row[2], ctx.pass_alloc) or_else panic(
			"failed to allocate persistent thing label key",
		)
		map_insert(&ctx.persistent_strings, key, persistent)
	}

	ctx.current.labels[label] = persistent
	return true
}

things_setup :: proc(path: string, things: ^Things, persistent_alloc: mem.Allocator) -> bool {
	things_init(things)

	scratch := get_scratch()
	defer release_scratch(scratch)

	records, ok := load_csv_records(path, scratch.arena)
	if !ok {
		return false
	}

	blob_arena: mem.Arena
	mem.arena_init(&blob_arena, things.blob[:])
	ctx := Thing_Load_Ctx {
		persistent_alloc   = persistent_alloc,
		thing_alloc        = mem.arena_allocator(&blob_arena),
		pass_alloc         = scratch.arena,
		persistent_strings = make(map[string]string, scratch.arena),
		ids                = make(map[string]ThId, scratch.arena),
		next_ix            = 1,
	}

	for row, row_idx in records {
		row_num := row_idx + 1
		if len(row) == 0 {
			continue
		}

		switch row[0] {
		case "spawn":
			if len(row) != 2 {
				thing_load_error(path, row_num, "spawn expects 1 argument")
				return false
			}
			if len(row[1]) == 0 {
				thing_load_error(path, row_num, "spawn key cannot be empty")
				return false
			}
			if _, exists := ctx.ids[row[1]]; exists {
				thing_load_error(path, row_num, "duplicate thing key %q", row[1])
				return false
			}
			if int(ctx.next_ix) >= NUM_THINGS {
				thing_load_error(path, row_num, "too many things")
				return false
			}

			thing := &things.entries[ctx.next_ix]
			thing.id = thid_bump_generation(thing.id)
			thing.relations = make([dynamic]Reland, 0, 0, ctx.thing_alloc) or_else panic(
				"failed to allocate thing relations",
			)
			ctx.ids[row[1]] = thing.id
			ctx.current = thing
			ctx.next_ix += 1

		case "label":
			if !thing_load_set_label(&ctx, path, row_num, row) {
				return false
			}

		case "var":
			if len(row) != 3 {
				thing_load_error(path, row_num, "var expects 2 arguments")
				return false
			}
			if !thing_load_require_current(&ctx, path, row_num, row[0]) {
				return false
			}

			v, var_ok := var_from_string(row[1])
			if !var_ok {
				thing_load_error(path, row_num, "unknown var %q", row[1])
				return false
			}

			value, parse_ok := strconv.parse_f32(row[2])
			if !parse_ok {
				thing_load_error(path, row_num, "invalid f32 %q", row[2])
				return false
			}
			ctx.current.vars[v] = value

		case "flag":
			if len(row) != 2 && len(row) != 3 {
				thing_load_error(path, row_num, "flag expects 1 or 2 arguments")
				return false
			}
			if !thing_load_require_current(&ctx, path, row_num, row[0]) {
				return false
			}

			flag, flag_ok := flag_from_string(row[1])
			if !flag_ok {
				thing_load_error(path, row_num, "unknown flag %q", row[1])
				return false
			}

			enabled := true
			if len(row) == 3 {
				bool_ok: bool
				enabled, bool_ok = parse_bool(row[2])
				if !bool_ok {
					thing_load_error(path, row_num, "invalid bool %q", row[2])
					return false
				}
			}

			if enabled {
				ctx.current.flags += bit_set[Flag]{flag}
			} else {
				ctx.current.flags -= bit_set[Flag]{flag}
			}

		case "relate":
			if len(row) != 4 {
				thing_load_error(path, row_num, "relate expects 3 arguments")
				return false
			}

			src_id, src_ok := thing_load_resolve_id(&ctx, path, row_num, row[1], "source")
			if !src_ok {
				return false
			}
			rel, rel_ok := relation_from_string(row[2])
			if !rel_ok {
				thing_load_error(path, row_num, "unknown relation %q", row[2])
				return false
			}
			tgt_id, tgt_ok := thing_load_resolve_id(&ctx, path, row_num, row[3], "target")
			if !tgt_ok {
				return false
			}

			src := &things.entries[thid_parts(src_id).ix]
			tgt := &things.entries[thid_parts(tgt_id).ix]
			append(&src.relations, Reland{id = tgt_id, relation = rel, type = .Forward})
			append(&tgt.relations, Reland{id = src_id, relation = rel, type = .Backward})

		case:
			thing_load_error(path, row_num, "unknown command %q", row[0])
			return false
		}
	}

	return true
}
