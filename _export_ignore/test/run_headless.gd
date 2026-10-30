extends SceneTree
## Headless entry for the node_wrapper suite, exiting with a CI code.
##     godot --headless --path . --script res://addons/_lib/node_wrapper/_export_ignore/test/run_headless.gd

const SUITES: PackedStringArray = [
	"res://addons/_lib/node_wrapper/_export_ignore/test/node_wrapper_test.gd",
]


func _initialize() -> void:
	var success = true
	var output: Array = []
	for path in SUITES:
		var res: Dictionary = load(path).run_tests()
		success = success and res.result == 0
		output.append_array(res.output)
	print("\n".join(output))
	quit(0 if success else 1)
