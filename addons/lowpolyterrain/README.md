# Low Poly Terrain Builder

An intuitive, optimized, and robust 3D terrain sculpting tool tailored for creating organic low-poly landscapes inside the Godot 4 editor.

## ✅ **Update information for v1.0.10 (The Zero-Latency & UI Polish Update):**
Version 1.0.10 brings fluid editing and practical workflow additions.
Key additions:
* Fluid Painting: Completely optimized chunk activation and deactivation passes to maintain heavy editor performance on large terrains.
* Colored Visual Brush Circles: The 3D viewport indicator now dynamically updates its color profile based on the active sculpting mode for instant visual feedback.
* 2D Screen Label: The active brush info (mode, radius, strength) now stays perfectly readable directly beside the mouse pointer without 3D space distortion.
* Adjustable Brush Sharpness: A new slider allows you to choose between sharp low-poly cliff edges and soft, gradual slopes.
* Fixed Plateau Flattening: The flatten tool now locks its initial click height across fast mouse movements until the mouse button is released.

## ✅ **Update information for v1.0.9 (The UI & Workflow Update):**
Version 1.0.9 introduces an overhaul of the user interface and editing ergonomics. 
Key additions:
* a horizontal viewport toolbar
* configurable hotkeys for brush tools and brush radius scaling
* brush radius dependend activation and deactivation of chunks
	
## ✅ **Update information for v1.0.8 (Optimization):**
With v1.0.7, a very resource-intensive (GPU-heavy) default ShaderMaterial was used, causing frame drops on weaker systems. This issue has been resolved in v1.0.8. I also tested this add-on on my mobile device, achieving up to 1000 FPS within the editor.


![Low Poly Terrain Demo](lowpolyterrain_demo.jpg)

---

## 🚀 Key Features

* **Dynamic Chunk Management:** Grid blocks are handled fluidly within the editor without cluttering your scene files.
* **Organic Delaunay Topology:** Creates organic low-poly triangle networks for the typical landscape look.
* **Integrated Sculpting Brushes:** Includes intuitive Raise, Lower (with Shift-Invert), Flatten, Smooth, and dedicated Active/Inactive chunk toggles.
* **Ergonomic Viewport Toolbar:** Adds a horizontal radio-button menu with clear white SVG icons that automatically adapt to dark or light editor themes.
* **Dynamic Color Indicators:** Features a colored 3D brush circle aligned directly to active terrain tool colors.
* **Crisp 2D Mouse Display:** Shows the current tool name, radius, and strength directly at your cursor so you always know what you are painting.
* **Laptop-Friendly Radius Control:** Scale your brush radius fluidly in mid-air by holding or tapping **, (Comma)** or **. (Period)** without camera interference.
* **Production-Ready GLTF Export:** Exports active terrain chunks directly into a standalone `.gltf` asset for other tools or projects.
* **Lossless Grid Migration:** Allows safe resizing of the terrain dimensions in the inspector without losing existing hills or data.
* **Dynamic Live Physics Baking:** Generates static 3D colliders instantly for your terrain, automatically skipping invisible sections.

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
