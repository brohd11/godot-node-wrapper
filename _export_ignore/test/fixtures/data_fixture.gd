extends RefCounted

## A plain data object whose wrapper base hands it data on construction.

var value: int = 0
var data: Dictionary = {}


func set_data(next: Dictionary) -> void:
	data = next
