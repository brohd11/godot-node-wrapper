#! namespace NodeWrapper class DefaultBases
extends RefCounted

## Reference templates: Node types attach to a parent, RefCounted types (Resource included) don't.
## A starting point for consumer profiles; copy and adjust rather than depending on exact output.

const Profile = preload("res://addons/_lib/node_wrapper/src/profile.gd")

const OWNER = \
"class_name WrapperOwner
extends RefCounted

var _root: Node
var _node: Node


func _init(node: Node = null) -> void:
	_root = node
	_node = node

func rebase(node: Node) -> WrapperOwner:
	_node = node
	return self

func to_root() -> WrapperOwner:
	_node = _root
	return self
"

const NODE_CLASS = \
"class {wrapper} extends RefCounted:
	var _object: {type}
	var _owner: WrapperOwner

	func obj() -> {type}:
		return _object

	func owner() -> WrapperOwner:
		return _owner

	func _init(object: {type}) -> void:
		_object = object

	static func with_parent(object: {type}, parent: Node, owner_: WrapperOwner) -> {wrapper}:
		var wrapper = {wrapper}.new(object)
		parent.add_child(object)
		wrapper._owner = owner_
		return wrapper
"

const NODE_FACTORY = \
"func {factory}(parent: Node = null) -> {wrapper_type}:
	if not is_instance_valid(parent):
		parent = _node
	return {wrapper_type}.with_parent({type}.new(), parent, self)


func {factory}_from(object: {type}, parent: Node = null) -> {wrapper_type}:
	if not is_instance_valid(parent):
		parent = _node
	return {wrapper_type}.with_parent(object, parent, self)
"

const REF_CLASS = \
"class {wrapper} extends RefCounted:
	var _object: {type}
	var _owner: WrapperOwner

	func obj() -> {type}:
		return _object

	func owner() -> WrapperOwner:
		return _owner

	func _init(object: {type}) -> void:
		_object = object

	static func with_owner(object: {type}, owner_: WrapperOwner) -> {wrapper}:
		var wrapper = {wrapper}.new(object)
		wrapper._owner = owner_
		return wrapper
"

const REF_FACTORY = \
"func {factory}() -> {wrapper_type}:
	return {wrapper_type}.with_owner({type}.new(), self)


func {factory}_from(object: {type}) -> {wrapper_type}:
	return {wrapper_type}.with_owner(object, self)
"

const STATIC_FACTORY = \
"static func {factory}(object: {type} = null) -> {wrapper_type}:
	if object == null:
		object = {type}.new()
	return {wrapper_type}.new(object)
"


static func bases() -> Dictionary:
	return {
		"Node": {"class": NODE_CLASS, "factory": NODE_FACTORY, "static": STATIC_FACTORY},
		"RefCounted": {"class": REF_CLASS, "factory": REF_FACTORY, "static": STATIC_FACTORY},
	}


## A complete profile with the default owner; set targets_setting/addon_dir before setup().
static func profile() -> Profile:
	var result = Profile.new()
	result.owner_template = OWNER
	result.bases = bases()
	return result
