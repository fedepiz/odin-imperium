package main

import "core:mem"
import heap "core:slice/heap"
World_Cell_Id :: distinct int

World_Cell :: struct {
	traverse_speed: f32,
}

World_Graph :: struct {
	grid_size: [2]int,
	// Array representing the 2d grid of cells
	cells:     []World_Cell,
}

WORLD_GRAPH_UNREACHABLE_COST :: 1e30
WORLD_GRAPH_DIAGONAL_DISTANCE :: f32(1.41421356)

@(private = "file")
World_Graph_Open_Node :: struct {
	cell:    World_Cell_Id,
	f_score: f32,
}

make_world_graph :: proc(
	allocator: mem.Allocator,
	size: [2]int,
	terrain: []Terrain_Type,
) -> World_Graph {
	graph: World_Graph
	graph.grid_size = size
	num_cells := size.x * size.y
	assert(num_cells == len(terrain))

	graph.grid_size = size
	cells, cells_err := make([]World_Cell, size.x * size.y, allocator)
	if cells_err != nil {
		panic("failed to allocate world graph cells")
	}
	graph.cells = cells
	for i := 0; i < num_cells; i += 1 {
		graph.cells[i].traverse_speed = terrain[i].movement_speed
	}

	return graph
}

world_graph_pos_is_valid :: #force_inline proc(graph: World_Graph, pos: [2]int) -> bool {
	return pos.x >= 0 && pos.x < graph.grid_size.x && pos.y >= 0 && pos.y < graph.grid_size.y
}

world_graph_cell_is_valid :: #force_inline proc(graph: World_Graph, id: World_Cell_Id) -> bool {
	idx := int(id)
	return idx >= 0 && idx < len(graph.cells)
}

world_graph_pos_to_id :: #force_inline proc(graph: World_Graph, pos: [2]int) -> World_Cell_Id {
	idx := pos.y * graph.grid_size.x + pos.x
	return World_Cell_Id(idx)
}

world_graph_id_to_pos :: #force_inline proc(graph: World_Graph, id: World_Cell_Id) -> [2]int {
	idx := int(id)
	return {idx % graph.grid_size.x, idx / graph.grid_size.x}
}

world_graph_get_neighbours :: proc(
	graph: World_Graph,
	cell_id: World_Cell_Id,
	out: ^[dynamic]World_Cell_Id,
) {
	// Update the slice by returning the neighbours in it
	clear(out)
	pos := world_graph_id_to_pos(graph, cell_id)
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			if dx == 0 && dy == 0 do continue
			npos := pos + [2]int{dx, dy}
			if !world_graph_pos_is_valid(graph, npos) do continue
			ncell := world_graph_pos_to_id(graph, npos)
			if !world_graph_cell_is_valid(graph, ncell) do continue
			append_or_panic(out, ncell)
		}
	}
}

@(private = "file")
world_graph_edge_cost :: proc(graph: World_Graph, from, to: World_Cell_Id) -> (f32, bool) {
	from_cell := graph.cells[int(from)]
	to_cell := graph.cells[int(to)]
	if from_cell.traverse_speed <= 0 || to_cell.traverse_speed <= 0 {
		return 0, false
	}

	edge_cost := 0.5 * (1 / from_cell.traverse_speed + 1 / to_cell.traverse_speed)
	from_pos := world_graph_id_to_pos(graph, from)
	to_pos := world_graph_id_to_pos(graph, to)
	if from_pos.x != to_pos.x && from_pos.y != to_pos.y {
		edge_cost *= WORLD_GRAPH_DIAGONAL_DISTANCE
	}

	return edge_cost, true
}

@(private = "file")
world_graph_heuristic :: proc(
	graph: World_Graph,
	max_traverse_speed: f32,
	from, to: World_Cell_Id,
) -> f32 {
	if max_traverse_speed <= 0 {
		return 0
	}

	from_pos := world_graph_id_to_pos(graph, from)
	to_pos := world_graph_id_to_pos(graph, to)
	dx := from_pos.x - to_pos.x
	if dx < 0 {
		dx = -dx
	}
	dy := from_pos.y - to_pos.y
	if dy < 0 {
		dy = -dy
	}

	steps := dx
	if dy < dx {
		steps = dy
	}
	straight_steps := dx + dy - 2 * steps
	distance := f32(steps) * WORLD_GRAPH_DIAGONAL_DISTANCE + f32(straight_steps)

	return distance / max_traverse_speed
}

@(private = "file")
world_graph_reconstruct_path :: proc(
	allocator: mem.Allocator,
	came_from: []int,
	start, goal: World_Cell_Id,
) -> []World_Cell_Id {
	start_idx := int(start)
	current_idx := int(goal)
	path_len := 1
	for current_idx != start_idx {
		current_idx = came_from[current_idx]
		if current_idx < 0 {
			return {}
		}
		path_len += 1
	}

	path, err := make([]World_Cell_Id, path_len, allocator)
	if err != nil {
		panic("failed to allocate world path")
	}

	current_idx = int(goal)
	for write_idx := path_len - 1; write_idx >= 0; write_idx -= 1 {
		path[write_idx] = World_Cell_Id(current_idx)
		if current_idx == start_idx {
			break
		}

		current_idx = came_from[current_idx]
		if current_idx < 0 {
			return {}
		}
	}

	return path
}

@(private = "file")
world_graph_open_node_less :: proc(a, b: World_Graph_Open_Node) -> bool {
	if a.f_score == b.f_score {
		return int(a.cell) > int(b.cell)
	}
	return a.f_score > b.f_score
}

world_graph_pathfind :: proc(
	allocator: mem.Allocator,
	graph: World_Graph,
	start: World_Cell_Id,
	end: World_Cell_Id,
) -> []World_Cell_Id {
	// Performs A* pathfinding between start and end cells.
	// Outputs a slice, allocated in `allocator`, which contains all the nodes of the path, including start and end
	// The edge cost between edges Ei and Ej is:
	// (1/Ei.traverse_speed + 1/Ej.traverse_speed)/2
	// (If either traverse speed is 0, the edge is impassable and should not be considered)
	if !world_graph_cell_is_valid(graph, start) || !world_graph_cell_is_valid(graph, end) {
		return {}
	}

	if graph.cells[int(start)].traverse_speed <= 0 || graph.cells[int(end)].traverse_speed <= 0 {
		return {}
	}

	if start == end {return {}}

	scratch := get_scratch(allocator)
	defer release_scratch(scratch)

	num_cells := len(graph.cells)
	came_from := make([]int, num_cells, scratch.arena)
	g_score := make([]f32, num_cells, scratch.arena)
	f_score := make([]f32, num_cells, scratch.arena)
	closed := make([]bool, num_cells, scratch.arena)
	open_set := make([dynamic]World_Graph_Open_Node, 0, 16, scratch.arena)

	max_traverse_speed: f32
	for i := 0; i < num_cells; i += 1 {
		came_from[i] = -1
		g_score[i] = WORLD_GRAPH_UNREACHABLE_COST
		f_score[i] = WORLD_GRAPH_UNREACHABLE_COST
		if graph.cells[i].traverse_speed > max_traverse_speed {
			max_traverse_speed = graph.cells[i].traverse_speed
		}
	}

	neighbours := make([dynamic]World_Cell_Id, 0, 8, scratch.arena)

	start_idx := int(start)
	g_score[start_idx] = 0
	f_score[start_idx] = world_graph_heuristic(graph, max_traverse_speed, start, end)
	append_or_panic(&open_set, World_Graph_Open_Node{cell = start, f_score = f_score[start_idx]})

	for len(open_set) > 0 {
		current_node := open_set[0]
		heap.pop(open_set[:], world_graph_open_node_less)
		resize(&open_set, len(open_set) - 1)

		current := current_node.cell
		current_idx := int(current)
		if closed[current_idx] {
			continue
		}
		if current_node.f_score > f_score[current_idx] {
			continue
		}

		if current == end {
			return world_graph_reconstruct_path(allocator, came_from, start, end)
		}

		closed[current_idx] = true
		world_graph_get_neighbours(graph, current, &neighbours)
		for neighbour in neighbours {
			neighbour_idx := int(neighbour)
			if closed[neighbour_idx] {
				continue
			}

			edge_cost, ok := world_graph_edge_cost(graph, current, neighbour)
			if !ok {
				continue
			}

			tentative_g := g_score[current_idx] + edge_cost
			if tentative_g >= g_score[neighbour_idx] {
				continue
			}

			came_from[neighbour_idx] = current_idx
			g_score[neighbour_idx] = tentative_g
			f_score[neighbour_idx] =
				tentative_g + world_graph_heuristic(graph, max_traverse_speed, neighbour, end)
			append_or_panic(
				&open_set,
				World_Graph_Open_Node{cell = neighbour, f_score = f_score[neighbour_idx]},
			)
			heap.push(open_set[:], world_graph_open_node_less)
		}
	}

	return {}
}
