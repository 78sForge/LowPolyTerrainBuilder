# Low Poly Terrain Builder

An intuitive, optimized, and robust 3D terrain sculpting tool tailored for creating organic
low-poly landscapes inside the Godot 4 editor.

## ✅ **Update information for v1.0.13 (The Noise Layer & Compatibility Update):**
Version 1.0.13 introduces procedural noise detailing and critical fixes for the OpenGL backend.
Key additions:
* Additive Noise Layering: Injects organic surface details directly onto existing sculpted shapes.
* Zero-Drift Amplitude: Uses a balanced multiplier to keep the average height level stable.
* Chunk-Activity Awareness: Automated safety filters skip deactivated chunks during noise passes.
* Compatibility Renderer Fixes: Resolves rendering artifacts, black spots, and flickering in OpenGL.
* Explicit UV Mapping: Generates native UV coordinates to prevent graphics driver fallbacks.
* Smooth Group Tuning: Forces 'st.set_smooth_group(-1)' to enforce a crisp, artifact-free look.
* Optimized Vertex Pipeline: Re-enables indexing, normals, and tangents to lower GPU overhead.

## ✅ **Update information for v1.0.12 (The Zero-Latency & UI Polish Update):**
Version 1.0.12 brings fluid editing and practical workflow additions.
Key additions:
* Fluid Painting: Optimized chunk activation passes to maintain heavy editor performance.
* Colored Visual Brush Circles: Viewport indicator dynamically updates its color profile.
* 2D Screen Label: Active brush info stays perfectly readable beside the mouse pointer.
* Adjustable Brush Sharpness: Choose between sharp cliff edges and soft, gradual slopes.
* Fixed Plateau Flattening: Flatten tool locks its initial click height across fast movements.

## ✅ **Update information for v1.0.9 (The UI & Workflow Update):**
Version 1.0.9 introduces an overhaul of the user interface and editing ergonomics. 
Key additions:
* a horizontal viewport toolbar
* configurable hotkeys for brush tools and brush radius scaling
* brush radius dependend activation and deactivation of chunks
	
## ✅ **Update information for v1.0.8 (Optimization):**
With v1.0.7, a very resource-intensive (GPU-heavy) default ShaderMaterial was used, causing
frame drops on weaker systems. This issue has been resolved in v1.0.8. I also tested this add-on
on my mobile device, achieving up to 1000 FPS within the editor.


![Low Poly Terrain Demo](lowpolyterrain_demo.jpg)

---

## 🚀 Key Features

* **Dynamic Chunk Management:** Grid blocks are handled fluidly without cluttering scene files.
* **Organic Delaunay Topology:** Creates organic triangle networks for typical landscape looks.
* **Integrated Sculpting Brushes:** Includes intuitive Raise, Lower, Flatten, and Smooth tools.
* **Procedural Noise Injector:** Generates seamless Perlin or Cellular landscapes instantly.
* **Ergonomic Viewport Toolbar:** Adds a horizontal radio-button menu with clear SVG icons.
* **Dynamic Color Indicators:** Features a colored 3D brush circle aligned to active tool colors.
* **Crisp 2D Mouse Display:** Shows current tool name, radius, and strength directly at cursor.
* **Laptop-Friendly Radius Control:** Scale your brush radius fluidly using comma and period keys.
* **Production-Ready GLTF Export:** Exports active terrain chunks directly into a standalone asset.
* **Lossless Grid Migration:** Safe resizing of terrain dimensions without losing existing data.
* **Dynamic Live Physics Baking:** Generates static 3D colliders instantly for active sections.
* **Multi-Backend Stability:** Fully optimized for Forward+, Mobile, and Compatibility renderers.
* **Selectable Submission Backend:** Render chunks as nodes or register them with the servers.
* **Radius-Based Collision Culling:** Enables physics near a target without per-collider scans.

---

## 🧱 Terrain Backend

The **Terrain Backend** setting sits at the very top of the inspector and decides how chunks
reach the engine. Both modes read from the same height data, so switching is lossless in
either direction and can be done at any time.

| | `MESH_NODES` (default) | `SERVERS` |
| :--- | :--- | :--- |
| Rendering | One `MeshInstance3D` child per chunk | `RenderingServer` instance per chunk, no nodes |
| Collision | Baked `StaticBody3D` container next to the manager | `PhysicsServer3D` static bodies, created at runtime |
| Node count | One node per chunk | Zero chunk nodes |
| Draw calls | Identical | Identical |
| Editor selection | Chunks are clickable in the viewport | Chunks are not clickable (see limitations) |

`SERVERS` does **not** reduce draw calls, primitives or GPU frame time. `MeshInstance3D` is a
thin wrapper around the very same `RenderingServer` calls. What it removes is the per-chunk
node: memory, scene-tree transform propagation and rebuild cost. That matters at high chunk
counts and it is what makes cheap streaming possible.

### Frame time

Draw calls, primitives and GPU time are identical by construction. Measured with rendering on a
10×10 grid of size-16 chunks, median `TIME_PROCESS` was 23.9 ms for unbaked `MESH_NODES` against
21.6 ms for `SERVERS`, and physics time dropped from 0.38 ms to 0.08 ms. Node count fell from 106
to 6.

There is one case where `SERVERS` is genuinely slower. If the manager, or any ancestor, changes
its transform, every chunk instance has to be re-pushed, and that loop runs in GDScript rather
than in Godot's C++ scene-graph propagation:

| Chunks | `MESH_NODES` | `SERVERS` |
| ---: | ---: | ---: |
| 100 | 0.6 µs | 14.5 µs |
| 400 | 1.8 µs | 54.3 µs |
| 900 | 4.1 µs | 124.4 µs |

This cost applies **once per frame** (Godot coalesces transform notifications) and **only while
the manager is actually moving**. A stationary terrain pays nothing. If you animate a terrain of
several thousand chunks, prefer `MESH_NODES`.

### Memory

Collision, not rendering, dominates the memory profile. Measured on a 10×10 grid of size-16
chunks (51 200 triangles), each configuration in its own process:

| Configuration | RAM | Colliders |
| :--- | ---: | ---: |
| `MESH_NODES`, never baked | 6.1 MB | 0 |
| `MESH_NODES`, baked | 18.3 MB | 100 |
| `SERVERS`, `RuntimeCollision.NONE` | 6.4 MB | 0 |
| `SERVERS`, `RuntimeCollision.ALL` | 17.5 MB | 100 |
| `SERVERS`, `CULLED`, 40 m radius | 10.1 MB | 32 |
| `SERVERS`, `CULLED`, 20 m radius | 8.0 MB | 12 |

Compare like with like: `SERVERS` + `ALL` against **baked** `MESH_NODES`, where it is slightly
cheaper. An unbaked `MESH_NODES` terrain has no collision at all, so it is not a fair baseline.

A concave collider costs roughly 110 KB per chunk, most of it inside the physics server rather
than in the face data itself. Releasing one does **not** give that memory back, so `CULLED`
never builds a collider for a chunk outside the radius in the first place. That is where the
saving comes from.

### SERVERS mode limitations

* Chunks cannot be picked or framed in the editor viewport, because server instances are
  invisible to the editor's click-selection.
* **Bake Live Collisions** is hidden, since `PhysicsServer3D` already provides the physics and
  a baked container would duplicate it. Calling it from code is refused with a message.
* Switching to `SERVERS` removes an existing `<Manager>_Collisions` container. The removal is
  registered in the editor history, so a single `Ctrl+Z` brings it back.
* The manager's child count drops to one (`Terrain_Assets`). This is expected, not a defect.
* Game code that checks `collider is StaticBody3D` stops matching, because hits resolve to the
  manager. Check the collision group instead (see below).

---

## 🎯 Collision Culling

Collision is kept loaded only around the things that need it, and there are two ways to drive
that. Both work in either backend.

**Assign a target.** Drop your player into **Collision Cull Targets** in the inspector and you
are done - no glue code at all. The manager follows it once per physics frame and skips the
whole pass while no target has crossed a chunk boundary, so standing still costs nothing.
Several targets are allowed; the loaded region is the union of their radii.

An inspector reference can only point inside the same scene, so a player spawned at runtime is
registered in code instead:

```gdscript
terrain_manager.add_culling_target(player)
terrain_manager.remove_culling_target(player)   # on despawn
```

**Or drive it yourself** with the call the manager uses internally, for example from a level
controller:

```gdscript
func _physics_process(_delta: float) -> void:
	if is_instance_valid(player):
		terrain_manager.update_collision_culling(player.global_position, 40.0)
```

`update_collision_culling_multi(positions, radius_meters)` takes several centres at once.

The chunk grid is regular, so the affected chunks are derived arithmetically rather than by
measuring the distance to every collider. Cost scales with the radius instead of the world
size, and only the delta is pushed to the physics engine, so no amortization across frames
and therefore no reaction delay is required.

What the call does depends on **Runtime Collision**:

| `runtime_collision` | Behaviour of `update_collision_culling()` |
| :--- | :--- |
| `ALL` (default) | Colliders exist everywhere; the radius only enables/disables them. Cheapest to toggle, highest memory. |
| `CULLED` | Colliders are **built** on entering the radius and **released** on leaving. Lowest memory. |
| `NONE` | No effect; there is no runtime collision. |

> With `CULLED` something **must** drive the culling - either a target or your own call -
> otherwise the terrain has no collision whatsoever. With neither in place the manager pushes a
> warning two seconds in.

In `MESH_NODES` the call toggles `disabled` on the baked colliders instead, so the same setup
works in both backends. Baking produces a `Static_Chunk_<x>_<z>` body holding a
`Chunk_<x>_<z>_Col` shape, so a collider can be traced back to its chunk from the node name
alone. Scenes baked before that naming still work; the lookup resolves shapes by type.

**Collision Cull Radius** is measured in metres and pre-filled with two chunk edge lengths
(`chunk_size * cell_size * 2`). It is re-derived whenever the terrain dimensions change, but
only while it still matches the previously derived value, so an override you set on purpose is
never overwritten. Bigger is safer: collision has to be present *before* a target arrives, so
fast movers need more lead than walkers. Cost grows with the area, so quadratically.

### Seeing the colliders

Godot's **Debug → Visible Collision Shapes** cannot show `SERVERS` colliders. That feature is
implemented inside `CollisionShape3D`, and this backend deliberately has no such node.

**Collision Debug Draw** fills the gap. It renders the same geometry the built-in view would,
taken straight from `Shape3D.get_debug_mesh()`, as a translucent cyan wireframe:

| Value | Behaviour |
| :--- | :--- |
| `FOLLOW_DEBUG_MENU` (default) | Follows `Debug → Visible Collision Shapes`, exactly like node colliders do. |
| `ALWAYS` | Always drawn, including in a normal run. |
| `NEVER` | Never drawn. |

Because only chunks that actually own a collider light up, this is the direct way to watch
`CULLED` at work: the lit region *is* the culling radius. Turn it off for profiling, since the
wireframe adds line geometry per visible chunk.

---

## ⚙️ Inspector Configuration Parameters

| Property | Group | Type | Description |
| :--- | :--- | :--- | :--- |
| **Terrain Backend** | *(top level)* | `Enum` | `MESH_NODES` creates a `MeshInstance3D` per chunk. `SERVERS` registers chunks directly with `RenderingServer` and `PhysicsServer3D`. |
| **Preview World Chunks** | World Dimensions | `Vector2i` | Map size measured in full grid chunks (X, Z). |
| **Preview Chunk Size** | World Dimensions | `int` | Subdivision density per chunk. Controls details. |
| **Preview Cell Size** | World Dimensions | `float` | Scale size of a single grid square in meters. |
| **Apply Dimension Changes** | World Dimensions | `Button` | Resizes the terrain safely to the new dimensions. |
| **Step Height** | Terrain Properties | `float` | Vertical step height added or removed per brush stroke. |
| **Brush Radius** | Terrain Properties | `int` | Size of the painting tool radius. |
| **Brush Strength** | Terrain Properties | `float` | Multiplier for how fast the terrain deforms. |
| **Brush Falloff Strength** | Terrain Properties | `float` | Blends between sharp linear brush edges (0.0) and soft transitions (1.0). |
| **Jitter Strength** | Terrain Properties | `float` | Intensity of the random vertex displacement for the low-poly look. |
| **Jitter Slope Threshold** | Terrain Properties | `float` | Controls whether flat paths stay plain while hills get unique shapes. |
| **Noise Amplitude** | Noise Generation | `float` | Vertical scale multiplier for balanced height/depth noise distribution. |
| **Terrain Noise** | Noise Generation | `FastNoiseLite` | Target FastNoiseLite resource used for generating organic Perlin/Cellular shapes. |
| **Generate Noise Terrain** | Noise Generation | `Button` | Processes and injects the selected noise pattern into all active chunk vertices. |
| **Show Chunk Grid** | Terrain Properties | `bool` | Overlays a wireframe grid along the chunk boundaries in the editor. One line mesh for the whole terrain, so the cost does not grow with chunk count. |
| **Show Deactivated Chunks** | Terrain Properties | `bool` | Shows or hides semi-transparent red grid boxes over disabled coordinates. |
| **Custom Material** | Terrain Properties | `Resource` | Slot for custom 3D shader or standard materials. |
| **Export Target Path** | Data Export | `String` | Target path where the exported `.gltf` file will be saved. |
| **Choose Path & Export Terrain** | Data Export | `Button` | Opens a file dialog to name and save the model asset. |
| **Runtime Collision** | Collision Generation | `Enum` | `SERVERS` only, hidden otherwise. `ALL` gives every active chunk a collider. `CULLED` builds colliders only inside the culling radius. `NONE` disables runtime collision. |
| **Collision Cull Targets** | Collision Generation | `Array[Node3D]` | Nodes the culling follows, typically the player. The manager then drives culling itself once per physics frame. Empty means you drive it manually. |
| **Collision Cull Radius** | Collision Generation | `float` | Metres of collision kept around each target. Pre-filled with `chunk_size * cell_size * 2` and re-derived on dimension changes unless you overrode it. |
| **Collision Debug Draw** | Collision Generation | `Enum` | `SERVERS` only, hidden otherwise. Draws live colliders as a translucent wireframe, since Godot's own Visible Collision Shapes cannot see server bodies. |
| **Collision Layer / Group** | Collision Generation | `Flags / String` | Physics layer mask and custom scene group name for colliders. In `SERVERS` mode the group is applied to the **manager** itself and bodies report the manager as their collider, so `collider.is_in_group("Wall")` keeps working. |

---

## ⌨️ Viewport Hotkeys

* **Tool Swapping:** `Q` (Raise), `W` (Lower), `E` (Flatten), `R` (Smooth), `A` (Activate), `S` (Deactivate).
* **Brush Size:** Hold `,` (Comma) to shrink or `.` (Period) to expand the selection circle seamlessly.
* **Polarity Inversion:** Hold `Shift` during sculpt passes to instantly flip `Raise` into `Lower`.
