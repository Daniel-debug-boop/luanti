class_name Pathfinder
extends RefCounted
## A* over the voxel grid, so mobs can walk around obstacles instead of
## bumping into them.
##
## The grid is the voxel field itself: `VoxelWorld.solid_at()` answers "can I
## stand here", so there is no separate navmesh to keep in sync with terrain
## edits. A step may climb or fall one block, which is what lets a mob follow a
## player up a staircase of single blocks the way the player can.
##
## Deliberately bounded: a 1-core machine cannot afford an unbounded search, so
## the node budget is capped and a failed search returns an empty path rather
## than stalling the frame. The mob then falls back to its old direct steering.

## Nodes expanded before the search gives up.
const MAX_NODES := 1500
## Ignore steps that would move further than this, to bound the search box.
const MAX_RANGE := 24

## Directions, with the climb allowed for each.
const STEPS := [
	[Vector3i(1, 0, 0), 0], [Vector3i(-1, 0, 0), 0],
	[Vector3i(0, 0, 1), 0], [Vector3i(0, 0, -1), 0],
	# Up a one-block step.
	[Vector3i(1, 1, 0), 1], [Vector3i(-1, 1, 0), 1],
	[Vector3i(0, 1, 1), 1], [Vector3i(0, 1, -1), 1],
	# Down one block.
	[Vector3i(1, -1, 0), -1], [Vector3i(-1, -1, 0), -1],
	[Vector3i(0, -1, 1), -1], [Vector3i(0, -1, -1), -1],
]


## Find a walkable path from `from` to `to`, excluding both endpoints' start
## cell from the "is blocked" test. Returns an empty array when no route exists
## within the node budget.
##
## `height` is how many blocks tall the mover is; a cell is passable when
## there is floor to stand on and `height` blocks of headroom.
static func find_path(world: VoxelWorld, from: Vector3i, to: Vector3i,
		height := 2) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if world == null or not is_instance_valid(world):
		return out
	# Start from the ground under the mover rather than its feet, so a mob
	# standing on a block starts from a cell it can actually occupy.
	var start := _ground_at(world, from, height)
	var goal := _ground_at(world, to, height)
	if start == goal:
		return out

	var open := {start: 0.0}
	var came := {}
	var gscore := {start: 0.0}
	var closed := {}
	var expansions := 0

	while not open.is_empty() and expansions < MAX_NODES:
		expansions += 1
		var current := _pop_best(open, goal)
		if current == goal:
			return _reconstruct(came, current)
		closed[current] = true
		open.erase(current)

		for step in STEPS:
			var delta: Vector3i = step[0]
			var climb: int = step[1]
			var next := current + delta
			if closed.has(next):
				continue
			if absi(next.x - start.x) > MAX_RANGE or absi(next.z - start.z) > MAX_RANGE:
				continue
			if not _passable(world, next, climb, height):
				continue
			var tentative: float = float(gscore[current]) \
				+ 1.0 + (0.4 if climb != 0 else 0.0)
			if gscore.has(next) and tentative >= float(gscore[next]):
				continue
			came[next] = current
			gscore[next] = tentative
			# f = g + h, so the pop order is A* rather than Dijkstra.
			open[next] = tentative + _heuristic(next, goal)
	return out


## Lowest cell at or below `pos` that the mover can occupy, or `pos` itself.
static func _ground_at(world: VoxelWorld, pos: Vector3i, height: int) -> Vector3i:
	var p := Vector3i(pos.x, maxi(pos.y, 1), pos.z)
	for _i in 8:
		if _passable(world, p, 0, height):
			return p
		p.y += 1
	return Vector3i(pos.x, maxi(pos.y, 1), pos.z)


## Can the mover occupy `cell`, having just moved `climb` blocks vertically?
## Climbing needs solid ground underfoot at the destination; stepping down or
## across only needs headroom, because gravity handles the fall.
static func _passable(world: VoxelWorld, cell: Vector3i, climb: int,
		height: int) -> bool:
	if world.solid_at(cell):
		return false
	for h in height:
		if world.solid_at(cell + Vector3i(0, h, 0)):
			return false
	if climb >= 0 and not world.solid_at(cell - Vector3i(0, 1, 0)):
		# Nothing to stand on: this would be a mid-air step-up.
		return false
	return true


static func _heuristic(a: Vector3i, b: Vector3i) -> float:
	var d := absi(a.x - b.x) + absi(a.y - b.y) + absi(a.z - b.z)
	return float(d)


## Pop the open node with the lowest g+h, which is what makes this A* rather
## than Dijkstra. The node set is tiny (a few hundred at most before the
## budget bites) so a linear scan beats the bookkeeping of a heap.
static func _pop_best(open: Dictionary, goal: Vector3i) -> Vector3i:
	var best: Vector3i = Vector3i.ZERO
	var best_score := INF
	for k in open.keys():
		var pos: Vector3i = k
		var score := float(open[k])
		if score < best_score:
			best_score = score
			best = pos
	return best


static func _reconstruct(came: Dictionary, goal: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var cur := goal
	var guard := 0
	while came.has(cur) and guard < MAX_NODES:
		out.push_front(cur)
		cur = came[cur]
		guard += 1
	return out
