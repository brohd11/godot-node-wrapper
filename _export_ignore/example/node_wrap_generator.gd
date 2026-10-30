@tool
extends EditorScript

## Example consumer: a NodeWrap owner over the default bases, for Node → Node3D → MeshInstance3D
## and RefCounted → Resource → StandardMaterial3D. Copy both files into your plugin and adjust the
## paths. Call setup() from your plugin's _enter_tree(); File → Run force-regenerates.

const Generator = preload("res://addons/_lib/node_wrapper/src/generator.gd")
const DefaultBases = preload("res://addons/_lib/node_wrapper/src/default_bases.gd")

const TARGET_DIR = "res://scripts/node_wrap"
const SEED = "res://addons/_lib/node_wrapper/_export_ignore/example/node_wrap_source.gd.txt"


func _run() -> void:
	setup(true)


static func generator() -> Generator:
	var profile = DefaultBases.profile()
	profile.label = "NodeWrap"
	# No targets setting: read_targets() falls back to these.
	profile.default_targets = {TARGET_DIR: "NodeWrap"}
	# Set to your plugin's directory so output never lands inside it (it'd be lost on update).
	profile.addon_dir = ""
	profile.source_file = "node_wrap_source.gd"
	profile.owner_file = "generated/node_wrap.gd"
	profile.classes_file = "generated/node_wraps_generated.gd"
	profile.statics_file = "generated/node_wraps.gd"
	profile.statics_const = "Wraps"
	profile.seed_template = FileAccess.get_file_as_string(SEED)
	return Generator.new(profile)


## Without force, only missing or renamed outputs are generated.
static func setup(force: bool = false) -> Error:
	var gen = generator()
	return gen.report(gen.setup(force))
