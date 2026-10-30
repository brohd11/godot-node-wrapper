# Node Wrapper

Generates chainable wrapper classes for Godot types from a GDScript prototype source. This is the
generation side of [Sweet UI](https://github.com/brohd11/godot-sweet-ui); any plugin can use it to
generate its own wrapper library for Nodes, Resources or RefCounted types.

Godot 4.6+

## Usage

```gdscript
const Generator = preload("res://addons/_lib/node_wrapper/src/generator.gd")
const DefaultBases = preload("res://addons/_lib/node_wrapper/src/default_bases.gd")

var profile = DefaultBases.profile()
profile.label = "My Wrappers"
profile.targets_setting = "my_plugin/generation/targets"
profile.default_targets = {"res://scripts/my_wrappers": "MyWrappers"}
profile.addon_dir = "res://addons/my_plugin"
profile.seed_template = FileAccess.get_file_as_string("res://addons/my_plugin/templates/source.gd.txt")

var generator = Generator.new(profile)
generator.report(generator.setup())      # create missing outputs
generator.report(generator.setup(true))  # regenerate from source changes
```

Each target directory gets `profile.source_file` (seeded from `seed_template` when missing) plus three
generated files: the owner (`owner_file`), the wrapper classes (`classes_file`) and static factories
(`statics_file`). A target with an empty class name generates an unnamed build, which you use by preloading it.

## Prototypes

Top-level classes named `profile.prefix` + type (`SwNode3D` → `Node3D`, factory `node_3d()`) are
prototypes. Inherited methods are flattened into each generated wrapper. The `TYPES` dictionary can
override `node` (a native name or a file-backed script) and `factory`, and `RE_EXPORT` re-exports the
wrapper names on the owner.
`#! set a, b` generates setters for properties and connectors for signals. The only state a prototype
may declare is `profile.member`.

## Bases

`profile.bases` maps a native class name to the templates that define each wrapper's base functionality:

```gdscript
{"Node": {"class": NODE_CLASS, "factory": NODE_FACTORY, "static": STATIC_FACTORY}}
```

- `class`: the wrapper's head, meaning its fields, accessors, `_init`, and attach helpers. Prototypes can't
  redefine any func declared here.
- `factory`: funcs appended to the owner. `static`: funcs appended to the statics file. Leave either
  empty to emit none.
- Keys: `{wrapper}`, `{type}`, `{wrapper_type}`, `{factory}`. `profile.owner_name` stays literal and
  is renamed per target.

A type uses the most derived base it inherits from. Types must inherit `Node` or `RefCounted` (Resource
included). Bare `Object` is rejected because nothing would free it. Abstract natives (e.g. CanvasItem) still get a
wrapper class, so they can be inherited, but no factories.

`DefaultBases` has reference templates: `Node` attaches to a parent, while `RefCounted` wraps without one.
Copy them and change the base to change what construction does, e.g. an `_init` that calls `set_data()`.

## Tests

```
godot --headless --path . --script res://addons/_lib/node_wrapper/_export_ignore/test/run_headless.gd
```
