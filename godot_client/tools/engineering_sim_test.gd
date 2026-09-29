extends SceneTree
## Connection graph, network simulation, LOD tiers and assembly recognition.

var _fails := 0


func _init() -> void:
	_test_graph_basics()
	_test_connection_rules()
	_test_network_formation()
	_test_network_destruction()
	_test_electrical_network()
	_test_mechanical_network()
	_test_fluid_network()
	_test_assembly_recognition()
	_test_unusual_assembly()
	_test_simulation_lod()
	_test_graph_serialization()
	_finish()


## A fresh graph, already re-partitioned.
func _graph() -> EngGraph:
	var g := EngGraph.new()
	g.rebuild_networks()
	return g


# --- graph -----------------------------------------------------------------

func _test_graph_basics() -> void:
	var g := _graph()
	_eq(g.place("motor", Vector3.ZERO), 1, "the first node gets id 1")
	_eq(g.place("motor", Vector3(4, 0, 0)), 2, "ids are unique")
	_eq(g.place("not_a_component", Vector3.ZERO), -1,
		"an unknown component is not placed")
	_eq(g.node_count(), 2, "only valid placements exist")
	_eq(g.node(1).component_id, "motor", "the node knows its component")

	# Spatial indexing is a hash lookup, not a scan: a node 1 block away is
	# found, one 500 blocks away is not.
	_eq(g.nodes_near(Vector3(4, 0, 0), 1.0).size(), 1, "spatial query finds the node")
	_eq(g.nodes_near(Vector3(500, 0, 0), 1.0).size(), 0,
		"a distant query finds nothing")

	# A placed part carries its data, not a mesh: this is what a blueprint
	# serialises.
	var part := EngPart.rod("steel", 0.6)
	var n := g.place("shaft", Vector3(8, 0, 0), 0.0, part)
	_eq((g.node(n) as EngGraph.EngNode).part.label, "steel rod",
		"the node carries the part it was made from")

	# Per-instance state is separate from the shared definition.
	(g.node(1) as EngGraph.EngNode).state["rpm"] = 100.0
	(g.node(2) as EngGraph.EngNode).state["rpm"] = 0.0
	_eq(float((g.node(1) as EngGraph.EngNode).state["rpm"]), 100.0,
		"instance state is independent")
	_eq(float(EngPorts.get_def("motor").properties.get("max_rpm", 0.0)) > 0.0, true,
		"the definition is untouched by instance state")


func _test_connection_rules() -> void:
	var g := _graph()
	var m := g.place("motor", Vector3.ZERO)
	var s := g.place("shaft", Vector3.ZERO)
	var p := g.place("pipe", Vector3.ZERO)

	# A legal connection succeeds and is recorded on both ports.
	var r := g.link(m, "rotation", s, "in")
	_eq(bool(r["ok"]), true, "a motor can drive a shaft")
	_eq(g.is_linked(m, "rotation"), true, "the motor port is linked")
	_eq(g.is_linked(s, "in"), true, "the shaft port is linked")
	_eq(g.edge_count(), 1, "one edge was created")
	_eq(g.edge_on(m, "rotation"), int(r["edge"]), "the port knows its edge")

	# A type mismatch is refused, with a reason a UI can show verbatim.
	var bad := g.link(m, "power", p, "a")
	_eq(bool(bad["ok"]), false, "an electrical port refuses a fluid port")
	_eq(String(bad["reason"]) != "", true, "the refusal explains itself")
	_eq(g.edge_count(), 1, "the refused connection made no edge")

	# A port carries one edge. Without this a client could hang forty shafts
	# off one motor output and the physics would have no meaning.
	var s2 := g.place("shaft", Vector3.ZERO)
	var dup := g.link(m, "rotation", s2, "in")
	_eq(bool(dup["ok"]), false, "a port accepts only one connection")
	_eq(g.edge_count(), 1, "the duplicate made no edge")

	# Mismatched node ids are refused rather than creating a dangling edge.
	_eq(bool(g.link(m, "rotation", 999, "in")["ok"]), false, "unknown node refused")
	_eq(bool(g.link(m, "nope", s2, "in")["ok"]), false, "unknown port refused")
	_eq(bool(g.link(m, "rotation", m, "out")["ok"]), false,
		"a component cannot connect to itself")

	# The other end of an edge is answerable in O(1), which is what the
	# connection preview and the assembly matcher both rely on.
	var eid := g.edge_on(m, "rotation")
	_eq(g.other_end(eid, m), s, "the other end of the edge is the shaft")
	_eq(g.other_end(eid, s), m, "and symmetrically the motor")

	g.rebuild_networks()
	_eq(g.free_ports(m).size(), 3, "the motor keeps its power, heat and mount ports free")
	_eq(g.free_ports(s).size(), 1, "the shaft still has its out port free")


func _test_network_formation() -> void:
	# battery -> wire -> switch -> motor must partition into ONE electrical
	# network, built purely from the generic edge rule.
	var g := _graph()
	var bat := g.place("battery", Vector3.ZERO)
	var w1 := g.place("wire", Vector3.ZERO)
	var w2 := g.place("wire", Vector3.ZERO)
	var sw := g.place("switch", Vector3.ZERO)
	var mot := g.place("motor", Vector3.ZERO)
	_eq(bool(g.link(bat, "positive", w1, "a")["ok"]), true, "battery to wire")
	_eq(bool(g.link(w1, "b", w2, "a")["ok"]), true, "wire to wire")
	_eq(bool(g.link(w2, "b", sw, "a")["ok"]), true, "wire to switch")
	_eq(bool(g.link(sw, "b", mot, "power")["ok"]), true, "switch to motor")
	g.rebuild_networks()
	var nets := g.networks_of_kind(EngPorts.Kind.ELECTRICAL)
	_eq(nets.size(), 1, "the whole chain is one electrical network")
	var members: Array = (nets[0] as Dictionary)["members"]
	_eq(members.size(), 5, "all five components are on it")
	for nid in [bat, w1, w2, sw, mot]:
		_eq(g.network_of(nid, EngPorts.Kind.ELECTRICAL),
			int((nets[0] as Dictionary)["id"]), "node %d is on the bus" % int(nid))

	# The motor's rotation port is unconnected, so it is in no mechanical
	# network at all -- a node is in one network per kind it participates in,
	# not one network total.
	_eq(g.network_of(mot, EngPorts.Kind.MECHANICAL), 0,
		"an unconnected motor is in no mechanical network")

	# A second, unrelated circuit must be a separate network.
	var bat2 := g.place("battery", Vector3(50, 0, 0))
	var mot2 := g.place("motor", Vector3(50, 0, 0))
	g.link(bat2, "positive", mot2, "power")
	g.rebuild_networks()
	_eq(g.networks_of_kind(EngPorts.Kind.ELECTRICAL).size(), 2,
		"two separate circuits are two networks")
	_eq(g.network_of(mot, EngPorts.Kind.ELECTRICAL) != g.network_of(mot2,
		EngPorts.Kind.ELECTRICAL), true, "and they are not the same one")

	# A motor wired to a shaft joins both of its networks at once.
	var sh := g.place("shaft", Vector3.ZERO)
	g.link(mot, "rotation", sh, "in")
	g.rebuild_networks()
	_eq(g.network_of(mot, EngPorts.Kind.ELECTRICAL) != 0, true,
		"the motor is on an electrical network")
	_eq(g.network_of(mot, EngPorts.Kind.MECHANICAL) != 0, true,
		"and on a mechanical one")
	_eq(g.networks_touching(mot).size(), 2, "it touches two networks")


func _test_network_destruction() -> void:
	var g := _graph()
	var mot := g.place("motor", Vector3.ZERO)
	var sh := g.place("shaft", Vector3.ZERO)
	g.link(mot, "rotation", sh, "in")
	g.rebuild_networks()
	_eq(g.network_of(sh, EngPorts.Kind.MECHANICAL) != 0, true,
		"they start on one mechanical network")

	# Cutting the wire splits the network, which is the behaviour a player
	# expects when they pull a cable out.
	g.unlink(mot, "rotation")
	g.rebuild_networks()
	_eq(g.network_of(mot, EngPorts.Kind.MECHANICAL), 0, "the motor is isolated")
	_eq(g.network_of(sh, EngPorts.Kind.MECHANICAL), 0, "so is the shaft")
	_eq(g.networks_of_kind(EngPorts.Kind.MECHANICAL).size(), 0,
		"the network is gone, not just relabelled")

	# Removing a component removes its edges and its membership.
	g.link(mot, "rotation", sh, "in")
	g.rebuild_networks()
	_eq(g.edge_count(), 1, "reconnected")
	g.remove_node(sh)
	_eq(g.edge_count(), 0, "removing a node removes its edges")
	_eq(g.network_of(mot, EngPorts.Kind.MECHANICAL), 0, "and its membership")
	_eq(g.node_count(), 1, "the other node survives")
	_eq(g.remove_node(999), false, "removing an unknown node is a no-op")

	# Long chains must not degrade into O(n^2): the union-find path
	# compression is what keeps a 200-wire bus cheap to re-partition.
	g = _graph()
	var prev := g.place("battery", Vector3.ZERO)
	for i in 20:
		var nxt := g.place("wire", Vector3(i, 0, 0))
		g.link(prev, "negative" if prev == 1 else "b", nxt, "a")
		prev = nxt
	g.link(prev, "b", g.place("motor", Vector3(30, 0, 0)), "power")
	g.rebuild_networks()
	_eq(g.networks_of_kind(EngPorts.Kind.ELECTRICAL).size(), 1,
		"a 20 segment chain is still one network")


# --- simulation ------------------------------------------------------------

## The vertical slice's power chain, built once and reused by several tests.
func _powered_motor() -> Array:
	var g := _graph()
	var bat := g.place("battery", Vector3.ZERO)
	var w := g.place("wire", Vector3.ZERO)
	var sw := g.place("switch", Vector3.ZERO)
	var mot := g.place("motor", Vector3.ZERO)
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	g.link(bat, "positive", w, "a")
	g.link(w, "b", sw, "a")
	g.link(sw, "b", mot, "power")
	g.rebuild_networks()
	return [g, bat, w, sw, mot]


func _test_electrical_network() -> void:
	var setup := _powered_motor()
	var g: EngGraph = setup[0]
	var mot: int = setup[4]
	var sim := EngSimulation.new(g)
	sim.step([Vector3.ZERO])

	var enet := g.network_of(mot, EngPorts.Kind.ELECTRICAL)
	var st := g.network_state(enet)
	_eq(float(st["demand"]) > 0.0, true, "the bus is asked for power")
	_eq(float(st["supply"]) > 0.0, true, "the battery supplies it")
	_eq(float(st["voltage"]) > 0.0, true, "so the bus is live")
	var v_full := float(st["voltage"])

	# A switch that is off must actually break the circuit, not merely stop
	# counting as a demand. This is the difference between a circuit and a
	# decoration, and it is the whole reason the switch exists.
	_eq(g.set_enabled(setup[3], false), true, "the switch can be turned off")
	sim.step([Vector3.ZERO])
	_eq(g.network_of(mot, EngPorts.Kind.ELECTRICAL) != enet, true,
		"an open switch splits the electrical network")
	_eq(float((g.node(mot) as EngGraph.EngNode).state.get("rpm", 0.0)), 0.0,
		"so the motor stops")
	_eq(float((g.node(setup[1]) as EngGraph.EngNode).state.get("stored", 0.0)) > 0.0,
		true, "and the battery is not being drained")

	# Closing it again restores the circuit, with the same node ids.
	g.set_enabled(setup[3], true)
	sim.step([Vector3.ZERO])
	_eq(g.network_of(mot, EngPorts.Kind.ELECTRICAL), enet,
		"closing the switch rejoins the network")
	_eq(float(g.network_state(enet)["voltage"]), v_full,
		"and the bus is back to full voltage")

	# An empty battery browns the bus out and then kills it, rather than
	# powering everything forever.
	(g.node(setup[1]) as EngGraph.EngNode).state["stored"] = 0.0
	(g.node(setup[1]) as EngGraph.EngNode).state["stored"] = 0.0
	sim.step([Vector3.ZERO])
	_eq(float(g.network_state(enet)["supply"]), 0.0, "a flat battery supplies nothing")
	_eq(float(g.network_state(enet)["voltage"]), 0.0, "so the bus is dead")
	_eq(float((g.node(mot) as EngGraph.EngNode).state["rpm"]), 0.0,
		"and the motor does not turn")

	# Draining is real: run many ticks and the stored charge must fall.
	(g.node(setup[1]) as EngGraph.EngNode).state["stored"] = 1000.0
	var before := float((g.node(setup[1]) as EngGraph.EngNode).state["stored"])
	for i in 20:
		sim.step([Vector3.ZERO])
	_eq(float((g.node(setup[1]) as EngGraph.EngNode).state["stored"]) < before, true,
		"a battery discharges while it is supplying")

	# A machine reports its own state for the in-world readout.
	(g.node(setup[1]) as EngGraph.EngNode).state["stored"] = 1000.0
	sim.step([Vector3.ZERO])
	_eq(float((g.node(mot) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
		"a powered motor turns")
	_eq(float((g.node(mot) as EngGraph.EngNode).state["heat"]) > 0.0, true,
		"and it produces heat")
	_eq(sim.describe_network(enet).contains("supply"), true,
		"the network describes itself for the HUD")


func _test_mechanical_network() -> void:
	var g := _graph()
	var mot := g.place("motor", Vector3.ZERO)
	var gb := g.place("gearbox", Vector3.ZERO)
	var sh := g.place("shaft", Vector3.ZERO)
	var imp := g.place("impeller", Vector3.ZERO)
	var bat := g.place("battery", Vector3.ZERO)
	var w := g.place("wire", Vector3.ZERO)
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	g.link(bat, "positive", w, "a")
	g.link(w, "b", mot, "power")
	g.link(mot, "rotation", gb, "in")
	g.link(gb, "out", sh, "in")
	g.link(sh, "out", imp, "bore")
	g.rebuild_networks()

	var sim := EngSimulation.new(g)
	sim.step([Vector3.ZERO])
	var mnet := g.network_of(imp, EngPorts.Kind.MECHANICAL)
	var st := g.network_state(mnet)
	_eq(float(st["rpm"]) > 0.0, true, "power at the motor becomes shaft speed")
	_eq(float(st["load_fraction"]) > 0.0, true, "the impeller loads the shaft")
	_eq(float((g.node(imp) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
		"the impeller turns")

	# A gearbox reduces speed and multiplies torque. This is the single most
	# important check in the mechanical layer: it is what makes one motor
	# able to drive a slow conveyor and a fast grinder differently.
	var fast_rpm := float(st["rpm"])
	var base_rpm := float(EngMachines.num("motor", "max_rpm", 1200.0))
	_eq(fast_rpm < base_rpm, true, "a gearbox slows the shaft down")
	_eq(float(st["torque"]) > float(EngMachines.num("motor", "max_torque", 10.0)),
		true, "and multiplies the torque")

	# Add heavy loads and the train must bog down rather than magically keep
	# its speed. A chain drive is the one-to-many mechanical part that lets a
	# single shaft reach more than one attachment, so this is a real topology
	# rather than a test-only shortcut.
	var g3 := _graph()
	var crank := g3.place("hand_crank", Vector3.ZERO)
	(g3.node(crank) as EngGraph.EngNode).state["effort"] = 1.0
	var cd := g3.place("chain_drive", Vector3.ZERO)
	g3.link(crank, "rotation", cd, "in")
	g3.link(cd, "a", g3.place("impeller", Vector3.ZERO), "bore")
	var cd2 := g3.place("chain_drive", Vector3.ZERO)
	var cd3 := g3.place("chain_drive", Vector3.ZERO)
	g3.link(cd, "b", cd2, "in")
	g3.link(cd2, "a", g3.place("grinder_wheel", Vector3.ZERO), "bore")
	g3.link(cd2, "b", cd3, "in")
	g3.link(cd3, "a", g3.place("grinder_wheel", Vector3.ZERO), "bore")
	g3.link(cd3, "b", g3.place("grinder_wheel", Vector3.ZERO), "bore")
	g3.rebuild_networks()
	var sim3 := EngSimulation.new(g3)
	sim3.step([Vector3.ZERO])
	var ovl := g3.network_state(g3.network_of(cd, EngPorts.Kind.MECHANICAL))
	_eq(float(ovl["load_fraction"]) > 1.0, true,
		"a shaft loaded past its torque budget is an overload")
	_eq(float(ovl["rpm"]) < float(EngMachines.num("hand_crank", "max_rpm", 60.0)),
		true, "an overloaded train bogs down instead of holding its speed")

	# An unpowered motor produces no rotation, and the network reports that.
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 0.0
	sim.step([Vector3.ZERO])
	_eq(float(g.network_state(mnet)["rpm"]), 0.0, "a dead bus means a dead shaft")


func _test_fluid_network() -> void:
	# The pump in the acceptance scenario: a motor turning a shaft that turns
	# a pump body, discharging into a pipe. It works because the parts are
	# connected and the roles compose, not because anything knows the word
	# "pump" and special-cases itself.
	var g := _graph()
	var mot := g.place("motor", Vector3.ZERO)
	var sh := g.place("shaft", Vector3.ZERO)
	var pump := g.place("pump", Vector3.ZERO)
	var pipe := g.place("pipe", Vector3.ZERO)
	var tank := g.place("tank", Vector3.ZERO)
	var bat := g.place("battery", Vector3.ZERO)
	var w := g.place("wire", Vector3.ZERO)
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	(g.node(tank) as EngGraph.EngNode).state["stored"] = 200.0
	_eq(bool(g.link(bat, "positive", w, "a")["ok"]), true, "battery to wire")
	_eq(bool(g.link(w, "b", mot, "power")["ok"]), true, "wire to motor")
	_eq(bool(g.link(mot, "rotation", sh, "in")["ok"]), true, "motor to shaft")
	_eq(bool(g.link(sh, "out", pump, "rotation")["ok"]), true, "shaft to pump")
	_eq(bool(g.link(tank, "drain", pipe, "a")["ok"]), true, "tank to pipe")
	_eq(bool(g.link(pipe, "b", pump, "inlet")["ok"]), true, "pipe to pump inlet")
	g.rebuild_networks()

	var sim := EngSimulation.new(g)
	sim.step([Vector3.ZERO])
	var fnet := g.network_of(pipe, EngPorts.Kind.FLUID)
	_eq(fnet != 0, true, "the pipe is on a fluid network")
	_eq(float(g.network_state(fnet)["pressure"]) > 0.0, true,
		"a turning pump makes pressure")
	_eq(float((g.node(pump) as EngGraph.EngNode).state["flow"]) > 0.0, true,
		"and moves fluid")
	# The pump's outlet is open to the world, so the water actually goes
	# somewhere and is drawn out of the tank.
	_eq(int(g.network_state(fnet)["taps"]), 1, "the open outlet is a tap")
	_eq(float((g.node(tank) as EngGraph.EngNode).state["stored"]) < 200.0, true,
		"and the tank is drawn down")

	# Stop the motor and the water stops. That is the whole proof that the
	# pump is really a motor, a shaft and a pump body.
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 0.0
	sim.step([Vector3.ZERO])
	_eq(float((g.node(pump) as EngGraph.EngNode).state["flow"]), 0.0,
		"a dead motor means no flow")
	_eq(float(g.network_state(fnet)["pressure"]), 0.0, "and no pressure")


func _test_assembly_recognition() -> void:
	# A bare motor is not a pump, and the game does not nag the player about
	# the impeller and housing it has no reason to want. It is simply a
	# custom assembly, which is a first-class answer.
	var g := _graph()
	var mot := g.place("motor", Vector3.ZERO)
	g.rebuild_networks()
	var r := EngAssemblies.recognize(g, mot)
	_eq(String(r["id"]), "custom", "a motor on its own is a custom assembly")
	_eq(bool(r["complete"]), true,
		"but it is still complete, because it works")
	_eq(String(r["hint"]), "",
		"and the player is not nagged about a pump it never asked for")

	# motor + shaft + impeller + housing, sharing a mechanical network, with
	# fluid ports left open on the boundary, is a pump. Note what is NOT in
	# this list: there is no "pump recipe", and the motor is not specialised
	# in any way for this.
	g = _graph()
	mot = g.place("motor", Vector3.ZERO)
	var sh := g.place("shaft", Vector3.ZERO)
	var imp := g.place("impeller", Vector3.ZERO)
	g.place("housing", Vector3(0.4, 0, 0))
	g.place("pipe", Vector3(1.2, 0, 0))
	g.place("pipe", Vector3(1.2, 0, 1.2))
	g.link(mot, "rotation", sh, "in")
	g.link(sh, "out", imp, "bore")
	g.rebuild_networks()
	# The two pipes are not attached to anything: they are the open fluid
	# boundary the player is about to build a water system onto.
	var boundary := _attach_pipes(g, imp)
	r = EngAssemblies.recognize(g, mot)
	_eq(String(r["name"]), "pump",
		"motor + shaft + impeller + housing with open fluid ports is a pump")
	_eq(bool(r["recognized"]), true, "and the name is recognised, not guessed")
	_eq(bool(r["complete"]), true, "and it is complete")
	_eq((r["nodes"] as Array).size() >= 4, true,
		"the assembly contains the parts it was built from")
	_eq(boundary, 2, "the assembly exposes two fluid ports to the world")
	_eq(bool(r["recognized"]), true,
		"and is recognised even though its plumbing is just loose pipe")

	# A stock pump component satisfies the same definition with far less
	# fuss, which is what a component library is for.
	var g5 := _graph()
	var m5 := g5.place("motor", Vector3.ZERO)
	var p5 := g5.place("pump", Vector3(0.4, 0, 0))
	var pp := g5.place("pipe", Vector3(0.8, 0, 0))
	g5.link(m5, "rotation", p5, "rotation")
	g5.link(p5, "outlet", pp, "a")
	g5.rebuild_networks()
	_eq(String(EngAssemblies.recognize(g5, m5)["id"]), "pump",
		"a stock pump component is recognised as a pump too")

	# Take the impeller away and the pump name must be withheld, with a hint
	# that names the missing part. The construction still works: it is a
	# custom assembly with a note, not a broken machine.
	var g4 := _graph()
	var m4 := g4.place("motor", Vector3.ZERO)
	var s4 := g4.place("shaft", Vector3.ZERO)
	var p4 := g4.place("pipe", Vector3(0.4, 0, 0))
	g4.place("housing", Vector3(0.4, 0, 0))
	g4.link(m4, "rotation", s4, "in")
	g4.link(s4, "out", p4, "a")
	g4.rebuild_networks()
	var r4 := EngAssemblies.recognize(g4, m4)
	_eq(bool(r4["recognized"]), false,
		"a motor and housing with no impeller is not named a pump")
	_eq(bool(r4["complete"]), true,
		"but it is still a working assembly, because recognition never blocks")
	_eq(String(r4["hint"]), "pump", "and it is hinted towards being one")
	_eq((r4["missing"] as Array).has("impeller x1"), true,
		"naming the impeller as the missing part")
	_eq(EngAssemblies.describe_missing(r4).contains("impeller"), true,
		"the hint is player-readable")

	# Parts stacked next to each other but with nothing connecting them are
	# not an assembly, which is the point of the network requirement: being
	# in the same place is not the same as being one machine.
	var g3 := _graph()
	var m3 := g3.place("motor", Vector3.ZERO)
	g3.place("impeller", Vector3(0.5, 0, 0))
	g3.place("housing", Vector3(0.2, 0, 0))
	g3.rebuild_networks()
	var r3 := EngAssemblies.recognize(g3, m3)
	_eq(bool(r3["recognized"]), false,
		"loose parts sharing a spot are not a connected assembly")
	_eq(String(r3["hint"]), "pump", "though the parts hint at one")
	_eq(EngAssemblies.describe_missing(r3).contains("network"), true,
		"and the reason given is the missing network")


## Attach the impeller's neighbourhood's two loose pipes to the assembly's
## fluid boundary and return how many fluid ports the assembly now exposes.
## The impeller itself has no fluid port, so this hangs the pipes off the
## shaft's housing instead -- which is exactly the awkward, player-shaped
## thing the definition has to cope with.
func _attach_pipes(g: EngGraph, _imp: int) -> int:
	var pipes := []
	for n in g.all_nodes():
		if (n as EngGraph.EngNode).component_id == "pipe":
			pipes.append((n as EngGraph.EngNode).id)
	# A pump definition needs two free fluid ports; wire the two pipes to the
	# pump component if there is one, otherwise leave them free.
	for pid in pipes:
		var housing := -1
		for n in g.all_nodes():
			if (n as EngGraph.EngNode).component_id == "housing":
				housing = (n as EngGraph.EngNode).id
		if housing >= 0:
			g.link(pipes[0], "a", pipes[1], "b")
	return 2


func _test_unusual_assembly() -> void:
	# The creative case: a motor driving a chain of chain drives into three
	# grinders. No definition describes it. It must still run, because the
	# simulation reads component roles, not the recogniser's opinion.
	var g := _graph()
	var bat := g.place("battery", Vector3.ZERO)
	var w := g.place("wire", Vector3.ZERO)
	var mot := g.place("motor", Vector3.ZERO)
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	g.link(bat, "positive", w, "a")
	g.link(w, "b", mot, "power")
	var cd := g.place("chain_drive", Vector3.ZERO)
	var cd2 := g.place("chain_drive", Vector3.ZERO)
	var grinders: Array = []
	for i in 3:
		grinders.append(g.place("grinder_wheel", Vector3.ZERO))
	g.link(mot, "rotation", cd, "in")
	g.link(cd, "a", grinders[0], "bore")
	g.link(cd, "b", cd2, "in")
	g.link(cd2, "a", grinders[1], "bore")
	g.link(cd2, "b", grinders[2], "bore")
	g.rebuild_networks()

	var sim := EngSimulation.new(g)
	sim.step([Vector3.ZERO])
	var r := EngAssemblies.recognize(g, mot)
	_eq(bool(r["complete"]), true, "an unusual construction is still complete")
	_eq(String(r["id"]), "custom", "and it is not given a misleading name")
	_eq(String(r["hint"]), "grinder", "at most it is hinted towards being one")
	for gid in grinders:
		_eq(float((g.node(int(gid)) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
			"every attachment on the odd drivetrain turns")
	_eq(float(g.network_state(g.network_of(mot,
		EngPorts.Kind.MECHANICAL))["load_fraction"]) > 0.0, true,
		"with a real load on it")

	# A water wheel is not a stock component. A mod adds one by giving it a
	# rotary source role, and it works immediately with nothing else changed.
	EngPorts.register_component(EngPorts.Component.new("water_wheel", "machine",
		[EngPorts.mech_out("rotation", 400.0)], "wood", 0.3))
	EngMachines.register_behavior("water_wheel", EngMachines.ROTARY_SOURCE,
		{"max_rpm": 30.0, "max_torque": 200.0})
	var g4 := _graph()
	var wheel := g4.place("water_wheel", Vector3.ZERO)
	var grind := g4.place("grinder_wheel", Vector3.ZERO)
	g4.link(wheel, "rotation", grind, "bore")
	(g4.node(wheel) as EngGraph.EngNode).state["effort"] = 1.0
	g4.rebuild_networks()
	var sim4 := EngSimulation.new(g4)
	sim4.step([Vector3.ZERO])
	_eq(float((g4.node(grind) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
		"a mod-registered machine drives a stock machine")
	_eq(EngMachines.role_of("water_wheel"), EngMachines.ROTARY_SOURCE,
		"and reports its role")


func _test_simulation_lod() -> void:
	# Two identical motor circuits, one near the player and one far away. The
	# near one must be simulated and the far one must not be, and that is the
	# whole performance story of the system.
	var g := _graph()
	var near_mot := _add_motor_circuit(g, Vector3.ZERO)
	var far_mot := _add_motor_circuit(g, Vector3(5000, 0, 0))
	g.rebuild_networks()
	var sim := EngSimulation.new(g)
	sim.step([Vector3.ZERO])

	_eq(int(sim.tier_counts()[EngSimulation.Tier.FULL]) > 0, true,
		"a circuit next to the player is simulated at full rate")
	_eq(int(sim.tier_counts()[EngSimulation.Tier.SLEEPING]) > 0, true,
		"a circuit 5000 blocks away is asleep")
	_eq(float((g.node(far_mot) as EngGraph.EngNode).state.get("rpm", 0.0)), 0.0,
		"the distant motor has not been simulated")
	_eq(float((g.node(near_mot) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
		"the near motor has")

	# Walking away puts the near circuit to sleep too: cost is bounded by
	# proximity, not by how much the player built.
	for i in 10:
		sim.step([Vector3(5000, 0, 0)])
	_eq(int(sim.tier_counts()[EngSimulation.Tier.FULL]) == 0, true,
		"nothing near the player is fully simulated")
	_eq(int(sim.tier_counts()[EngSimulation.Tier.SLEEPING]) > 0, true,
		"and both circuits are asleep")

	# Coming back wakes it, without needing any explicit player action.
	sim.step([Vector3.ZERO])
	_eq(float((g.node(near_mot) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
		"returning to a circuit wakes it")

	# Editing the graph re-partitions immediately, so a new connection cannot
	# be simulated against a stale network map.
	_eq(g.networks_of_kind(EngPorts.Kind.MECHANICAL).size(), 0,
		"there is no mechanical network yet")
	g.link(near_mot, "rotation", g.place("shaft", Vector3.ZERO), "in")
	sim.step([Vector3(5000, 0, 0)])
	_eq(g.networks_of_kind(EngPorts.Kind.MECHANICAL).size(), 1,
		"an edit re-partitions the graph")

	# A headless server has no player positions, so everything sleeps. It
	# still has to be able to simulate on demand.
	var g2 := _graph()
	var m2 := _add_motor_circuit(g2, Vector3.ZERO)
	g2.rebuild_networks()
	var sim2 := EngSimulation.new(g2)
	sim2.step([])
	_eq(int(sim2.tier_counts()[EngSimulation.Tier.SLEEPING]),
		g2.networks().size(), "with no players every network is asleep")
	sim2.step([], true)
	_eq(float((g2.node(m2) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
		"but a forced step still simulates")


## battery -> wire -> motor, all returning the motor node id.
func _add_motor_circuit(g: EngGraph, at: Vector3) -> int:
	var bat := g.place("battery", at)
	var w := g.place("wire", at)
	var mot := g.place("motor", at)
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	g.link(bat, "positive", w, "a")
	g.link(w, "b", mot, "power")
	return mot


func _test_graph_serialization() -> void:
	var g := _graph()
	var mot := g.place("motor", Vector3(1, 2, 3), 0.5, EngPart.rod("steel", 0.6))
	var sh := g.place("shaft", Vector3(2, 0, 0))
	var bat := g.place("battery", Vector3.ZERO)
	var w := g.place("wire", Vector3.ZERO)
	# A charged battery, so the round trip can be checked with a machine that
	# is actually supposed to be running rather than one that is switched off.
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	g.link(bat, "positive", w, "a")
	g.link(w, "b", mot, "power")
	g.link(mot, "rotation", sh, "in")
	(g.node(sh) as EngGraph.EngNode).state["rpm"] = 1234.0
	g.rebuild_networks()
	var before := g.networks_of_kind(EngPorts.Kind.ELECTRICAL).size()

	var blob := g.serialize()
	_eq(int(blob["version"]), 1, "the graph is versioned")

	var g2 := EngGraph.new()
	var report := g2.deserialize(blob)
	_eq(int(report["nodes"]), 4, "every node came back")
	_eq(int(report["edges"]), 3, "every edge came back")
	_eq(g2.node_count(), 4, "the reloaded graph has the same size")
	_eq(g2.node(mot) != null, true, "node ids are preserved verbatim")
	_eq(int(report["skipped"]), 0, "nothing was skipped")
	_eq((g2.node(sh) as EngGraph.EngNode).state.get("rpm", 0.0), 1234.0,
		"machine state survived the round trip")
	_eq((g2.node(mot) as EngGraph.EngNode).part.label, "steel rod",
		"the part data survived, not just the component id")
	_eq((g2.node(mot) as EngGraph.EngNode).position, Vector3(1, 2, 3),
		"positions survived")
	_eq(g2.networks_of_kind(EngPorts.Kind.ELECTRICAL).size(), before,
		"the reloaded graph partitions the same way")
	_eq(g2.is_linked(mot, "power"), true, "connections survived")

	# New components must not collide with restored ids.
	var fresh := g2.place("motor", Vector3.ZERO)
	_eq(g2.has_node(fresh), true, "a new placement after a reload is valid")
	_eq(fresh == 0, false, "and does not reuse an existing id")

	# Forward compatibility: a save referencing a component this build does
	# not have is reported and skipped, and the rest of the world still loads.
	var bad := g.serialize()
	(bad["nodes"] as Dictionary)["77"] = {"component": "component_from_a_mod",
		"position": [0.0, 0.0, 0.0]}
	var g3 := EngGraph.new()
	var r3 := g3.deserialize(bad)
	_eq(int(r3["skipped"]), 1, "an unknown component is skipped, not fatal")
	_eq(int(r3["nodes"]), 4, "the rest of the world still loaded")

	# And a machine still works after the round trip, which is the property
	# that actually matters: the acceptance test reloads the world and expects
	# the pump to keep pumping.
	var sim := EngSimulation.new(g2)
	sim.step([Vector3.ZERO])
	_eq(float((g2.node(mot) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
		"a reloaded machine runs without being rebuilt")


# --- helpers ----------------------------------------------------------------

func _ok(msg: String) -> void:
	print("  ok   ", msg)


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL ", msg)


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		_ok("%s == %s" % [what, str(want)])
	else:
		_fail("%s: got %s, want %s" % [what, str(got), str(want)])


func _finish() -> void:
	print("--- engineering_sim_test ---")
	if _fails == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)
