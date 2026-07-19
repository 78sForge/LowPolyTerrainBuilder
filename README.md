# Low Poly Chunk Terrain Plugin for Godot 4.7+

An intuitive, optimized, and robust 3D terrain sculpting tool tailored for creating organic
low-poly landscapes. Powered by deterministic Delaunay triangulation and slope-aware vertex
jittering, this plugin ensures complete cross-chunk seam blending and zero-latency editor
painting performance.

---

## 🚀 Key Features

* **Dynamic Chunk Management:** 
  Automatically breaks the terrain map down into grid blocks initialized natively inside the
  editor RAM without cluttering your persistent `.tscn` save file layout.

* **High-Performance Packed Arrays:**
  Utilizes a heavily optimized `PackedFloat32Array` architecture for storing `global_height_data`
  instead of dynamic dictionaries, maximizing memory throughput and minimizing cache misses.

* **Organic Delaunay Topology:** 
  Abandons the typical stiff voxel/grid layout by calculating custom triangle networks on
  mathematically shifted vertex points.

* **Lossless Grid Migration:** 
  Safely handles real-time inspector resizing. Shrinking map boundaries filters data safely,
  while enlarging matrices copies matching height points coordinate-accurately.

* **Dynamic Live Physics Baking:** 
  Instantiates persistent 3D static colliders parallel to the terrain manager under your scene
  root to avoid cyclical memory architecture loops or load-time `Invalid Owner` tree crashes.

* **Physics Optimization & Distance Culling:**
  By parsing the physical terrain into modular, individual `StaticBody3D` nodes mapped per chunk
  rather than compiling one massive global landscape collider, the architecture unlocks advanced
  performance optimization pathways. Developers can seamlessly hook into this structure to
  dynamically toggle collider visibility (`disabled = true`) or remove out-of-range chunk
  colliders based on the factual distance to the active player node. This drastically reduces
  the calculation overhead for Godot's 3D physics engine pipeline, boosting runtime frame rates
  in large world environments.

---

## 🛠 Sculpting & Painting Brushes

The terrain editing workflow features an enum-driven canvas brush layout that easily
accommodates multi-vertex operations. Holding **Shift** triggers contextual inverse
modifications:

* **Raise / Lower:** 
  Modifies global vertex matrices based on your exact `step_height` constraints. Holding
  **Shift** seamlessly toggles the operational polarity (e.g., inverts *Raise* into *Lower*).

* **Flatten:** 
  Samples the initial click height to instantly smooth any painted features to a cohesive
  terrace plateau.

* **Smooth:** 
  Blurs and average-blends adjacent vertex elevations using a real-time linear interpolation
  cross-filter (`lerpf`). Holding **Shift** during a *Flatten* stroke automatically runs this
  smoothing brush.

---

## 📐 Underlying Mathematics & Algorithms

### 1. Reproducible Coordinates via Sine-Hash Jittering

To establish a distinct artistic poly style without loose global random seeds shifting your
shapes on scene reload, the mesh relies on a deterministic sine trigonometry hashing algorithm:

```math
hash(x, z) = frac(sin(x * 12.9898 + z * 78.233) * 43758.5453)
```

This calculation yields pseudo-random vectors between `-1.0` and `1.0` that are 100%
reproducible for any specific global coordinate pair across the scene lifetime.

### 2. Slope-Aware Jitter Attenuation

To protect flat plains and terrace pathways from getting distorted by noisy polygon spikes, the
mesh updates apply an automated slope incline calculation using cardinal neighbors:

```math
slope \(= \frac\){max(\(\vert{}h_{right} -\) h_{left}|, |h_{down} - h_{up}|)}{cell\_size * 2.0}
```

Vertices are only offset if this calculation matches your user-defined `jitter_slope_threshold`.
Steep cliffs receive full geometric fracturing, while horizontal surfaces scale down to zero
noise.

### 3. Boundary Edge Decimation

To guarantee seamless, crack-free rendering transitions where separate chunk grids touch, the
triangulation engine runs explicit boundary constraints. Points located on active edges skip
spatial noise alterations. 

Furthermore, flat boundaries are systematically decimated using modular constraints
(`index % 4 != 0`) to counteract complex web artifact patterns.

### 4. Fragment-Level Flat Face Normals

Instead of forcing expensive vertex splitting across the index arrays to create crisp edges, the
low-poly material injects hardware-accelerated partial screen derivatives (`dFdx` and `dFdy`)
straight into the fragment lighting loop:

```glsl
vec3 flat_normal = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
NORMAL = flat_normal;
```

This forces flat lighting calculations directly on the individual triangle surfaces, unlocking
high performance.

---

## ⚙️ Inspector Configuration Parameters

| Property | Group | Type | Description |
| :--- | :--- | :--- | :--- |
| **Preview World Chunks** | World Dimensions | `Vector2i` | Map size configuration layout
measured in full grid chunks (X, Z). |

| **Preview Chunk Size** | World Dimensions | `int` | Segment subdivision count per chunk.
Controls localized vertex density. |

| **Preview Cell Size** | World Dimensions | `float` | Horizontal coordinate span multiplier
(in meters) for grid subdivisions. |

| **Apply Dimension Changes** | World Dimensions | `Button` | Resolves Lambda Callables to
migrate your height matrices safely to a new scale. |

| **Step Height** | Terrain Properties | `float` | Precise vertical increment size applied
per stroke during shaping. |

| **Jitter Strength** | Terrain Properties | `float` | Maximum random vertex displacement
amount to generate the look. |

| **Jitter Slope Threshold** | Terrain Properties | `float` | Slope angle constraint. Lower
values allow noise on flatter pathways. |

| **Custom Material** | Terrain Properties | `Resource` | Inspector custom resource slot
filtering out Fog/Particles. Accepts only 3D materials. |

| **Collision Layer / Group** | Collision Generation | `Flags / String` | Custom physics layer
mask and scene group definitions for the colliders. |

---

## 🧪 Automated Stability Testing

The plugin packages an internal automated test script running on the **Godot Unit Test (GUT)**
framework. It isolates map operations to verify features safely:

1. **Grid Allocation Validation:** 
   Tests if RAM matrix sizing correctly matches specifications.

2. **Cardinal Seam Verification:** 
   Simulates strokes directly on boundary intersecting coordinates to assert if all 4
   interlocking chunk edges synchronize data flawlessly.

3. **Winding Order Integrity:** 
   Assures that generated Delaunay indices follow true counter-clockwise wind orientations to
   bypass backface culling errors.
