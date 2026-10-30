extends RefCounted

## Generator coverage beyond Control: Node, Node3D, signals, Resource, a RefCounted script whose
## base template initializes it, abstract natives, and rejections. Sweet UI's suite covers the rest.

const Generator = preload("res://addons/_lib/node_wrapper/src/generator.gd")
const Profile = preload("res://addons/_lib/node_wrapper/src/profile.gd")
const DefaultBases = preload("res://addons/_lib/node_wrapper/src/default_bases.gd")
const DATA_FIXTURE = "res://addons/_lib/node_wrapper/_export_ignore/test/fixtures/data_fixture.gd"

const MIXED_SOURCE = """extends RefCounted

const RE_EXPORT = %s
const TYPES = {}


class SwNode extends RefCounted:
	var _object

	func name(value: String) -> SwNode:
		_object.name = value
		return self


class SwNode3D extends SwNode:
	#! set position, visible
	pass


class SwMeshInstance3D extends SwNode3D:
	#! set material_override
	pass


class SwTimer extends SwNode:
	#! set wait_time, timeout
	pass


class SwCanvasItem extends SwNode:
	#! set visible
	pass


class SwStyleBoxFlat extends RefCounted:
	#! set bg_color
	var _object
"""

const DATA_SOURCE = """extends RefCounted

const Data = preload("%s")
const TYPES = {"SwData": {"node": Data, "factory": "data"}}


class SwData extends RefCounted:
	#! set value
	var _object
"""

static var _checks := 0
static var _failures: Array[String] = []


static func run_tests() -> Dictionary:
	_checks = 0
	_failures.clear()
	var workspace = _workspace()
	_check_bases()
	# A runtime error aborts a chain midway; only a completed chain returns true.
	for re_export in [false, true]:
		_check("mixed chain completes" + (" (re-export)" if re_export else ""), _check_mixed(workspace, re_export) == true)
	_check("data chain completes", _check_data_init(workspace) == true)
	_check_rejections(workspace)
	_check_written(workspace)
	_check("named chain completes", _check_named_first_load(workspace) == true)
	_remove_workspace(workspace)
	var output: Array = ["Node Wrapper: %d checks, %d failures" % [_checks, _failures.size()]]
	output.append_array(_failures)
	return {"result": _failures.size(), "output": output}


static func _check_bases() -> void:
	var profile = DefaultBases.profile()
	profile.bases["Resource"] = profile.bases["RefCounted"]
	var generator = Generator.new(profile)
	_check("Node3D resolves to the Node base", generator._base_for("Node3D") == "Node")
	_check("Resource subtype prefers the most derived base", generator._base_for("StyleBoxFlat") == "Resource")
	_check("plain RefCounted resolves", generator._base_for("RefCounted") == "RefCounted")
	_check("bare Object is unsupported", generator._base_for("Object") == "")
	_check("unknown class is unsupported", generator._base_for("NotAClass") == "")
	profile.bases["Object"] = profile.bases["RefCounted"]
	_check("bare Object stays unsupported with an Object base", generator._base_for("Object") == "")
	_check("an Object base still serves Node and RefCounted", generator._base_for("Node") == "Node" and generator._base_for("Resource") == "Resource")


static func _check_mixed(workspace: String, re_export: bool) -> bool:
	var label = " (re-export)" if re_export else ""
	var generator = Generator.new(DefaultBases.profile())
	var source = _write(workspace.path_join("mixed.gd"), MIXED_SOURCE % str(re_export))
	var result = _build(generator, workspace, source)
	_check("mixed bases compile" + label, result.error == OK)
	if result.error != OK:
		_failures.append("  " + result.get("message", ""))
		return false
	var root = Node3D.new()
	var owner = result.validation.new(root)
	var spatial = owner.node_3d().position(Vector3(1, 2, 3)).visible(false).name("Spatial")
	_check("Node3D factory attaches to the owner's node" + label, spatial.obj().get_parent() == root and spatial.owner() == owner)
	_check("Node3D setters and inherited operations apply" + label, spatial.obj().position == Vector3(1, 2, 3) and not spatial.obj().visible and spatial.obj().name == "Spatial")
	var adopted_node = Node3D.new()
	var other_parent = Node.new()
	_check("Node3D from wraps a supplied node and parent" + label, owner.node_3d_from(adopted_node, other_parent).obj() == adopted_node and adopted_node.get_parent() == other_parent)
	var material = StandardMaterial3D.new()
	_check("union-hinted setter takes one value" + label, owner.mesh_instance_3d().material_override(material).obj().material_override == material)
	_check("union-hinted setter is typed by its setter" + label, result.classes_source.contains("func material_override(value: Material) ->"))
	var events: Array = []
	var timer = owner.timer().wait_time(2.5).timeout(func(): events.append(true))
	timer.obj().timeout.emit()
	_check("Timer signal connector connects" + label, events == [true] and is_equal_approx(timer.obj().wait_time, 2.5))
	var style = owner.style_box_flat().bg_color(Color.RED)
	_check("Resource factory wraps without a parent" + label, style.obj() is StyleBoxFlat and style.obj().bg_color == Color.RED and style.owner() == owner)
	var supplied = StyleBoxFlat.new()
	_check("Resource from wraps a supplied resource" + label, owner.style_box_flat_from(supplied).obj() == supplied)
	var statics = result.validation.get_script_constant_map()[generator.profile.statics_const]
	_check("static Resource factory constructs" + label, statics.style_box_flat().obj() is StyleBoxFlat)
	var detached = statics.node_3d()
	_check("static Node factory leaves the node detached" + label, detached.obj() is Node3D and detached.obj().get_parent() == null and detached.owner() == null)
	detached.obj().free()
	detached = null
	_check("abstract native gets a wrapper class" + label, result.classes_source.contains("class SwCanvasItem extends RefCounted"))
	_check("abstract native gets no factories" + label, not owner.has_method("canvas_item") and not owner.has_method("canvas_item_from") and not statics.has_method("canvas_item"))
	root.free()
	other_parent.free()
	owner = null
	spatial = null
	timer = null
	style = null
	_check("validation types release" + label, generator.clear_validation(result.validation) == OK)


## The base template, not the generator, decides what construction does.
	return true


static func _check_data_init(workspace: String) -> bool:
	var profile = DefaultBases.profile()
	var base: Dictionary = profile.bases["RefCounted"].duplicate()
	base["class"] = base["class"].replace("\t\t_object = object\n", "\t\t_object = object\n\t\t_object.set_data({\"wrapped\": true})\n")
	profile.bases = {"RefCounted": base}
	var generator = Generator.new(profile)
	var source = _write(workspace.path_join("data.gd"), DATA_SOURCE % DATA_FIXTURE)
	var result = _build(generator, workspace, source)
	_check("custom RefCounted target compiles", result.error == OK)
	if result.error != OK:
		_failures.append("  " + result.get("message", ""))
		return false
	var owner = result.validation.new()
	var wrapped = owner.data().value(5)
	_check("base template _init runs set_data", wrapped.obj().data == {"wrapped": true})
	_check("script property setter applies", wrapped.obj().value == 5)
	_check("custom target is imported by alias", result.classes_source.contains("const Data = preload("))
	owner = null
	wrapped = null
	_check("custom validation types release", generator.clear_validation(result.validation) == OK)
	return true


static func _check_rejections(workspace: String) -> void:
	var control_only = DefaultBases.profile()
	control_only.bases = {"Control": control_only.bases["Node"]}
	var bodies = {
		"bare Object": ["class SwObject extends RefCounted:\n\tvar _object\n", DefaultBases.profile()],
		"type outside the profile's bases": ["class SwNode3D extends RefCounted:\n\tvar _object\n", control_only],
		"unknown native": ["class SwMissing extends RefCounted:\n\tvar _object\n", DefaultBases.profile()],
		"prototype redefining a template accessor": ["class SwNode extends RefCounted:\n\tvar _object\n\n\tfunc obj():\n\t\treturn _object\n", DefaultBases.profile()],
		"prototype redefining a RefCounted-only template func": ["class SwStyleBoxFlat extends RefCounted:\n\tvar _object\n\n\tfunc _with_owner():\n\t\treturn self\n", DefaultBases.profile()],
		"setter shadowing a template func": ["class SwNode extends RefCounted:\n\t#! set owner\n\tvar _object\n", DefaultBases.profile()],
		"state other than the profile member": ["class SwNode extends RefCounted:\n\tvar _control\n", DefaultBases.profile()],
	}
	for label in bodies:
		var source = _write(workspace.path_join("rejected.gd"), "extends RefCounted\n\n\n" + bodies[label][0])
		var result = _build(Generator.new(bodies[label][1]), workspace, source)
		_check(label + " rejected", result.error != OK)


static func _check_written(workspace: String) -> void:
	var profile = DefaultBases.profile()
	profile.header = "# Generated for the node_wrapper suite."
	var generator = Generator.new(profile)
	var source = _write(workspace.path_join("written.gd"), MIXED_SOURCE % "false")
	var target = workspace.path_join("out/owner.gd")
	var classes = workspace.path_join("out/wrappers_generated.gd")
	var statics = workspace.path_join("out/wrappers.gd")
	var result = generator.generate_file(target, source, classes, statics, "", "")
	_check("generation writes outputs", result.error == OK and result.changed)
	var owner_text = FileAccess.get_file_as_string(target)
	_check("unnamed owner drops class_name and aliases itself", not owner_text.begins_with("class_name") and owner_text.contains("const _WrapperOwner = preload(\"owner.gd\")"))
	_check("profile header is emitted", FileAccess.get_file_as_string(classes).contains(profile.header) and FileAccess.get_file_as_string(statics).contains(profile.header))
	_check("statics const preloads the statics file", owner_text.contains("const Wrappers = preload(\"wrappers.gd\")"))
	result = generator.generate_file(target, source, classes, statics, "", "")
	_check("unchanged regeneration writes nothing", result.error == OK and not result.changed)
	_check("no staging files remain", DirAccess.get_files_at(workspace.path_join("out")).size() == 3)


## The name is never registered, so loading proves only the owner relies on its global class.
static func _check_named_first_load(workspace: String) -> bool:
	var generator = Generator.new(DefaultBases.profile())
	var source = _write(workspace.path_join("named.gd"), MIXED_SOURCE % "false")
	var target = workspace.path_join("named/owner.gd")
	var classes = workspace.path_join("named/gen/wrappers_generated.gd")
	var statics = workspace.path_join("named/wrappers.gd")
	var result = generator.generate_file(target, source, classes, statics, "", "UnregisteredWrap")
	_check("named build writes outputs", result.error == OK)
	var bare_name = RegEx.create_from_string("\\bUnregisteredWrap\\b")
	_check("only the owner names its class", FileAccess.get_file_as_string(target).begins_with("class_name UnregisteredWrap\n") and [classes, statics].all(func(path): return bare_name.search(FileAccess.get_file_as_string(path)) == null))
	_check("wrappers preload the owner", FileAccess.get_file_as_string(classes).contains("const _WrapperOwner = preload(\"../owner.gd\")"))
	var owner_script: GDScript = ResourceLoader.load(target, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check("named owner loads before registration", owner_script != null and owner_script.can_instantiate())
	if owner_script == null or not owner_script.can_instantiate():
		return false
	var root = Node3D.new()
	var spatial = owner_script.new(root).node_3d().position(Vector3.ONE).obj()
	_check("named owner chains on first load", spatial.get_parent() == root and spatial.position == Vector3.ONE)
	root.free()
	return true


static func _build(generator: Generator, workspace: String, source: String) -> Dictionary:
	return generator.build_candidate(source, workspace.path_join("owner.gd"), workspace.path_join("gen/wrappers_generated.gd"), workspace.path_join("wrappers.gd"), "", generator.profile.owner_name)


static func _workspace() -> String:
	var temp_dir = OS.get_environment("TMPDIR")
	if temp_dir.is_empty():
		temp_dir = "/tmp"
	temp_dir = temp_dir.path_join("node_wrapper_%d" % Time.get_ticks_usec())
	_check("temporary workspace created", DirAccess.make_dir_recursive_absolute(temp_dir) == OK)
	return temp_dir


static func _remove_workspace(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for dir in DirAccess.get_directories_at(path):
		_remove_workspace(path.path_join(dir))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


static func _write(path: String, source: String) -> String:
	var file = FileAccess.open(path, FileAccess.WRITE)
	_check("temporary file writable: " + path.get_file(), file != null)
	if file != null:
		file.store_string(source)
		file.close()
	return path


static func _check(label: String, passed: bool) -> void:
	_checks += 1
	if not passed:
		_failures.append("FAIL " + label)
