extends Node3D

@onready var pivot: Node3D = $Pivot
@onready var camera_3d: Camera3D = $Pivot/Camera3D

var count := 0
var zoomOut := true
func _process(delta: float) -> void:
	
	pivot.rotate_y(delta * 0.3)
	#pivot.rotate_x(delta * 0.3)
	
	
	return
	
	count += 1
	if count < 1000:
		if zoomOut:
			camera_3d.position.z += 0.1
		else:
			camera_3d.position.z -= 0.1
	else:
		count = 0
		zoomOut = !zoomOut
		
	
