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

---

## ⚙️ Inspector Configuration Parameters

| Property | Group | Type | Description |
| :--- | :--- | :--- | :--- |
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
| **Show Deactivated Chunks** | Terrain Properties | `bool` | Shows or hides semi-transparent red grid boxes over disabled coordinates. |
| **Custom Material** | Terrain Properties | `Resource` | Slot for custom 3D shader or standard materials. |
| **Export Target Path** | Data Export | `String` | Target path where the exported `.gltf` file will be saved. |
| **Choose Path & Export Terrain** | Data Export | `Button` | Opens a file dialog to name and save the model asset. |
| **Collision Layer / Group** | Collision Generation | `Flags / String` | Physics layer mask and custom scene group name for colliders. |

---

## ⌨️ Viewport Hotkeys

* **Tool Swapping:** `Q` (Raise), `W` (Lower), `E` (Flatten), `R` (Smooth), `A` (Activate), `S` (Deactivate).
* **Brush Size:** Hold `,` (Comma) to shrink or `.` (Period) to expand the selection circle seamlessly.
* **Polarity Inversion:** Hold `Shift` during sculpt passes to instantly flip `Raise` into `Lower`.
