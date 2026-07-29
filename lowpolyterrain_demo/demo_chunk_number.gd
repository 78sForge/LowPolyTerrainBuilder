extends Node3D

@onready var low_poly_terrain_manager: LowPolyTerrainManager = $LowPolyTerrainManager

func _ready() -> void:
	
	for child in low_poly_terrain_manager.get_children():
		print (child)

	printt("number of children:", low_poly_terrain_manager.get_child_count())
