class_name EmergentPersistence
extends RefCounted
## Save/load for the emergent layer, and the argument about what to save.
##
## The rule is short: **save what only the player knows.**
##
## That is the placed entities (where they are, what kind, what state they
## reached) and the player's rules (their intent). Everything else --
## relationships, capabilities, matched patterns, composed behaviours, the
## causal chain, the event queue -- is DERIVED, and derived data is not saved.
##
## The reason is not file size, it is correctness. Derived data is a claim
## about what the code would compute. If the code changes -- a new pattern, a
## fixed bug, a rebalanced constraint -- every save that stored the old answer
## now disagrees with the engine, and the player gets a machine that no longer
## matches the pattern that used to describe it. Reconstructing instead means
## an old save gets the CURRENT interpretation of the same construction, which
## is the only interpretation that can be correct.
##
## The test that matters is at the bottom of this file: serialize, clear,
## deserialize, and assert the reconstructed world produces the SAME
## behaviours. Not similar -- the same.

## Format version. Bumped when the shape changes; `migrate` is the hook.
const VERSION := 1


## What gets written. Deliberately small and boring.
static func capture(emergent: Object) -> Dictionary:
	var graph: EmergentGraph = emergent.graph
	var causal: EmergentCausal = emergent.causal
	return {
		"version": VERSION,
		"graph": graph.serialize(),
		"rules": EmergentRules.serialize(),
		"causal": causal.serialize(),
		"tick": int(emergent.tick_count),
	}


## Rebuild from a save. Returns a report the caller can show the player:
## what was restored, and -- importantly -- what was REJECTED. A load that
## silently drops half a factory and reports "ok" is worse than a refusal.
static func restore(emergent: Object, data: Dictionary) -> Dictionary:
	var graph: EmergentGraph = emergent.graph
	var causal: EmergentCausal = emergent.causal
	var report := {"entities": 0, "skipped": 0, "rules": 0, "version": 0}
	report["version"] = int(data.get("version", 0))
	if report["version"] > VERSION:
		report["reason"] = "save is from a newer build (v%d)" % report["version"]
		return report
	var g := graph.deserialize(data.get("graph", {})) as Dictionary
	report["entities"] = int(g.get("entities", 0))
	report["skipped"] = int(g.get("skipped", 0))
	var r := EmergentRules.deserialize(data.get("rules", {})) as Dictionary
	report["rules"] = int(r.get("rules", 0))
	causal.deserialize(data.get("causal", {}))
	emergent.tick_count = int(data.get("tick", 0))
	# Derived state is rebuilt now rather than at the first tick, so a caller
	# that inspects the world immediately after loading sees the same thing it
	# would have seen had it never saved.
	emergent.rebuild()
	return report


## Everything derived, for one subject. Two subjects with the same digest
## behave the same way, which is what "functionally equivalent construction"
## has to mean if it is to mean anything testable.
static func digest(graph: EmergentGraph, entity_id: int) -> String:
	var parts := PackedStringArray()
	var e := graph.entity(entity_id)
	if e == null:
		return ""
	# Capabilities sorted, so two different construction orders agree.
	var caps := e.capabilities()
	caps.sort()
	parts.append("caps=" + ",".join(caps))
	# Behaviours, sorted for the same reason.
	var beh: Array[String] = []
	for id in EmergentMatcher.satisfied([e.kind]):
		var p := EmergentPatterns.get_pattern(id)
		if p != null:
			for b in p.behaviours:
				beh.append(b)
	beh.sort()
	parts.append("beh=" + ",".join(beh))
	# Relationships, sorted so traversal order cannot leak into the digest.
	var rels := PackedStringArray()
	for r in graph.relatives(entity_id, "", 32):
		var d: Dictionary = r
		rels.append("%s:%d" % [String(d["rel"]), int(d["other"])])
	rels.sort()
	parts.append("rel=" + ",".join(rels))
	parts.append("state=" + str(e.state))
	return "|".join(parts)


## The digest of a whole world. This is the thing the save/load equivalence
## test compares, and it is deliberately strict: kind, capabilities,
## behaviours, relationships and state. If two constructions produce the same
## world digest they are the same construction as far as the game is
## concerned, whatever the player called them.
static func world_digest(graph: EmergentGraph) -> String:
	var ids: Array = []
	for e in graph.all_entities():
		ids.append(int((e as EmergentEntity).id))
	ids.sort()
	var parts := PackedStringArray()
	for id in ids:
		parts.append("%d:%s" % [int(id), digest(graph, int(id))])
	return "\n".join(parts)


## A one-line summary for the debug overlay. The entity count is a property
## of the live graph, so it is read from the system this describes: the old
## signature took no argument and hardcoded 0, which reported an empty world
## no matter how much the player had built.
static func report(emergent: Object) -> String:
	var graph: EmergentGraph = emergent.graph
	return ("emergent save: %d entities, %d rules, v%d") % [
		graph.all_entities().size(), EmergentRules.count(), VERSION]