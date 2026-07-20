# AI Coding Rules & Context - LowPolyTerrainBuilder

## 1. Project Context & Environment
* **Engine:** Godot 4.7+ (GDScript 2.0 & GDShader)
* **Project Type:** 3D Editor Plugin / Terrain Sculpting Tool
* **Core Tech:** Deterministic Delaunay triangulation, chunk-based terrain generation, 
  distance-culling physics collision.
* **Languages:** GDScript, GDShader

## 2. General Output & Editing Constraints (STRICT)
* **No Unsolicited Refactoring:** Do NOT rewrite, refactor, or clean up any code unless 
  explicitly requested.
* **Strict Task Scope:** If asked to add comments, add *only* comments. If asked to fix a 
  specific bug, touch *only* the lines related to that bug.
* **Preserve Functionality:** Never change existing functionality, variable definitions, or 
  architecture pipelines without permission.
* **Code Only:** When updating files, output the full modified code block or precise diffs 
  without conversational filler.
* **Additional format constrainst:** Limit each line (code or documentation) to a maximum of 
  100 characters to enable better readability. Except for table formattings in order to 
  avoid broken tables.

## 3. Language & Modern Godot 4.7+ Syntax Standards
* **English Only:** All code elements—including variable names, function names, class names, 
  constants, and inline or block comments—MUST be written in English.
* **Godot 4 Styling:** Follow official Godot GDScript style guidelines (snake_case for 
  functions/variables, PascalCase for classes, UPPER_CASE for constants).
* **Static Typing:** Always use explicit static typing for variables, arguments, and function 
  return types (e.g., `var chunk_size: int = 16`, `func get_height() -> float`).
* **Strict Modern API Execution:** Never use obsolete Godot 3.x or early 4.0 constructs.
	* Use modern signal connection: `signal.connect(callable)` — NEVER use `connect("signal", 
	  target)`.
	* Use modern string formatting: `"Value: %s" % var` or `str(var)` — NEVER use old string 
	  utility methods.
	* Use Lambda Callables for runtime migrations where appropriate, leveraging Godot 4.7+ 
	  syntax improvements.

## 4. Technical Guardrails & Editor Behavior
* **Editor `@tool` Awareness:** This is an editor plugin. Always check if a script requires the 
  `@tool` annotation at the very top to execute inside the editor RAM.
* **RAM Data Isolation:** Chunk data is initialized inside editor RAM to prevent `.tscn` bloat. 
  Do not inject persistent scene-saving code unless explicitly requested.
* **Deterministic Generation:** Any mathematical changes to the mesh generation must preserve 
  the deterministic sine-hash approach (`hash(x, z)` formula).
* **Boundary Decimation:** Boundary edges must never receive random spatial noise or jitter to 
  keep chunk seams perfectly blended (use the `index % 4 != 0` constraint).

## 5. Performance Optimization Standards (CRITICAL)
* **Zero-Latency Target:** All algorithms, brush strokes, and loops must be strictly optimized 
  for real-time execution to guarantee zero-latency editor painting and peak runtime FPS.
* **Optimized Math & Type Casting:** Avoid un-typed arrays or dynamic lookups in loops. Use 
  PackedVector3Array or PackedFloat32Array for mesh generation. Cache calculation values.
* **Efficient Memory Allocation:** Minimize allocations inside process loops. Reuse objects, 
  leverage distance-culling, and disable distant colliders natively (`disabled = true`).

## 6. Automated Testing Rules (GUT Framework)
* **Framework:** All internal automated test scripts must strictly use the **Godot Unit Test 
  (GUT)** framework.
* **Validation Protocols:** When writing or updating tests, ensure you adhere to the three main 
  project test pillars:
	1. Grid Allocation Validation (RAM matrix scaling checks).
	2. Cardinal Seam Verification (asserting that all 4 interlocking chunk edges synchronize 
	  data flawlessly).
	3. Winding Order Integrity (verifying counter-clockwise wind orientations to bypass 
	  backface culling errors).
