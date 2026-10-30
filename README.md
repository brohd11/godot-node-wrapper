# Node Wrapper

Generates chainable wrapper classes for Godot types from a GDScript prototype source. This is the
generation side of [Sweet UI](https://github.com/brohd11/godot-sweet-ui); any plugin can use it to
generate its own wrapper library for Nodes, Resources or RefCounted types.

Godot 4.6+

## Usage

See the [example](_export_ignore/example/): a profile script plus a seed source that generates a `NodeWrap` class
for Node → Node3D → MeshInstance3D and RefCounted → Resource → StandardMaterial3D:

```gdscript
var mat = wrap.standard_material_3d().albedo_color(Color.RED).pbr(1.0, 0.25).obj()
wrap.mesh_instance_3d().mesh(BoxMesh.new()).material_override(mat)
```

A `Profile` (`src/profile.gd`) holds the naming, output layout and templates. `Generator.new(profile).setup()`
seeds the source file if it's missing and generates the owner, the wrapper classes and the static factories.
Only the owner uses its global class. The other generated files preload it, so a first generation
compiles before the editor registers the class.

## Prototypes

Top-level classes named `prefix` + type (`SwNode3D` → `Node3D`, factory `node_3d()`) are prototypes, and
inherited methods are flattened into each wrapper. `#! set a, b` generates property setters and signal
connectors. `TYPES` can override `node` (a native class or a file-backed script) and `factory`.

## Bases

`profile.bases` maps a native class to `{"class", "factory", "static"}` templates, which define each
wrapper's own base functionality. They use the keys `{wrapper}`, `{type}`, `{wrapper_type}` and `{factory}`. A type
uses the most derived base it inherits from, and it must inherit `Node` or `RefCounted`. Abstract natives get
a wrapper class but no factories. [`DefaultBases`](src/default_bases.gd) is a good starting point.

## Tests

```
godot --headless --path . --script res://addons/_lib/node_wrapper/_export_ignore/test/run_headless.gd
```
