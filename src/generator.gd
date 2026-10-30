#! namespace NodeWrapper class Generator
extends RefCounted

## Generates chainable wrapper classes, owner factories and static factories from prototype classes.
## A Profile supplies naming, output layout and the per-base templates; see README.md.

const Parser = preload("res://addons/_lib/gdscript_parser/src/gdscript_parser.gd")
const Lexer = preload("res://addons/_lib/gdscript_parser/src/utils/lambda_scanner.gd")
const TagScanner = preload("res://addons/_lib/editor_parser/src/tag/scanner.gd")
const Profile = preload("res://addons/_lib/node_wrapper/src/profile.gd")

## A bare Object would never be freed, so wrapped types must be one of these.
const ROOTS = ["Node", "RefCounted"]

var profile: Profile


func _init(profile_: Profile) -> void:
	profile = profile_


func register_setting() -> void:
	if profile.targets_setting.is_empty():
		return
	if not ProjectSettings.has_setting(profile.targets_setting):
		ProjectSettings.set_setting(profile.targets_setting, profile.default_targets)
	ProjectSettings.set_initial_value(profile.targets_setting, profile.default_targets)
	ProjectSettings.add_property_info({"name": profile.targets_setting, "type": TYPE_DICTIONARY,
		"hint": PROPERTY_HINT_DICTIONARY_TYPE, "hint_string": "String;String"})


func report(result: Dictionary) -> Error:
	if result.error != OK:
		push_error(result.message)
	else:
		if result.changed:
			print("%s generated." % profile.label)
		if result.changed and Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
			_scan_editor.call_deferred()
	return result.error


## Plugin enable can run inside the initial scan; rescanning there re-enters plugin setup.
static func _scan_editor() -> void:
	var filesystem = Engine.get_singleton(&"EditorInterface").get_resource_filesystem()
	while filesystem.is_scanning():
		await Engine.get_main_loop().process_frame
	filesystem.scan()


## Enable repairs missing outputs; explicit generation also incorporates source changes.
func setup(force: bool = false, only: String = "") -> Dictionary:
	register_setting()
	var read = read_targets()
	if read.error != OK:
		return read
	var targets: Dictionary = read.targets
	only = only.simplify_path().trim_suffix("/")
	if not only.is_empty() and not targets.has(only):
		return _failure("No %s target configured for %s in %s." % [profile.label, only, profile.targets_setting])
	var changed = false
	for directory: String in targets:
		if only.is_empty() or directory == only:
			var result = setup_directory(directory, force, targets[directory])
			if result.error != OK:
				return result
			changed = changed or result.changed
	return {"error": OK, "changed": changed}


## Validates every target before any of them writes.
func read_targets() -> Dictionary:
	var configured = ProjectSettings.get_setting(profile.targets_setting, profile.default_targets)
	if configured is not Dictionary:
		return _failure("%s must map project directories to class names." % profile.targets_setting)
	var addon_dir = profile.addon_dir.simplify_path().trim_suffix("/")
	var targets: Dictionary = {}
	for key in configured:
		var directory = str(key).simplify_path().trim_suffix("/")
		var name = configured[key]
		if not directory.begins_with("res://") or directory == "res:" or (not addon_dir.is_empty() and (directory == addon_dir or directory.begins_with(addon_dir + "/"))):
			return _failure("%s needs a project directory outside its addon: %s" % [profile.label, directory])
		if name is not String or not (name.is_empty() or name.is_valid_ascii_identifier()) or ClassDB.class_exists(name):
			return _failure("Invalid %s class name for %s: %s" % [profile.label, directory, name])
		for other: String in targets:
			if directory == other or directory.begins_with(other + "/") or other.begins_with(directory + "/"):
				return _failure("%s targets cannot overlap: %s, %s" % [profile.label, other, directory])
			if not name.is_empty() and targets[other] == name:
				return _failure("%s class name used by two targets: %s" % [profile.label, name])
		var target = directory.path_join(profile.owner_file)
		for entry in ProjectSettings.get_global_class_list():
			if not name.is_empty() and entry.class == name and entry.path != target and FileAccess.file_exists(entry.path):
				return _failure("%s already exists at %s. Move its directory through Godot before changing %s." % [name, entry.path, profile.targets_setting])
		targets[directory] = name
	return {"error": OK, "targets": targets}


func setup_directory(directory: String, force: bool, class_name_: String) -> Dictionary:
	var source = directory.path_join(profile.source_file)
	var target = directory.path_join(profile.owner_file)
	var classes = directory.path_join(profile.classes_file)
	var statics = directory.path_join(profile.statics_file)
	var seeded = false
	if not FileAccess.file_exists(source):
		if profile.seed_template.is_empty():
			return _failure("Cannot read %s source template." % profile.label, ERR_FILE_NOT_FOUND)
		var written = write_outputs({source: profile.seed_template})
		if written.error != OK:
			return written
		seeded = true
	if not force and not seeded and _has_name(target, class_name_) and FileAccess.file_exists(classes) and FileAccess.file_exists(statics):
		return {"error": OK, "changed": false}
	return generate_file(target, source, classes, statics, "", class_name_)


## A renamed target counts as stale output, like a missing file.
static func _has_name(target: String, class_name_: String) -> bool:
	if not FileAccess.file_exists(target):
		return false
	var declaration = FileAccess.get_file_as_string(target).get_slice("\n", 0)
	return declaration == "class_name " + class_name_ if not class_name_.is_empty() else not declaration.begins_with("class_name ")


func generate_file(target_path: String, source_path: String, classes_path: String, statics_path: String, template_source: String, class_name_: String) -> Dictionary:
	var result = build_candidate(source_path, target_path, classes_path, statics_path, template_source, class_name_)
	if result.error != OK:
		return result
	clear_validation(result.validation)
	return write_outputs({classes_path: result.classes_source, statics_path: result.sweets_source, target_path: result.source})


func write_outputs(outputs: Dictionary) -> Dictionary:
	var pending: Array[String] = []
	for path: String in outputs:
		if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == outputs[path]:
			continue
		var directory_error = DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		if directory_error != OK:
			_clear_staging(pending)
			return _failure("Cannot create generated %s directory: %s" % [profile.label, path.get_base_dir()], directory_error)
		pending.append(path)
		var file = FileAccess.open(path + ".nw.tmp", FileAccess.WRITE)
		if file == null:
			_clear_staging(pending)
			return _failure("Cannot stage generated %s: %s" % [profile.label, path], FileAccess.get_open_error())
		file.store_string(outputs[path])
		var error = file.get_error()
		file.close()
		if error != OK:
			_clear_staging(pending)
			return _failure("Cannot stage generated %s: %s" % [profile.label, path], error)
	var replaced: Array[String] = []
	var backups: Array[String] = []
	for path in pending:
		var error = OK
		if FileAccess.file_exists(path):
			error = DirAccess.rename_absolute(path, path + ".nw.bak")
			if error == OK:
				backups.append(path)
		if error == OK:
			error = DirAccess.rename_absolute(path + ".nw.tmp", path)
			if error == OK:
				replaced.append(path)
		if error != OK:
			for replaced_path in replaced:
				DirAccess.remove_absolute(replaced_path)
			for backup in backups:
				DirAccess.rename_absolute(backup + ".nw.bak", backup)
			_clear_staging(pending)
			return _failure("Cannot replace generated %s: %s" % [profile.label, path], error)
	for backup in backups:
		DirAccess.remove_absolute(backup + ".nw.bak")
	return {"error": OK, "changed": not pending.is_empty()}


static func _clear_staging(paths: Array[String]) -> void:
	for path in paths:
		if FileAccess.file_exists(path + ".nw.tmp"):
			DirAccess.remove_absolute(path + ".nw.tmp")


## Clear the returned temporary validation types after their instances are gone.
func build_candidate(source_path: String, target_path: String, classes_path: String, statics_path: String, template_source: String, class_name_: String) -> Dictionary:
	var owner_source = profile.owner_template if template_source.is_empty() else template_source
	if owner_source.is_empty():
		return _failure("Cannot read %s owner template." % profile.label, ERR_FILE_NOT_FOUND)
	owner_source = owner_source.replace("\r\n", "\n").strip_edges(false, true) + "\n\n"
	var generated = _build_region(source_path)
	if generated.error != OK:
		return generated
	var preload_line = "const _Generated = preload(%s)\n" % var_to_str(_relative_path(target_path, classes_path))
	var statics_preload = "const %s = preload(%s)\n" % [profile.statics_const, var_to_str(_relative_path(target_path, statics_path))]
	var candidate: String = owner_source + preload_line + statics_preload + generated.source
	var statics_source: String = "extends RefCounted\n\nconst _Generated = preload(%s)\n" % var_to_str(_relative_path(statics_path, classes_path)) + generated.static_source

	# A local owner type keeps self typed without touching the editor's cached scripts.
	var validation_path = _validation_path(target_path)
	var validation_name = "NodeWrapperValidation" + validation_path.get_file().get_basename().trim_prefix("__nw_validate_")
	var wrapper_source: String = generated.classes_source.trim_prefix("extends RefCounted\n")
	var factory_source: String = generated.source
	var static_source: String = generated.static_source
	if generated.re_export:
		# In-memory aliases to nested classes can resolve to null; use the local types directly.
		var aliases = RegEx.new()
		aliases.compile("(?m)^const %s[A-Za-z_0-9]* = _Generated\\.%s[A-Za-z_0-9]*\n" % [profile.prefix, profile.prefix])
		factory_source = aliases.sub(factory_source, "", true)
		static_source = aliases.sub(static_source, "", true)
		if not generated.dependencies.is_empty():
			factory_source = factory_source.replace(generated.dependencies, "")
	else:
		wrapper_source = _nested_class("_Generated", wrapper_source)
	var validation_source = owner_source + wrapper_source + "\n" + _nested_class(profile.statics_const, static_source) + "\n" + factory_source
	if generated.re_export:
		validation_source = _flatten_wrapper_references(validation_source)
	validation_source = _rename_identifier(validation_source, profile.owner_name, validation_name)
	if not validation_source.contains("class_name " + validation_name):
		validation_source = "class_name " + validation_name + "\n" + validation_source
	var validation = GDScript.new()
	validation.set_path_cache(validation_path)
	validation.source_code = validation_source
	var error = validation.reload()
	if error != OK:
		clear_validation(validation)
		return _failure("Generated %s did not compile: %s" % [profile.label, error_string(error)], error)
	# Validation already compiled the placeholder under its own name; renaming is token-only.
	return {"error": OK, "source": _apply_name(candidate, target_path, target_path, class_name_),
		"classes_source": _apply_name(generated.classes_source, classes_path, target_path, class_name_),
		"classes_path": classes_path, "sweets_source": _apply_name(statics_source, statics_path, target_path, class_name_),
		"sweets_path": statics_path, "validation": validation}


## Only a named owner uses its global class; everything else preloads it, so first generation
## compiles before the editor has registered the class.
func _apply_name(source: String, path: String, target_path: String, class_name_: String) -> String:
	if path == target_path and not class_name_.is_empty():
		return source if class_name_ == profile.owner_name else _rename_identifier(source, profile.owner_name, class_name_)
	var unnamed = source.trim_prefix("class_name %s\n" % profile.owner_name)
	var renamed = _rename_identifier(unnamed, profile.owner_name, profile.owner_alias)
	if renamed == unnamed:
		return renamed
	var extends_line = RegEx.create_from_string("(?m)^extends [^\n]*\n").search(renamed)
	var at = extends_line.get_end() if extends_line != null else 0
	return renamed.insert(at, "const %s = preload(%s)\n" % [profile.owner_alias, var_to_str(_relative_path(path, target_path))])


static func _relative_path(owner: String, dependency: String) -> String:
	var parent = owner.get_base_dir().split("/")
	var target = dependency.split("/")
	var common = 0
	while common < mini(parent.size(), target.size()) and parent[common] == target[common]:
		common += 1
	return "../".repeat(parent.size() - common) + "/".join(target.slice(common))


static func _nested_class(name: String, source: String) -> String:
	var nested = "class %s extends RefCounted:\n" % name
	for line in source.split("\n"):
		nested += ("\t" + line if not line.is_empty() else "") + "\n"
	return nested


func clear_validation(validation: GDScript) -> Error:
	return _clear_validation(validation, profile.prefix, profile.statics_const)


## Release the temporary owner/wrapper type cycle after its instances are gone.
static func _clear_validation(validation: GDScript, prefix: String, statics_const: String) -> Error:
	var constants = validation.get_script_constant_map()
	for name in constants:
		var value = constants[name]
		if value is GDScript and value.resource_path.is_empty() and (name == "_Generated" or name == statics_const or str(name).begins_with(prefix)):
			var error = _clear_validation(value, prefix, statics_const)
			if error != OK:
				return error
	validation.source_code = "extends RefCounted\n"
	return validation.reload()


static func _validation_path(path: String) -> String:
	return path.get_base_dir().path_join("__nw_validate_%d.gd" % Time.get_ticks_usec())


static func _rename_identifier(source: String, identifier: String, replacement: String) -> String:
	var tokens = Lexer._tokens(source)
	for i in range(tokens.size() - 1, -1, -1):
		var token = tokens[i]
		if token.text == identifier:
			source = source.left(token.offset) + replacement + source.substr(token.end)
	return source


## Handwritten helpers may use _Generated even when factories use re-exported names.
func _flatten_wrapper_references(source: String) -> String:
	var tokens = Lexer._tokens(source)
	for i in range(tokens.size() - 3, -1, -1):
		if tokens[i].text == "_Generated" and tokens[i + 1].text == "." and tokens[i + 2].text.begins_with(profile.prefix):
			source = source.left(tokens[i].offset) + source.substr(tokens[i + 2].offset)
	return source


## Names a template declares, so prototypes and setters can't shadow them.
static func _func_names(source: String) -> Array[String]:
	var names: Array[String] = []
	var tokens = Lexer._tokens(source)
	for i in tokens.size() - 1:
		if tokens[i].text == "func" and tokens[i + 1].text.is_valid_ascii_identifier():
			names.append(tokens[i + 1].text)
	return names


## The most derived configured base; empty when the type is unsupported.
func _base_for(native: String) -> String:
	if not ClassDB.class_exists(native) or not ROOTS.any(func(root): return ClassDB.is_parent_class(native, root)):
		return ""
	var best = ""
	for base: String in profile.bases:
		if ClassDB.is_parent_class(native, base) and (best.is_empty() or ClassDB.is_parent_class(base, best)):
			best = base
	return best


func _build_region(source_path: String) -> Dictionary:
	if not FileAccess.file_exists(source_path):
		return _failure("%s prototype source not found: %s" % [profile.label, source_path], ERR_FILE_NOT_FOUND)
	var source_text = FileAccess.get_file_as_string(source_path)
	var source_script = GDScript.new()
	source_script.set_path_cache(_validation_path(source_path))
	source_script.source_code = source_text
	var error = source_script.reload()
	if error != OK:
		clear_validation(source_script)
		return _failure("%s prototypes did not compile: %s" % [profile.label, error_string(error)], error)
	var settings = source_script.get_script_constant_map()
	var overrides = settings.get("TYPES", {})
	var re_export = settings.get("RE_EXPORT", false)
	if overrides is not Dictionary or re_export is not bool:
		clear_validation(source_script)
		return _failure("%s needs a TYPES dictionary and a boolean RE_EXPORT setting." % profile.label)
	var parser = Parser.new()
	parser.set_use_native_backend(false)
	parser.set_cache_enabled(false)
	parser.active_parser = parser
	parser.set_current_script(source_script)
	parser.set_source_code(source_text)
	parser.parse(true)
	var result = _emit_prototypes(parser, overrides, re_export, source_text.split("\n"), settings)
	parser.code_edit.free()
	parser.code_edit = null
	parser.active_parser = null
	clear_validation(source_script)
	return result


func _emit_prototypes(parser, overrides: Dictionary, re_export: bool, lines: PackedStringArray, settings: Dictionary) -> Dictionary:
	var tags = _collect_setter_tags(lines)
	if tags.error != OK:
		return tags
	var names: Array[String] = []
	for name: String in parser.get_classes():
		if name.begins_with(profile.prefix) and not name.contains("."):
			names.append(name)
	if names.is_empty():
		return _failure("%s needs at least one top-level %s prototype class." % [profile.label, profile.prefix])
	for name in overrides:
		if not name in names:
			return _failure("No %s prototype for override: %s" % [profile.label, name])
	names.sort()
	var factories: Array[String] = []
	var static_factories: Array[String] = []
	var wrappers: Array[String] = []
	var aliases: Array[String] = []
	var used_factories: Array[String] = []
	var used_statics: Array[String] = []
	var imports: Dictionary = {}
	var setting_names = settings.keys()
	setting_names.sort()
	for key: String in setting_names:
		if key in ["TYPES", "RE_EXPORT"] or key.begins_with(profile.prefix):
			continue
		var value = settings[key]
		if value is GDScript and not value.resource_path.is_empty():
			imports[key] = value.resource_path
	for name in names:
		if name is not String or not name.is_valid_ascii_identifier():
			return _failure("Invalid %s wrapper name: %s" % [profile.label, name])
		var entry = overrides.get(name, {})
		if entry is not Dictionary:
			return _failure("Invalid %s catalog entry: %s" % [profile.label, name])
		var inferred_type = name.trim_prefix(profile.prefix)
		var target = entry.get("node", inferred_type)
		var custom: GDScript = target if target is GDScript else null
		var native_base = custom.get_instance_base_type() if custom != null else str(target)
		var native_type = str(target)
		if custom != null:
			var checked = _check_target(custom)
			if checked.error != OK:
				return checked
			native_type = _import_type(custom.resource_path, imports)
		var base = _base_for(native_base)
		var factory = str(entry.get("factory", inferred_type.to_snake_case()))
		if base.is_empty() or not factory.is_valid_ascii_identifier():
			return _failure("%s entries need a supported type (%s) and factory name: %s" % [profile.label, ", ".join(profile.bases.keys()), name])
		var templates: Dictionary = profile.bases[base]
		var wrapper_type = name if re_export else "_Generated." + name
		var keys = {"wrapper": name, "type": native_type, "wrapper_type": wrapper_type, "factory": factory}
		# Abstract natives still wrap, so they can be inherited, but can't be constructed.
		var constructible = custom != null or ClassDB.can_instantiate(native_base)
		var owner_factory: String = str(templates.get("factory", "")).format(keys) if constructible else ""
		var static_factory: String = str(templates.get("static", "")).format(keys) if constructible else ""
		for method_name in _func_names(owner_factory):
			if method_name in used_factories:
				return _failure("Duplicate %s factory: %s" % [profile.label, method_name])
			used_factories.append(method_name)
		for method_name in _func_names(static_factory):
			if method_name in used_statics:
				return _failure("Duplicate %s static factory: %s" % [profile.label, method_name])
			used_statics.append(method_name)
		var body: String = str(templates.get("class", "")).format(keys)
		var reserved = _func_names(body)
		if not "_init" in reserved:
			reserved.append("_init")
		var collected = _collect_methods(parser, name, reserved)
		if collected.error != OK:
			return collected
		var methods: Dictionary = collected.methods
		var setters = _emit_setters(native_base, name, collected.ancestors, tags.members, custom, imports, reserved)
		if setters.error != OK:
			return setters
		# Parser keys are StringNames; their sort order depends on interned addresses.
		var method_names: Array[String] = []
		for method_name in methods:
			method_names.append(str(method_name))
		for setter_name in setters.methods:
			if not methods.has(setter_name):
				method_names.append(setter_name)
		method_names.sort()
		var output = body
		for method_name in method_names:
			if methods.has(method_name):
				var emitted = _emit_method(methods[method_name], lines, collected.ancestors, name)
				if emitted.error != OK:
					return emitted
				output += "\n\n" + emitted.source
			else:
				output += "\n\n" + setters.methods[method_name]
		wrappers.append(output)
		if re_export:
			aliases.append("const %s = _Generated.%s" % [name, name])
		if not owner_factory.is_empty():
			factories.append(owner_factory)
		if not static_factory.is_empty():
			static_factories.append(static_factory)
	var dependencies = ""
	for alias: String in imports:
		dependencies += "const %s = preload(%s)\n" % [alias, var_to_str(imports[alias])]
	var region = profile.header + "\n" + dependencies
	if not aliases.is_empty():
		region += "\n".join(aliases) + "\n"
	region += "\n\n"
	var static_region = region + "\n\n".join(static_factories) + "\n"
	region += "\n\n".join(factories) + "\n"
	var classes_source = "extends RefCounted\n\n" + profile.header + "\n\n"
	classes_source += dependencies + "\n" + "\n\n".join(wrappers)
	return {"error": OK, "source": region, "static_source": static_region, "classes_source": classes_source, "dependencies": dependencies, "re_export": re_export}


static func _collect_setter_tags(lines: PackedStringArray) -> Dictionary:
	var members: Dictionary = {}
	for tag in TagScanner.scan_lines(lines, ""):
		if tag.tag != "set" or not tag.owner_function.is_empty() or tag.owner_class.is_empty():
			continue
		if not lines[tag.line].left(tag.column).strip_edges().is_empty():
			continue
		var owner: String = tag.owner_class.trim_prefix(".")
		var names: Array = members.get_or_add(owner, [])
		var arguments: String = tag.raw.trim_prefix("#!").strip_edges().trim_prefix("set").strip_edges()
		for argument in arguments.split(","):
			var member_name: String = argument.strip_edges()
			if not member_name.is_valid_ascii_identifier():
				return _failure("Invalid set member on line %d: %s" % [tag.line + 1, member_name])
			if not member_name in names:
				names.append(member_name)
	return {"error": OK, "members": members}


func _emit_setters(native_type: String, wrapper: String, ancestors: Array[String], tags: Dictionary, custom: GDScript, imports: Dictionary, reserved: Array[String]) -> Dictionary:
	var properties: Dictionary = {}
	for property in ClassDB.class_get_property_list(native_type):
		properties[property.name] = property
	var script_properties: Dictionary = {}
	var signals: Dictionary = {}
	var base_script = custom
	while base_script != null:
		for property in base_script.get_script_property_list():
			if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and not script_properties.has(property.name):
				script_properties[property.name] = property
		for signal_info in base_script.get_script_signal_list():
			signals[signal_info.name] = true
		base_script = base_script.get_base_script()
	properties.merge(script_properties, true)
	var member = profile.member
	var methods: Dictionary = {}
	for ancestor in ancestors:
		for member_name: String in tags.get(ancestor, []):
			if methods.has(member_name):
				continue
			if member_name in reserved:
				return _failure("Set member conflicts with generated method: " + member_name)
			if not properties.has(member_name):
				if signals.has(member_name) or Parser.BuiltInChecker.class_has_signal(native_type, member_name):
					methods[member_name] = "\tfunc %s(callable: Callable) -> %s:\n\t\t%s.%s.connect(callable)\n\t\treturn self\n" % [member_name, wrapper, member, member_name]
					continue
				return _failure("Unknown %s property or signal: %s" % [native_type, member_name])
			var value_type: String
			if script_properties.has(member_name):
				var property: Dictionary = script_properties[member_name]
				if property.usage & PROPERTY_USAGE_READ_ONLY:
					return _failure("Property is not writable: " + member_name)
				value_type = _property_type(property, imports)
			else:
				var setter: String = ClassDB.class_get_property_setter(native_type, member_name)
				if setter.is_empty() or properties[member_name].usage & PROPERTY_USAGE_READ_ONLY:
					return _failure("Property is not writable: %s.%s" % [native_type, member_name])
				var api_type: String = Parser.BuiltInChecker.get_member_type(native_type, member_name)
				if api_type.is_empty():
					return _failure("Cannot resolve setter type: %s.%s" % [native_type, member_name])
				value_type = Parser.Utils.type_path_to_display(Parser.Utils.type_path_from_api_enum(api_type))
				# Union resource hints ("BaseMaterial3D,ShaderMaterial") would emit an extra parameter.
				if value_type.contains(","):
					value_type = _setter_argument_type(native_type, setter)
			if value_type == "Nil":
				value_type = "Variant"
			methods[member_name] = "\tfunc %s(value: %s) -> %s:\n\t\t%s.%s = value\n\t\treturn self\n" % [member_name, value_type, wrapper, member, member_name]
	return {"error": OK, "methods": methods}


## The declared type of a native setter's value, e.g. Material for set_material_override().
static func _setter_argument_type(native_type: String, setter: String) -> String:
	for method in ClassDB.class_get_method_list(native_type):
		if method.name == setter and method.args.size() - method.default_args.size() == 1:
			var argument: Dictionary = method.args[0]
			if not str(argument.class_name).is_empty():
				return str(argument.class_name)
			return "Variant" if argument.type == TYPE_NIL else type_string(argument.type)
	return "Variant"


func _check_target(script: GDScript) -> Dictionary:
	if not script.resource_path.ends_with(".gd") or not FileAccess.file_exists(script.resource_path):
		return _failure("Custom %s targets must be file-backed GDScript classes." % profile.label)
	if script.has_method("is_abstract") and script.call("is_abstract"):
		return _failure("Custom %s targets cannot be abstract: %s" % [profile.label, script.resource_path])
	var base_script = script
	while base_script != null:
		for method in base_script.get_script_method_list():
			if method.name == "_init":
				if method.args.size() > method.default_args.size():
					return _failure("Custom %s targets need a constructor without required arguments: %s" % [profile.label, script.resource_path])
				return {"error": OK}
		base_script = base_script.get_base_script()
	return {"error": OK}


func _import_type(path: String, imports: Dictionary) -> String:
	for alias: String in imports:
		if imports[alias] == path:
			return alias
	var alias = "%s%d" % [profile.alias_prefix, imports.size()]
	while imports.has(alias):
		alias += "_"
	imports[alias] = path
	return alias


func _type_reference(value: String, imports: Dictionary) -> String:
	var script_end = value.find(".gd")
	if script_end >= 0 and (value.begins_with("res://") or value.is_absolute_path()):
		var path = value.left(script_end + 3)
		return _import_type(path, imports) + value.substr(script_end + 3)
	var first = value.get_slice(".", 0)
	for entry in ProjectSettings.get_global_class_list():
		if entry.class == first:
			return _import_type(entry.path, imports) + value.trim_prefix(first)
	return value


func _property_type(property: Dictionary, imports: Dictionary) -> String:
	if not str(property.class_name).is_empty():
		return _type_reference(str(property.class_name), imports)
	if property.type == TYPE_ARRAY and property.hint == PROPERTY_HINT_ARRAY_TYPE:
		return "Array[%s]" % _type_reference(property.hint_string, imports)
	if property.type == TYPE_DICTIONARY and property.hint == PROPERTY_HINT_DICTIONARY_TYPE:
		var parts = str(property.hint_string).split(";")
		if parts.size() == 2:
			return "Dictionary[%s, %s]" % [_type_reference(parts[0], imports), _type_reference(parts[1], imports)]
	if property.hint == PROPERTY_HINT_TYPE_STRING:
		if property.type == TYPE_ARRAY:
			return "Array[%s]" % _export_element_type(property.hint_string, imports)
		if property.type == TYPE_DICTIONARY:
			var parts = str(property.hint_string).split(";")
			if parts.size() == 2:
				return "Dictionary[%s, %s]" % [_export_element_type(parts[0], imports), _export_element_type(parts[1], imports)]
	return "Variant" if property.type == TYPE_NIL else type_string(property.type)


func _export_element_type(encoded: String, imports: Dictionary) -> String:
	var type = int(encoded.get_slice(":", 0).get_slice("/", 0))
	if type == TYPE_OBJECT:
		return _type_reference(encoded.substr(encoded.find(":") + 1), imports)
	return "Variant" if type == TYPE_NIL else type_string(type)


func _collect_methods(parser, name: String, reserved: Array[String]) -> Dictionary:
	var chain: Array = []
	var ancestors: Array[String] = []
	var current = name
	while current != "RefCounted":
		if current in ancestors:
			return _failure("Cyclic %s prototype inheritance: %s" % [profile.label, name])
		var prototype = parser.get_class_object(current)
		if prototype == null:
			return _failure("Missing %s prototype: %s" % [profile.label, current])
		ancestors.append(current)
		chain.push_front(prototype)
		current = prototype.extended
	var methods = {}
	for prototype in chain:
		for constant in prototype.constants.values():
			if constant.get(Parser.Keys.ACCESS_PATH) == prototype.access_path:
				return _failure("Prototype constants are not supported: " + name)
		for member_name in prototype.members:
			if member_name != profile.member and not prototype.functions.has(member_name):
				return _failure("Only %s state and operation methods are supported: %s" % [profile.member, name])
		for method_name in prototype.functions:
			if method_name in reserved:
				return _failure("%s is generated by the base template: %s" % [method_name, name])
			methods[method_name] = prototype.functions[method_name]
	return {"error": OK, "methods": methods, "ancestors": ancestors}


static func _emit_method(method, lines: PackedStringArray, ancestors: Array[String], wrapper: String) -> Dictionary:
	var block: Array[String] = []
	var declaration: String = lines[method.declaration_line]
	var indentation = declaration.left(declaration.length() - declaration.strip_edges(true, false).length())
	for i in range(method.declaration_line, method.end_line + 1):
		block.append(lines[i].trim_prefix(indentation))
	var text = "\n".join(block).strip_edges(false, true)
	# The parser's lexer keeps type-like text inside strings and comments untouched.
	var tokens = Lexer._tokens(text)
	for token in tokens:
		if token.text == "super" or token.text == "static":
			return _failure("Wrapper operations must be instance methods without super calls: " + method.name)
	var in_signature = true
	for i in tokens.size():
		var token = tokens[i]
		if in_signature and token.text == ":" and token.depth == 0:
			in_signature = false
		if in_signature and i >= 2 and token.text in ancestors and tokens[i - 1].text == ">" and tokens[i - 2].text == "-":
			text = text.left(token.offset) + wrapper + text.substr(token.end)
			break
	var emitted: Array[String] = []
	for line in text.split("\n"):
		emitted.append("\t" + line if not line.is_empty() else "")
	return {"error": OK, "source": "\n".join(emitted) + "\n"}


static func _failure(message: String, error: Error = ERR_INVALID_DATA) -> Dictionary:
	return {"error": error, "message": message}
