# Low Poly Chunk Terrain Plugin for Godot 4.7+

An intuitive, optimized, and robust 3D terrain sculpting tool tailored for creating organic low-poly landscapes.

---

## 🚀 Key Features

*  **Dynamic Chunk Management:** Grid blocks are initialized inside editor RAM without cluttering `.tscn` files.
*  **High-Performance Packed Arrays:** Uses `PackedFloat32Array` for `global_height_data` to maximize memory throughput.
*  **Organic Delaunay Topology:** Calculates custom triangle networks on mathematically shifted vertex points.
*  **Integrated Sculpting Brushes:** Includes intuitive Raise/Lower (with Shift-Invert), Flatten, and Smooth tools.
*  **Production-Ready GLTF Export:** Bakes active visual chunk meshes into standalone, decoupled `.gltf` assets.
*  **Lossless Grid Migration:** Safely copies height points coordinate-accurately during real-time inspector resizing.
*  **Dynamic Live Physics Baking:** Instantiates persistent 3D static colliders parallel to the terrain manager.
*  **Physics Optimization:** Modular per-chunk `StaticBody3D` nodes allow distance culling and toggleable visibility.

---

## ⚙️ Inspector Configuration Parameters

| Property | Group | Type | Description |
| :--- | :--- | :--- | :--- |
| **Preview World Chunks** | World Dimensions | `Vector2i` | Map size configuration layout measured in full grid chunks (X, Z). |
| **Preview Chunk Size** | World Dimensions | `int` | Segment subdivision count per chunk. Controls localized vertex density. |
| **Preview Cell Size** | World Dimensions | `float` | Horizontal coordinate span multiplier (in meters) for grid subdivisions. |
| **Apply Dimension Changes** | World Dimensions | `Button` | Resolves Lambda Callables to migrate your height matrices safely to a new scale. |
| **Step Height** | Terrain Properties | `float` | Precise vertical increment size applied per stroke during shaping. |
| **Jitter Strength** | Terrain Properties | `float` | Maximum random vertex displacement amount to generate the look. |
| **Jitter Slope Threshold** | Terrain Properties | `float` | Slope angle constraint. Lower values allow noise on flatter pathways. |
| **Custom Material** | Terrain Properties | `Resource` | Inspector custom resource slot filtering out Fog/Particles. Accepts only 3D materials. |
| **Export Target Path** | Data Export | `String` | Project-relative storage directory configuration layout where the `.gltf` asset is written. |
| **Choose Path & Export Terrain** | Data Export | `Button` | Spawns an integrated native EditorFileDialog to choose directories, type new names, and trigger the export. |
| **Collision Layer / Group** | Collision Generation | `Flags / String` | Custom physics layer mask and scene group definitions for the colliders. |
