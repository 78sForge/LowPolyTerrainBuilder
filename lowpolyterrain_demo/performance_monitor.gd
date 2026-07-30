extends CanvasLayer

@onready var value_fps: Label = $Control/MarginContainer/HBox/VBoxValue/ValueFPS
@onready var value_ram: Label = $Control/MarginContainer/HBox/VBoxValue/ValueRAM
@onready var value_node_count: Label = $Control/MarginContainer/HBox/VBoxValue/ValueNodeCount
@onready var value_draw_calls: Label = $Control/MarginContainer/HBox/VBoxValue/ValueDrawCalls
@onready var value_process_time: Label = $Control/MarginContainer/HBox/VBoxValue/ValueProcessTime
@onready var value_physics_time: Label = $Control/MarginContainer/HBox/VBoxValue/ValuePhysicsTime
@onready var value_primitives_count: Label = $Control/MarginContainer/HBox/VBoxValue/ValuePrimitivesCount


func _process(delta: float) -> void:
	
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var mem_mb = Performance.get_monitor(Performance.MEMORY_STATIC) / 1024.0 / 1024.0
	var node_count: float = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var draw_calls: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	# Fetch execution times in seconds
	var process_time_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_time_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	# Fetch the total number of vertices/primitives rendered in the last frame
	var primitives = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)


	value_fps.set_text("%d" % fps)
	value_ram.set_text("%.2f" % mem_mb)
	value_node_count.set_text("%d" % node_count)
	value_draw_calls.set_text("%d" % draw_calls)
	value_process_time.set_text("%.2f" % process_time_ms)
	value_physics_time.set_text("%.2f" % physics_time_ms)
	value_primitives_count.set_text("%d" % primitives)

	
	
