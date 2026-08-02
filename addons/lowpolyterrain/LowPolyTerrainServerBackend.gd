@tool
extends RefCounted
class_name LowPolyTerrainServerBackend

## Owns every RenderingServer and PhysicsServer3D resource used by TerrainBackend.SERVERS.
##
## Nothing in here is a Node. The engine therefore performs none of the bookkeeping a
## MeshInstance3D would do for free, which is why this class explicitly mirrors transform,
## visibility, world membership and destruction. The manager forwards the matching node
## notifications; see LowPolyTerrainManager._notification().


## Per-chunk bundle of server resources and the cached state needed to keep them in sync.
class ChunkRecord extends RefCounted:
	var coord: Vector2i = Vector2i.ZERO

	# STRONG REFERENCE, LOAD-BEARING: an ArrayMesh is a Resource. Dropping the last GDScript
	# reference frees the underlying RID and the instance silently renders nothing at all.
	var mesh: ArrayMesh = null

	# STRONG REFERENCE for the same reason, and it guarantees the physics server receives
	# byte-identical face data to the classic LowPolyTerrainChunk.bake_collision() path.
	var shape: ConcavePolygonShape3D = null

	var instance_rid: RID = RID()
	var body_rid: RID = RID()

	## Offset of this chunk inside the manager's local space.
	var local_transform: Transform3D = Transform3D.IDENTITY

	## Scale that is already folded into the collision face data.
	var baked_scale: Vector3 = Vector3.ONE

	## True while this chunk currently carries terrain geometry rather than a preview quad.
	var has_terrain: bool = false

	## Set whenever the render mesh is rebuilt, so the collider cannot silently keep serving
	## the geometry of an earlier frame.
	var collision_dirty: bool = true

	## True while the collider is built but parked: it exists and keeps its shape, but takes
	## part in no collision test. Re-entering the radius only has to clear this flag.
	var shape_parked: bool = false

	# Translucent overlay showing this chunk's actual collider. Strong ref for the same
	# lifetime reason as `mesh`.
	var debug_mesh: ArrayMesh = null
	var debug_instance_rid: RID = RID()


var _manager: LowPolyTerrainManager = null

# Vector2i -> ChunkRecord
var _records: Dictionary = {}

## The very same records as a flat list. The per-frame transform sweep walks this instead of
## the Dictionary, which avoids a hash lookup per chunk on a path that can run every frame.
var _record_list: Array[ChunkRecord] = []

# Vector2i -> RID of a RenderingServer instance showing the shared deactivated preview quad
var _preview_instances: Dictionary = {}

# A single mesh and a single material are shared by every deactivated chunk preview, because
# the quads are geometrically identical and differ only by transform.
var _preview_mesh: ArrayMesh = null
var _preview_material: StandardMaterial3D = null
var _preview_dims: Vector2 = Vector2.ZERO

var _scenario: RID = RID()
var _space: RID = RID()
var _cached_global_transform: Transform3D = Transform3D.IDENTITY
var _cached_visible: bool = true

## False until the first transform push, so the identity default cannot be mistaken for an
## already-synchronised state.
var _transform_pushed: bool = false

## Number of records that currently own a physics body, so the per-frame body loop can be
## skipped outright when there is nothing to move.
var _body_count: int = 0

## Coalesces collision rebakes across a burst of transform notifications.
var _scale_rebake_pending: bool = false
var _warned_mirrored_scale: bool = false

## Mirror of LowPolyTerrainManager.runtime_collision, kept as an int so this class does not
## depend on the manager's enum during parsing.
var _collision_policy: int = 0

## Flips to true the first time update_collision_culling() runs.
var _culling_driving_collision: bool = false

## Coords whose collider is built but parked, least recently parked first. Under LAZY a
## chunk leaving the radius is switched off rather than destroyed, so returning to it costs a
## fraction of a microsecond instead of a full rebuild. The list is bounded by the manager's
## collision_retain_limit; the oldest entry is genuinely freed once that is exceeded.
var _parked: Array[Vector2i] = []

## Draws every live collider as a translucent overlay. Godot's own "Visible Collision Shapes"
## cannot show these bodies, because that feature is implemented inside CollisionShape3D and
## the SERVERS backend deliberately has no such node.
var _collision_debug: bool = false
var _debug_material: StandardMaterial3D = null


## Binds this backend to its owning manager. Must be called before anything else.
func setup(manager: LowPolyTerrainManager) -> void:
	_manager = manager



## Points every allocated resource at the world the manager currently lives in.
func attach_to_world(world: World3D) -> void:
	if world == null:
		return
	_scenario = world.scenario
	_space = world.space

	for coord: Vector2i in _records:
		var rec: ChunkRecord = _records[coord]
		if rec.instance_rid.is_valid():
			RenderingServer.instance_set_scenario(rec.instance_rid, _scenario)
		if rec.debug_instance_rid.is_valid():
			RenderingServer.instance_set_scenario(rec.debug_instance_rid, _scenario)
		if rec.body_rid.is_valid():
			PhysicsServer3D.body_set_space(rec.body_rid, _space)

	for coord: Vector2i in _preview_instances:
		var rid: RID = _preview_instances[coord]
		if rid.is_valid():
			RenderingServer.instance_set_scenario(rid, _scenario)


## Detaches all resources from their world without releasing them, so the manager can be moved
## between scene tabs or viewports and re-attached later.
func detach_from_world() -> void:
	for coord: Vector2i in _records:
		var rec: ChunkRecord = _records[coord]
		if rec.instance_rid.is_valid():
			RenderingServer.instance_set_scenario(rec.instance_rid, RID())
		if rec.debug_instance_rid.is_valid():
			RenderingServer.instance_set_scenario(rec.debug_instance_rid, RID())
		if rec.body_rid.is_valid():
			PhysicsServer3D.body_set_space(rec.body_rid, RID())

	for coord: Vector2i in _preview_instances:
		var rid: RID = _preview_instances[coord]
		if rid.is_valid():
			RenderingServer.instance_set_scenario(rid, RID())

	_scenario = RID()
	_space = RID()



## Mirrors the manager's world transform onto every server resource. A raw RenderingServer
## instance has no parent, so this is the only thing keeping the chunks aligned with the node.
func on_transform_changed(global_xform: Transform3D) -> void:
	# A node ancestor that animates every frame would otherwise drag this whole GDScript loop
	# through every chunk once per frame. Godot re-notifies liberally, so bail out when the
	# transform did not actually change.
	if _transform_pushed and global_xform.is_equal_approx(_cached_global_transform):
		return
	_transform_pushed = true
	_cached_global_transform = global_xform

	# A chunk's local transform is pure translation, so the product collapses from a full
	# Transform3D multiply (a 3x3 basis product per chunk) down to transforming one point.
	# The result is identical, and this loop can run every frame when an ancestor animates.
	var basis: Basis = global_xform.basis

	for rec: ChunkRecord in _record_list:
		if rec.instance_rid.is_valid():
			# The full transform, scale included. The terrain shaders run with
			# render_mode world_vertex_coords and derive their triplanar cliff pattern from
			# the resulting world position, so anything but the exact node transform would
			# visibly shift the rock texturing rather than merely displace the chunk.
			RenderingServer.instance_set_transform(
				rec.instance_rid,
				Transform3D(basis, global_xform * rec.local_transform.origin)
			)

	for coord: Vector2i in _preview_instances:
		var rid: RID = _preview_instances[coord]
		if rid.is_valid():
			var rec_xform: Transform3D = _local_transform_for(coord)
			RenderingServer.instance_set_transform(rid, global_xform * rec_xform)

	_sync_body_transforms()

	if _collision_debug:
		for rec: ChunkRecord in _record_list:
			if rec.debug_instance_rid.is_valid():
				_push_debug_transform(rec)


## Keeps the physics bodies aligned with the manager, rebaking shapes only when the scale
## actually changed. Rebaking is deferred because dragging the scale gizmo emits a transform
## notification every single frame, and N concave rebakes per frame would stall the editor.
func _sync_body_transforms() -> void:
	# Under LAZY only a handful of chunks own a body, so skipping the sweep entirely when
	# there is none avoids walking thousands of records for nothing.
	if Engine.is_editor_hint() or _body_count == 0:
		return

	var scale: Vector3 = _cached_global_transform.basis.get_scale()

	if _cached_global_transform.basis.determinant() < 0.0 and not _warned_mirrored_scale:
		_warned_mirrored_scale = true
		push_warning("LowPolyTerrain: mirrored scale detected. Collision winding is inverted; "
			+ "terrain colliders may behave as back-facing surfaces.")

	var needs_rebake: bool = false
	for rec: ChunkRecord in _record_list:
		if rec.body_rid.is_valid() and not rec.baked_scale.is_equal_approx(scale):
			needs_rebake = true
			break

	if needs_rebake:
		if not _scale_rebake_pending:
			_scale_rebake_pending = true
			call_deferred(&"_flush_scale_rebake")
		return

	for rec: ChunkRecord in _record_list:
		if rec.body_rid.is_valid():
			_push_body_transform(rec)


## Coalesced shape rebake, executed once after a burst of transform notifications.
func _flush_scale_rebake() -> void:
	_scale_rebake_pending = false
	if Engine.is_editor_hint():
		return
	var scale: Vector3 = _cached_global_transform.basis.get_scale()
	for coord: Vector2i in _records:
		var rec: ChunkRecord = _records[coord]
		if rec.mesh == null or not rec.body_rid.is_valid():
			continue
		_bake_collision_shape(rec, scale)
		_push_body_transform(rec)


## Propagates the manager's effective visibility, which a child node would inherit for free.
func on_visibility_changed(is_visible: bool) -> void:
	_cached_visible = is_visible

	for coord: Vector2i in _records:
		var rec: ChunkRecord = _records[coord]
		if rec.instance_rid.is_valid():
			RenderingServer.instance_set_visible(rec.instance_rid, is_visible and rec.has_terrain)
		if rec.debug_instance_rid.is_valid():
			RenderingServer.instance_set_visible(rec.debug_instance_rid, is_visible)

	for coord: Vector2i in _preview_instances:
		var rid: RID = _preview_instances[coord]
		if rid.is_valid():
			RenderingServer.instance_set_visible(rid, is_visible)



## Aligns a raw RenderingServer instance with the state a MeshInstance3D would have configured
## for itself. Without this the two backends differ in shadow casting and global illumination,
## which changes both the look and the render cost - MeshInstance3D defaults to cast_shadow ON
## and gi_mode STATIC, whereas a bare instance is created with neither applied.
func _apply_meshinstance_defaults(rid: RID) -> void:
	RenderingServer.instance_geometry_set_cast_shadows_setting(
		rid, RenderingServer.SHADOW_CASTING_SETTING_ON
	)
	RenderingServer.instance_geometry_set_flag(
		rid, RenderingServer.INSTANCE_FLAG_USE_BAKED_LIGHT, true
	)
	RenderingServer.instance_geometry_set_lod_bias(rid, 1.0)


## Creates the RenderingServer instance for a chunk coordinate if it does not exist yet.
func ensure_chunk(coord: Vector2i) -> ChunkRecord:
	if _records.has(coord):
		return _records[coord]

	var rec := ChunkRecord.new()
	rec.coord = coord
	rec.local_transform = _local_transform_for(coord)
	rec.instance_rid = RenderingServer.instance_create()
	_apply_meshinstance_defaults(rec.instance_rid)
	if _scenario.is_valid():
		RenderingServer.instance_set_scenario(rec.instance_rid, _scenario)
	RenderingServer.instance_set_transform(
		rec.instance_rid, _cached_global_transform * rec.local_transform
	)
	RenderingServer.instance_set_visible(rec.instance_rid, false)

	_records[coord] = rec
	_record_list.append(rec)
	return rec


## Rebuilds a single chunk's geometry, material and visibility from the manager's height data.
func update_chunk(coord: Vector2i) -> void:
	if _manager == null:
		return

	var is_active: bool = _manager.is_chunk_active(coord.x, coord.y)

	if not is_active:
		_clear_terrain_geometry(coord)
		if bool(_manager.show_deactivated_chunks) and Engine.is_editor_hint():
			_ensure_preview_instance(coord)
		else:
			_free_preview_instance(coord)
		return

	_free_preview_instance(coord)

	var rec: ChunkRecord = ensure_chunk(coord)
	rec.local_transform = _local_transform_for(coord)

	var heights: PackedFloat32Array = _manager.extract_chunk_heights(coord)
	rec.mesh = LowPolyTerrainMeshBuilder.build_chunk_mesh(
		coord,
		_manager.chunk_size,
		_manager.cell_size,
		heights,
		_manager.jitter_strength,
		_manager.jitter_slope_threshold,
		_manager.extract_chunk_paint(coord),
		LowPolyTerrainManager.PAINT_STEPS
	)
	# New geometry invalidates any collider built from the previous mesh.
	rec.collision_dirty = true

	if rec.mesh == null:
		rec.has_terrain = false
		RenderingServer.instance_set_base(rec.instance_rid, RID())
		RenderingServer.instance_set_visible(rec.instance_rid, false)
		return

	rec.has_terrain = true
	RenderingServer.instance_set_base(rec.instance_rid, rec.mesh.get_rid())
	RenderingServer.instance_set_transform(
		rec.instance_rid, _cached_global_transform * rec.local_transform
	)
	_apply_material(rec)
	RenderingServer.instance_set_visible(rec.instance_rid, _cached_visible)

	_update_chunk_collision(rec)


## Re-applies the manager's material override to every live chunk instance.
func refresh_materials() -> void:
	for coord: Vector2i in _records:
		_apply_material(_records[coord])


# --- PHYSICS ---
# Bodies exist at runtime only. Editor-side baking is deliberately absent, because rebuilding a
# ConcavePolygonShape3D on every _update_single_chunk() would fire once per brush stroke frame.
#
# Collision dominates this backend's memory profile: a chunk's concave collider costs
# considerably more than the mesh it was built from, because the physics server keeps its own
# indexed mesh and BVH alongside the raw face data. Keeping colliders alive for chunks nobody
# can reach is therefore the most expensive thing this backend can do, which is what the LAZY
# policy exists to avoid.


## Policy values mirroring LowPolyTerrainManager.RuntimeCollision.
const COLLISION_LAZY: int = 0
const COLLISION_PREBUILT: int = 1
const COLLISION_NONE: int = 2


## Applies a new collision policy to the colliders that already exist.
##
## Both directions have to act. Colliders are otherwise only ever created while a chunk is
## being redrawn, so a switch back to PREBUILT used to do nothing at all: coming from NONE the
## terrain stayed uncollidable, and coming from LAZY every previously parked chunk stayed
## switched off - in both cases silently, until something happened to regenerate a mesh.
func set_collision_policy(policy: int) -> void:
	var previous: int = _collision_policy
	_collision_policy = policy
	if Engine.is_editor_hint() or policy == previous:
		return

	if policy == COLLISION_NONE:
		for coord: Vector2i in _records:
			release_chunk_collision(coord)
		return

	if policy == COLLISION_PREBUILT:
		_parked.clear()
		for coord: Vector2i in _records:
			var rec: ChunkRecord = _records[coord]
			if rec.mesh == null:
				continue
			# Cleared before building, because _build_chunk_collision() restores exactly this
			# flag onto the rebuilt shape.
			rec.shape_parked = false
			_build_chunk_collision(rec)


## Records that the manager is actively culling. Purely informational under the current policy
## set, since LAZY never builds colliders on its own anyway.
func notify_culling_active() -> void:
	_culling_driving_collision = true


## True when a chunk may own a collider without anyone explicitly asking for it.
##
## LAZY answers false unconditionally: a chunk gets its collider from ensure_chunk_collision()
## when it first comes within reach, so memory tracks the region actually visited rather than
## the whole world. Releasing one genuinely hands the memory back - that only became true once
## the shapes stopped going through ArrayMesh.get_faces(), which cached its triangle soup
## inside the mesh permanently and left a released collider holding almost all of its cost.
## See LowPolyTerrainMeshBuilder.build_face_soup().
func _collision_allowed_by_default() -> bool:
	if _collision_policy == COLLISION_NONE or _collision_policy == COLLISION_LAZY:
		return false
	return true


## Builds the collider of a chunk on demand, e.g. because it just entered the culling radius.
func ensure_chunk_collision(coord: Vector2i) -> void:
	if Engine.is_editor_hint() or _manager == null:
		return
	if _collision_policy == COLLISION_NONE:
		return
	if not _records.has(coord):
		return
	var rec: ChunkRecord = _records[coord]
	if rec.mesh == null:
		return
	_build_chunk_collision(rec)


## Releases a chunk's collider entirely, including its shape and the physics server's BVH.
## This is what makes the LAZY policy actually reclaim memory rather than merely park it.
func release_chunk_collision(coord: Vector2i) -> void:
	_parked.erase(coord)
	if not _records.has(coord):
		return
	_free_body(_records[coord])


## Creates or refreshes the static body of a chunk. No-op inside the editor.
func _update_chunk_collision(rec: ChunkRecord) -> void:
	if Engine.is_editor_hint() or _manager == null:
		return
	if rec.mesh == null:
		_free_body(rec)
		return

	if not _collision_allowed_by_default():
		# Under LAZY the collider is created by ensure_chunk_collision() instead. An existing
		# one is still refreshed, so a chunk inside the radius follows the sculpted geometry.
		if not rec.body_rid.is_valid():
			return

	_build_chunk_collision(rec)


func _build_chunk_collision(rec: ChunkRecord) -> void:
	var scale: Vector3 = _cached_global_transform.basis.get_scale()
	_bake_collision_shape(rec, scale)

	if not rec.body_rid.is_valid():
		rec.body_rid = PhysicsServer3D.body_create()
		_body_count += 1
		PhysicsServer3D.body_set_mode(rec.body_rid, PhysicsServer3D.BODY_MODE_STATIC)
		if _space.is_valid():
			PhysicsServer3D.body_set_space(rec.body_rid, _space)
		# A server body is not a node and therefore cannot belong to a scene group. Attaching
		# the manager's instance id makes raycast hits resolve to the manager instead, which
		# IS in the configured group, so collider.is_in_group("Wall") keeps working.
		PhysicsServer3D.body_attach_object_instance_id(rec.body_rid, _manager.get_instance_id())

	PhysicsServer3D.body_set_collision_layer(rec.body_rid, _manager.collision_layer)
	PhysicsServer3D.body_set_collision_mask(rec.body_rid, 0)
	# body_add_shape() always attaches an ENABLED shape, so a rebuild would silently wake a
	# parked collider back up without this.
	if PhysicsServer3D.body_get_shape_count(rec.body_rid) > 0:
		PhysicsServer3D.body_set_shape_disabled(rec.body_rid, 0, rec.shape_parked)
	_push_body_transform(rec)
	_update_collision_debug(rec)


## Rebuilds the concave shape, folding the manager's scale straight into the triangle data.
## Jolt is strict about scaled concave shapes, so the body transform stays scale-free.
func _bake_collision_shape(rec: ChunkRecord, scale: Vector3) -> void:
	# The dirty flag is essential: without it a collider built once would keep serving the
	# geometry of that first frame forever, silently diverging from the rendered terrain as
	# soon as anything regenerates the mesh at runtime.
	if rec.shape != null and not rec.collision_dirty and rec.baked_scale.is_equal_approx(scale):
		return

	# build_face_soup() rather than get_faces(): the latter caches the soup inside the mesh
	# permanently, so a released collider would keep most of its memory anyway.
	var faces: PackedVector3Array = LowPolyTerrainMeshBuilder.build_face_soup(rec.mesh)
	if not scale.is_equal_approx(Vector3.ONE):
		for i in range(faces.size()):
			faces[i] = faces[i] * scale

	if rec.shape == null:
		rec.shape = ConcavePolygonShape3D.new()
	rec.shape.set_faces(faces)
	rec.baked_scale = scale
	rec.collision_dirty = false

	if rec.body_rid.is_valid():
		PhysicsServer3D.body_clear_shapes(rec.body_rid)
		PhysicsServer3D.body_add_shape(rec.body_rid, rec.shape.get_rid(), Transform3D.IDENTITY)


## Writes the scale-free world transform of a chunk body into the physics server.
func _push_body_transform(rec: ChunkRecord) -> void:
	if not rec.body_rid.is_valid():
		return
	if PhysicsServer3D.body_get_shape_count(rec.body_rid) == 0 and rec.shape != null:
		PhysicsServer3D.body_add_shape(rec.body_rid, rec.shape.get_rid(), Transform3D.IDENTITY)

	# Rotation and translation only. The scale already lives inside the face data, so
	# global_xform * local gives the correct origin while orthonormalized() strips the scale
	# from the basis. The two together reproduce the node pipeline exactly.
	var rotation_only: Basis = _cached_global_transform.basis.orthonormalized()
	var world_origin: Vector3 = (_cached_global_transform * rec.local_transform).origin
	PhysicsServer3D.body_set_state(
		rec.body_rid,
		PhysicsServer3D.BODY_STATE_TRANSFORM,
		Transform3D(rotation_only, world_origin)
	)


func _free_body(rec: ChunkRecord) -> void:
	if rec.body_rid.is_valid():
		PhysicsServer3D.free_rid(rec.body_rid)
		rec.body_rid = RID()
		_body_count -= 1
	# Dropping the last reference releases the shape RID and, with it, the physics server's
	# indexed mesh and BVH. That is the bulk of the per-chunk collision memory.
	rec.shape = null
	rec.baked_scale = Vector3.ONE
	rec.collision_dirty = true
	rec.shape_parked = false
	_free_collision_debug(rec)


## Switches a chunk's collision on or off according to the active policy.
##
## Under LAZY a chunk is BUILT the first time it is needed and afterwards only parked when it
## leaves the radius, rather than destroyed. Parking costs a fraction of a microsecond where a
## rebuild costs tens to hundreds, which matters because a target moving through the world
## keeps re-entering chunks it has already visited. Genuine release only happens once the
## parked list outgrows the manager's collision_retain_limit.
func set_chunk_collision_enabled(coord: Vector2i, enabled: bool) -> void:
	if Engine.is_editor_hint() or _collision_policy == COLLISION_NONE:
		return

	if _collision_policy == COLLISION_LAZY:
		if enabled:
			_parked.erase(coord)
			ensure_chunk_collision(coord)
			_set_shape_parked(coord, false)
		else:
			if not has_body(coord):
				return
			_set_shape_parked(coord, true)
			_park(coord)
		return

	_set_shape_parked(coord, not enabled)


## Parks or unparks a built collider: the body and its shape stay allocated either way.
func _set_shape_parked(coord: Vector2i, parked: bool) -> void:
	if not _records.has(coord):
		return
	var rec: ChunkRecord = _records[coord]
	if not rec.body_rid.is_valid():
		return
	if PhysicsServer3D.body_get_shape_count(rec.body_rid) == 0:
		return
	rec.shape_parked = parked
	PhysicsServer3D.body_set_shape_disabled(rec.body_rid, 0, parked)
	_update_collision_debug(rec)


## Records a chunk as parked and enforces the retention limit, freeing the oldest entries.
func _park(coord: Vector2i) -> void:
	_parked.erase(coord)
	_parked.append(coord)

	var limit: int = 0
	if _manager != null:
		limit = maxi(_manager.collision_retain_limit, 0)

	while _parked.size() > limit:
		var oldest: Vector2i = _parked[0]
		_parked.remove_at(0)
		release_chunk_collision(oldest)


## True when the chunk currently owns a physics body at all, parked or not.
func has_body(coord: Vector2i) -> bool:
	if not _records.has(coord):
		return false
	return (_records[coord] as ChunkRecord).body_rid.is_valid()


## True when the chunk's collider exists AND actually takes part in collision.
func has_active_body(coord: Vector2i) -> bool:
	if not _records.has(coord):
		return false
	var rec: ChunkRecord = _records[coord]
	return rec.body_rid.is_valid() and not rec.shape_parked


## Test-only accessor: how many built colliders are currently parked.
func get_debug_parked_count() -> int:
	return _parked.size()


# --- COLLISION DEBUG OVERLAY ---
# Reuses Shape3D.get_debug_mesh(), the very geometry CollisionShape3D renders, so the overlay
# shows the real collider rather than an approximation of it.


## Turns the collider overlay on or off for every chunk at once.
func set_collision_debug_enabled(enabled: bool) -> void:
	if _collision_debug == enabled:
		return
	_collision_debug = enabled

	if not enabled:
		for coord: Vector2i in _records:
			_free_collision_debug(_records[coord])
		_debug_material = null
		return

	for coord: Vector2i in _records:
		_update_collision_debug(_records[coord])


func is_collision_debug_enabled() -> bool:
	return _collision_debug


## Creates, refreshes or removes a chunk's overlay so it always matches the live collider.
func _update_collision_debug(rec: ChunkRecord) -> void:
	# A parked collider takes part in no collision test, so drawing it would misrepresent what
	# is actually active - which is the one thing this overlay exists to show.
	if not _collision_debug or rec.shape == null or not rec.body_rid.is_valid() \
	or rec.shape_parked:
		_free_collision_debug(rec)
		return

	# The debug mesh is derived from the shape, which already carries the folded scale, so the
	# overlay uses the body's own scale-free transform and lines up exactly.
	rec.debug_mesh = rec.shape.get_debug_mesh()
	if rec.debug_mesh == null:
		_free_collision_debug(rec)
		return

	if _debug_material == null:
		_debug_material = StandardMaterial3D.new()
		_debug_material.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
		_debug_material.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
		_debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_debug_material.albedo_color = Color(0.0, 0.6, 0.7, 0.42)

	if not rec.debug_instance_rid.is_valid():
		rec.debug_instance_rid = RenderingServer.instance_create()
		# A diagnostic overlay must not throw shadows or contribute to lighting.
		RenderingServer.instance_geometry_set_cast_shadows_setting(
			rec.debug_instance_rid, RenderingServer.SHADOW_CASTING_SETTING_OFF
		)
		if _scenario.is_valid():
			RenderingServer.instance_set_scenario(rec.debug_instance_rid, _scenario)

	RenderingServer.instance_set_base(rec.debug_instance_rid, rec.debug_mesh.get_rid())
	RenderingServer.instance_geometry_set_material_override(
		rec.debug_instance_rid, _debug_material.get_rid()
	)
	_push_debug_transform(rec)
	RenderingServer.instance_set_visible(rec.debug_instance_rid, _cached_visible)


func _push_debug_transform(rec: ChunkRecord) -> void:
	if not rec.debug_instance_rid.is_valid():
		return
	var rotation_only: Basis = _cached_global_transform.basis.orthonormalized()
	var world_origin: Vector3 = (_cached_global_transform * rec.local_transform).origin
	RenderingServer.instance_set_transform(
		rec.debug_instance_rid, Transform3D(rotation_only, world_origin)
	)


func _free_collision_debug(rec: ChunkRecord) -> void:
	if rec.debug_instance_rid.is_valid():
		RenderingServer.free_rid(rec.debug_instance_rid)
		rec.debug_instance_rid = RID()
	rec.debug_mesh = null


## Number of chunks currently drawing a collider overlay. Used by the test suite.
func get_debug_collision_overlay_count() -> int:
	var total: int = 0
	for coord: Vector2i in _records:
		if (_records[coord] as ChunkRecord).debug_instance_rid.is_valid():
			total += 1
	return total



## Re-applies the manager's collision layer to every live body.
func refresh_collision_layer() -> void:
	if _manager == null:
		return
	for coord: Vector2i in _records:
		var rec: ChunkRecord = _records[coord]
		if rec.body_rid.is_valid():
			PhysicsServer3D.body_set_collision_layer(rec.body_rid, _manager.collision_layer)


func _apply_material(rec: ChunkRecord) -> void:
	if not rec.instance_rid.is_valid():
		return
	var material: Material = _manager.custom_material if _manager != null else null
	var material_rid: RID = material.get_rid() if material != null else RID()
	RenderingServer.instance_geometry_set_material_override(rec.instance_rid, material_rid)

	# The painted layers ride on a material OVERLAY, which is what a MeshInstance3D would call
	# material_overlay. Keeping it separate is what lets painting work over any base material
	# without writing anything into it.
	var overlay: Material = _manager.get_active_paint_material() if _manager != null else null
	var overlay_rid: RID = overlay.get_rid() if overlay != null else RID()
	RenderingServer.instance_geometry_set_material_overlay(rec.instance_rid, overlay_rid)



## Releases records whose coordinates fall outside the current world dimensions.
func prune_out_of_bounds(world_chunks: Vector2i) -> void:
	var stale: Array[Vector2i] = []
	for coord: Vector2i in _records:
		if coord.x < 0 or coord.x >= world_chunks.x or coord.y < 0 or coord.y >= world_chunks.y:
			stale.append(coord)
	for coord: Vector2i in stale:
		_destroy_record(_records[coord])
		_records.erase(coord)

	# Rebuilt in one pass rather than erased per entry. Array.erase() is a linear scan, so
	# removing m of n records one at a time costs O(n*m) where rebuilding costs O(n).
	if not stale.is_empty():
		_record_list.clear()
		for coord: Vector2i in _records:
			_record_list.append(_records[coord])

	var stale_previews: Array[Vector2i] = []
	for coord: Vector2i in _preview_instances:
		if coord.x < 0 or coord.x >= world_chunks.x or coord.y < 0 or coord.y >= world_chunks.y:
			stale_previews.append(coord)
	for coord: Vector2i in stale_previews:
		_free_preview_instance(coord)


## Releases every server resource this backend ever allocated. Safe to call more than once.
func destroy_all() -> void:
	for coord: Vector2i in _records:
		_destroy_record(_records[coord])
	_records.clear()
	_record_list.clear()
	_parked.clear()

	for coord: Vector2i in _preview_instances.keys():
		_free_preview_instance(coord)
	_preview_instances.clear()

	_preview_mesh = null
	_preview_material = null
	_preview_dims = Vector2.ZERO
	_debug_material = null
	_scenario = RID()
	_space = RID()
	_body_count = 0
	_transform_pushed = false


func _destroy_record(rec: ChunkRecord) -> void:
	# Order matters: the body references the shape, and the instance references the mesh.
	if rec.body_rid.is_valid():
		PhysicsServer3D.free_rid(rec.body_rid)
		rec.body_rid = RID()
		_body_count -= 1
	if rec.instance_rid.is_valid():
		RenderingServer.free_rid(rec.instance_rid)
		rec.instance_rid = RID()
	_free_collision_debug(rec)
	rec.shape = null
	rec.mesh = null
	rec.has_terrain = false



## Drops a chunk's terrain geometry while keeping its instance allocated for later reuse.
func _clear_terrain_geometry(coord: Vector2i) -> void:
	if not _records.has(coord):
		return
	var rec: ChunkRecord = _records[coord]
	rec.has_terrain = false
	rec.mesh = null
	rec.collision_dirty = true
	if rec.instance_rid.is_valid():
		RenderingServer.instance_set_base(rec.instance_rid, RID())
		RenderingServer.instance_set_visible(rec.instance_rid, false)

	# A chunk without geometry must not keep a collider. Leaving it alive would give the
	# deactivated area invisible collision and pin its shape memory for the whole session.
	_free_body(rec)


## Creates or refreshes the editor preview quad shown for a deactivated chunk. Every preview
## points at the exact same mesh and material resource and differs only by transform.
func _ensure_preview_instance(coord: Vector2i) -> void:
	if _manager == null:
		return
	_ensure_shared_preview_resources()
	if _preview_mesh == null:
		return

	var rid: RID = _preview_instances.get(coord, RID())
	if not rid.is_valid():
		rid = RenderingServer.instance_create()
		# Matches the MESH_NODES preview, which lives on a MeshInstance3D and therefore casts.
		_apply_meshinstance_defaults(rid)
		_preview_instances[coord] = rid
		if _scenario.is_valid():
			RenderingServer.instance_set_scenario(rid, _scenario)

	RenderingServer.instance_set_base(rid, _preview_mesh.get_rid())
	RenderingServer.instance_geometry_set_material_override(rid, _preview_material.get_rid())
	RenderingServer.instance_set_transform(
		rid, _cached_global_transform * _local_transform_for(coord)
	)
	RenderingServer.instance_set_visible(rid, _cached_visible)


func _free_preview_instance(coord: Vector2i) -> void:
	if not _preview_instances.has(coord):
		return
	var rid: RID = _preview_instances[coord]
	if rid.is_valid():
		RenderingServer.free_rid(rid)
	_preview_instances.erase(coord)


## Rebuilds the shared preview mesh only when the chunk dimensions actually changed.
func _ensure_shared_preview_resources() -> void:
	var dims := Vector2(float(_manager.chunk_size), _manager.cell_size)
	if _preview_mesh != null and _preview_dims.is_equal_approx(dims):
		return

	_preview_mesh = LowPolyTerrainMeshBuilder.build_deactivated_preview_mesh(
		_manager.chunk_size, _manager.cell_size
	)
	if _preview_material == null:
		_preview_material = LowPolyTerrainMeshBuilder.build_deactivated_preview_material()
	_preview_dims = dims

	# Re-point every existing preview instance at the freshly rebuilt mesh.
	if _preview_mesh != null:
		for coord: Vector2i in _preview_instances:
			var rid: RID = _preview_instances[coord]
			if rid.is_valid():
				RenderingServer.instance_set_base(rid, _preview_mesh.get_rid())


func _local_transform_for(coord: Vector2i) -> Transform3D:
	if _manager == null:
		return Transform3D.IDENTITY
	var meters: float = float(_manager.chunk_size) * _manager.cell_size
	return Transform3D(
		Basis.IDENTITY,
		Vector3(float(coord.x) * meters, 0.0, -float(coord.y) * meters)
	)



## Returns every chunk coordinate this backend currently tracks, including preview-only ones.
func get_coords() -> Array:
	var result: Array = _records.keys()
	for coord: Vector2i in _preview_instances:
		if not _records.has(coord):
			result.append(coord)
	return result


func has_chunk(coord: Vector2i) -> bool:
	return _records.has(coord) or _preview_instances.has(coord)


## Returns the renderable geometry of a chunk, or null when it carries none.
func get_mesh(coord: Vector2i) -> ArrayMesh:
	if not _records.has(coord):
		return null
	var rec: ChunkRecord = _records[coord]
	return rec.mesh if rec.has_terrain else null


func get_local_transform(coord: Vector2i) -> Transform3D:
	return _local_transform_for(coord)


## Test-only accessor exposing the raw record so RID validity can be asserted.
func get_debug_record(coord: Vector2i) -> ChunkRecord:
	return _records.get(coord, null)


## Test-only accessor reporting how many distinct preview resources exist. Must stay at one
## mesh and one material no matter how many chunks are deactivated.
func get_debug_preview_stats() -> Dictionary:
	return {
		"instances": _preview_instances.size(),
		"meshes": 0 if _preview_mesh == null else 1,
		"materials": 0 if _preview_material == null else 1,
	}
