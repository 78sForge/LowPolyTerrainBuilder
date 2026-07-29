extends Node3D

@onready var label_fps: Label = $CanvasLayer/Control/MarginContainer/VBoxContainer/LabelFPS
@onready var label_ram: Label = $CanvasLayer/Control/MarginContainer/VBoxContainer/LabelRAM
@onready var label_node_count: Label = $CanvasLayer/Control/MarginContainer/VBoxContainer/LabelNodeCount
@onready var label_draw_calls: Label = $CanvasLayer/Control/MarginContainer/VBoxContainer/LabelDrawCalls
@onready var label_process_time: Label = $CanvasLayer/Control/MarginContainer/VBoxContainer/LabelProcessTime
@onready var label_physics_time: Label = $CanvasLayer/Control/MarginContainer/VBoxContainer/LabelPhysicsTime
@onready var label_primitives_count: Label = $CanvasLayer/Control/MarginContainer/VBoxContainer/LabelPrimitivesCount
@onready var pivot: Node3D = $Pivot


func get_total_child_count(node: Node) -> int:
	var count = 0
	for child in node.get_children():
		count += 1
		count += get_total_child_count(child)
	return count

func _ready() -> void:
	var noOfChildren = get_total_child_count(self)
	printt("Number of children: ", noOfChildren)

func _process(delta: float) -> void:
	pivot.rotate_y(delta * 0.1)
	
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var mem_mb = Performance.get_monitor(Performance.MEMORY_STATIC) / 1024.0 / 1024.0
	var node_count: float = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var draw_calls: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	# Fetch execution times in seconds
	var process_time_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_time_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	# Fetch the total number of vertices/primitives rendered in the last frame
	var primitives = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)


	label_fps.set_text("FPS %d" % fps)
	label_ram.set_text("RAM %.2f MB" % mem_mb)
	label_node_count.set_text("NodeCount %d" % node_count)
	label_draw_calls.set_text("DrawCalls %d" % draw_calls)
	label_process_time.set_text("ProcessTime %.2f ms" % process_time_ms)
	label_physics_time.set_text("PhysicsTime %.2f ms" % physics_time_ms)
	label_primitives_count.set_text("Primitives %d" % primitives)

	
	
