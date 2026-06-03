package main

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

THING_INIT_PATH :: "data/init.csv"

@(private = "file")
Thing_Load_Ctx :: struct {
	alloc:   mem.Allocator,
	ids:     map[string]ThId,
	current: ^Thing,
	next_ix: u16,
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

	ctx.current.labels[label] =
		strings.clone(row[2], ctx.alloc) or_else panic("failed to allocate thing label")
	return true
}

things_load_csv :: proc(path: string, things: ^Things) -> bool {
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
		alloc   = mem.arena_allocator(&blob_arena),
		ids     = make(map[string]ThId, scratch.arena),
		next_ix = 1,
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

		case:
			thing_load_error(path, row_num, "unknown command %q", row[0])
			return false
		}
	}

	return true
}
