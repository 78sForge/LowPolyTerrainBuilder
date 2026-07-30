extends Node3D

@onready var pivot: Node3D = $Pivot


func _process(delta: float) -> void:
	pivot.rotate_y(delta * 0.1)
