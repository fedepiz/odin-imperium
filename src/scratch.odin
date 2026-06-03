package main

import "core:mem"
import vmem "core:mem/virtual"

Scratch_Arena_State :: struct {
	arena:       vmem.Arena,
	allocator:   mem.Allocator,
	initialized: bool,
}

Arena_Temp :: struct {
	arena:    mem.Allocator,
	_backing: ^vmem.Arena,
	_temp:    vmem.Arena_Temp,
}

@(thread_local)
scratch_arenas: [NUM_SCRATCH_ARENAS]Scratch_Arena_State

ensure_scratch_arena :: proc(idx: int) {
	if scratch_arenas[idx].initialized {
		return
	}

	err := vmem.arena_init_growing(&scratch_arenas[idx].arena, DEFAULT_SCRATCH_ARENA_CAPACITY)
	if err != nil {
		panic("failed to initialize scratch arena")
	}

	scratch_arenas[idx].allocator = vmem.arena_allocator(&scratch_arenas[idx].arena)
	scratch_arenas[idx].initialized = true
}

allocator_conflicts :: proc(a, b: mem.Allocator) -> bool {
	return a.data == b.data
}

get_scratch :: proc(conflicts: ..mem.Allocator) -> Arena_Temp {
	for idx := 0; idx < NUM_SCRATCH_ARENAS; idx += 1 {
		ensure_scratch_arena(idx)

		has_conflict := false
		for conflict in conflicts {
			if allocator_conflicts(conflict, scratch_arenas[idx].allocator) {
				has_conflict = true
				break
			}
		}

		if !has_conflict {
			return Arena_Temp {
				arena = scratch_arenas[idx].allocator,
				_backing = &scratch_arenas[idx].arena,
				_temp = vmem.arena_temp_begin(&scratch_arenas[idx].arena),
			}
		}
	}

	panic("no scratch arena available")
}

release_scratch :: proc(temp: Arena_Temp) {
	vmem.arena_temp_end(temp._temp)
}

