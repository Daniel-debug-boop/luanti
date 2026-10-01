class_name EmergentDiagnostics
extends RefCounted
## The developer view: why is this thing doing what it is doing?
##
## An emergent system that cannot explain itself is unusable for its authors.
## Every design decision in this layer -- pattern match separate from
## behaviour, behaviour separate from constraints, constraints reporting a
## reason rather than a bool -- exists so that THIS file can produce a
## truthful answer to "my golf hole does not score".
##
## The output is plain text on purpose. A graph visualisation is a separate
## concern and belongs in the UI layer; what the engine owes its authors is a
## structured, complete, printable account, and that is what this returns.

## A full inspection of one subject.
##
## `subject` is an entity id or a graph node id. Both are ints in the same
## space, so the diagnostic view does not have to care which it is looking at
## -- which is itself a sign the graph model is the right shape.
static func inspect(emergent: Object, subject: int) -> String:
	var graph: EmergentGraph = emergent.graph
	var out := PackedStringArray()
	var entity := graph.entity(subject)
	if entity != null:
		out.append("SUBJECT: %s (entity %d)" % [EmergentEntity.label_of(
			entity.kind).to_upper(), entity.id])
		out.append("  at %s" % str(entity.position))
		_append_capabilities(out, entity.capabilities())
		_append_properties(out, entity)
		_append_state(out, entity)
		_append_limits(out, entity, null)
	else:
		var src := graph.source()
		var node: EngGraph.EngNode = src.node(subject) if src != null else null
		if node == null:
			return "SUBJECT %d: nothing here" % subject
		out.append("SUBJECT: %s (node %d)" % [node.component_id.to_upper(),
			node.id])
		out.append("  at %s" % str(node.position))
		_append_capabilities(out, EmergentCaps.of_component(node.component_id))
		_append_properties_node(out, node)
		_append_state_node(out, node)
		_append_limits(out, entity, node)
	_append_relationships(out, graph, subject)
	_append_patterns(out, emergent, subject, entity)
	_append_behaviours(out, emergent, subject)
	_append_causal_chain(out, emergent, subject)
	_append_rules(out)
	return "\n".join(out)


static func _append_capabilities(out: PackedStringArray, caps: Array[String]) -> void:
	if caps.is_empty():
		out.append("  CAPABILITIES: (none)")
		return
	var sorted := caps.duplicate()
	sorted.sort()
	out.append("  CAPABILITIES: %s" % ", ".join(sorted))


static func _append_properties(out: PackedStringArray, entity: EmergentEntity) -> void:
	if entity.props.is_empty():
		return
	var keys := PackedStringArray()
	for k in entity.props.keys():
		keys.append(String(k))
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%s" % [k, str(entity.props[k])])
	out.append("  PROPERTIES: %s" % ", ".join(parts))


## INPUTS and OUTPUTS, read off the component's ports rather than declared.
## A port the player left free is an input nobody is supplying, and saying so
## is the difference between "why is my motor stalled" being answerable and
## not.
static func _append_limits(out: PackedStringArray, entity: EmergentEntity,
		node: EngGraph.EngNode) -> void:
	if entity != null and node == null:
		out.append("  INPUTS: (an entity has no ports)")
		out.append("  OUTPUTS: (an entity has no ports)")
		return
	var free_in := 0
	var free_out := 0
	var in_names := PackedStringArray()
	var out_names := PackedStringArray()
	var def := EngPorts.get_def(node.component_id)
	if def != null:
		for p in def.ports:
			var port: EngPorts.Port = p
			if port.kind == EngPorts.Kind.STRUCTURAL:
				continue
			if port.flow == EngPorts.Flow.INPUT:
				free_in += 1
				in_names.append(port.name)
			elif port.flow == EngPorts.Flow.OUTPUT:
				free_out += 1
				out_names.append(port.name)
	out.append("  INPUTS: %s" % (", ".join(in_names) if not in_names.is_empty()
		else "(none)"))
	out.append("  OUTPUTS: %s" % (", ".join(out_names)
		if not out_names.is_empty() else "(none)"))


## Which of these names are checked, so the caller can print it. Kept here
## rather than in the constraint layer because this is a display concern.
static func _append_properties_node(out: PackedStringArray,
		node: EngGraph.EngNode) -> void:
	var p := EngMachines.params_of(node.component_id)
	if p.is_empty():
		return
	var keys := PackedStringArray()
	for k in p.keys():
		keys.append(String(k))
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%s" % [k, str(p[k])])
	out.append("  PROPERTIES: %s" % ", ".join(parts))


static func _append_state(out: PackedStringArray, entity: EmergentEntity) -> void:
	if entity.state.is_empty():
		return
	var keys := PackedStringArray()
	for k in entity.state.keys():
		keys.append(String(k))
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%s" % [k, str(entity.state[k])])
	out.append("  STATE: %s" % ", ".join(parts))


static func _append_state_node(out: PackedStringArray, node: EngGraph.EngNode) -> void:
	if node.state.is_empty():
		return
	var keys := PackedStringArray()
	for k in node.state.keys():
		keys.append(String(k))
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%s" % [k, str(node.state[k])])
	out.append("  STATE: %s" % ", ".join(parts))


## entity -> relationship -> entity, in both directions, because "what drives
## this" and "what does this drive" are different questions and a player asks
## both.
static func _append_relationships(out: PackedStringArray, graph: EmergentGraph,
		subject: int) -> void:
	var rels := graph.relatives(subject, "", 32)
	if rels.is_empty():
		out.append("  RELATIONSHIPS: (none)")
		return
	out.append("  RELATIONSHIPS:")
	for r in rels:
		var d: Dictionary = r
		var other := int(d["other"])
		out.append("    %s --%s--> %s" % [_name_of(graph, subject),
			String(d["rel"]), _name_of(graph, other)])


static func _name_of(graph: EmergentGraph, id: int) -> String:
	var e := graph.entity(id)
	if e != null:
		return "%s#%d" % [e.kind, e.id]
	var src := graph.source()
	var n: EngGraph.EngNode = src.node(id) if src != null else null
	return "node#%d(%s)" % [id, n.component_id] if n != null else "?%d" % id


## Both halves of the pattern story: what matched, and what did not. The
## second list is the more useful one -- it is the difference between a player
## knowing their hole needs a counter and guessing.
static func _append_patterns(out: PackedStringArray, emergent: Object,
		subject: int, entity: EmergentEntity) -> void:
	# The membership list the ENGINE used, not a re-derivation. A viewer that
	# computed its own would be a second opinion, and a second opinion that
	# disagrees with the engine is worse than no opinion at all.
	var members: Array = emergent.members_of(subject)
	if members.is_empty():
		return
	var matched: Array[String] = []
	var rejected: Array[String] = []
	for m in EmergentMatcher.match_assembly(members):
		var mm: EmergentMatcher.Match = m
		if mm.satisfied:
			matched.append(mm.pattern_id)
		else:
			rejected.append("%s (%s)" % [mm.pattern_id,
				", ".join(mm.missing)])
	matched.sort()
	rejected.sort()
	out.append("  MATCHED PATTERNS: %s" % (", ".join(matched) if
		not matched.is_empty() else "(none)"))
	if not rejected.is_empty():
		out.append("  NOT MATCHED:")
		for r in rejected:
			out.append("    %s" % r)


static func _append_behaviours(out: PackedStringArray, emergent: Object,
		subject: int) -> void:
	var graph: EmergentGraph = emergent.graph
	var active: Array = emergent.active_for(subject)
	if active.is_empty():
		out.append("  BEHAVIOURS: (none active)")
		return
	out.append("  BEHAVIOURS:")
	for a in active:
		var d: Dictionary = a
		var mark := "ON " if bool(d.get("active", false)) else "OFF"
		var line := "    [%s] %s" % [mark, String(d.get("behaviour", ""))]
		if String(d.get("reason", "")) != "":
			line += " -- %s" % String(d["reason"])
		out.append(line)


## cause -> transformation -> event -> state, reconstructed from what
## actually happened rather than from what the pattern intended. When a chain
## is broken this is where the break shows up.
static func _append_causal_chain(out: PackedStringArray, emergent: Object,
		subject: int) -> void:
	var chain: Array = emergent.causal_chain(subject)
	if chain == null:
		chain = []
	if chain.is_empty():
		out.append("  CAUSAL CHAIN: (nothing yet)")
		return
	out.append("  CAUSAL CHAIN:")
	var arrow := "    "
	for step in chain:
		out.append("%s%s" % [arrow, str(step)])
		arrow += "  ->  "


static func _append_rules(out: PackedStringArray) -> void:
	var rules: Array = EmergentRules.all()
	if rules.is_empty():
		return
	out.append("  PLAYER RULES:")
	for r in rules:
		var rule: EmergentRules.Rule = r
		out.append("    #%d %s (%d fired)" % [rule.id, rule.describe(),
			rule.fired])


## A summary of the whole layer, for the F11 report and for bug reports.
static func summarize(emergent: Object) -> String:
	var graph: EmergentGraph = emergent.graph
	var out := PackedStringArray()
	out.append("EMERGENT SYSTEM")
	out.append("  entities      %d" % graph.entity_count())
	out.append("  patterns      %d registered" % EmergentPatterns.all_ids().size())
	out.append("  behaviours    %d registered" % EmergentBehaviors.all_ids().size())
	out.append("  rules         %d authored" % EmergentRules.count())
	out.append("  graph rebuild %d (last %.2f ms)" % [graph.rebuilds,
		graph.rebuild_ms])
	out.append("  %s" % emergent.causal.report())
	var s := graph.stats()
	out.append("  relationships %d subjects" % int(s["nodes"]))
	return "\n".join(out)


## The graph as text. Cheap, printable, and enough to see a cycle that a
## force-directed layout would just draw as a knot.
static func graph_dump(graph: EmergentGraph, limit := 64) -> String:
	var out := PackedStringArray()
	var ids := PackedInt32Array()
	var src := graph.source()
	if src != null:
		for n in src.all_nodes():
			ids.append(int((n as EngGraph.EngNode).id))
	for e in graph.all_entities():
		ids.append(int((e as EmergentEntity).id))
	ids.sort()
	var shown := 0
	for id in ids:
		if shown >= limit:
			out.append("  ... %d more" % (ids.size() - shown))
			break
		var rels := graph.relatives(id, "", 8)
		if rels.is_empty():
			continue
		shown += 1
		var parts := PackedStringArray()
		for r in rels:
			var d: Dictionary = r
			parts.append("%s:%s" % [String(d["rel"]), _name_of(graph,
				int(d["other"]))])
		out.append("  %s -> %s" % [_name_of(graph, id), ", ".join(parts)])
	return "\n".join(out)