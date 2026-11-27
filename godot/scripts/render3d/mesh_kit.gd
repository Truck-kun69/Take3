class_name MeshKit
extends RefCounted
## Bakes primitives into one vertex-coloured ArrayMesh (one draw call per model, instancing friendly).
## Every vertex carries an animation channel in UV2:
##   UV2.x = part id  (see PART_*), UV2.y = pivot height of that part in model space
## The foe shader reads them to swing legs/arms, bob heads, wave tendrils and light up eyes, so a
## single instanced mesh still walks. Models face +X, up is +Y, flanks are +/-Z.

const PART_BODY := 0
const PART_LEG_L := 1
const PART_LEG_R := 2
const PART_ARM_L := 3
const PART_ARM_R := 4
const PART_HEAD := 5
const PART_EYE := 6        # emissive
const PART_GLOW := 7       # emissive, pulses
const PART_TAIL := 8       # waves

var st := SurfaceTool.new()
var _prims := {}

func _init() -> void:
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

func _prim(kind: String, seg: int) -> Array:
	var key := kind + str(seg)
	if _prims.has(key):
		return _prims[key]
	var m: PrimitiveMesh
	match kind:
		"box": m = BoxMesh.new()
		"sphere":
			var s := SphereMesh.new(); s.radial_segments = seg; s.rings = maxi(3, seg / 2); s.radius = 0.5; s.height = 1.0; m = s
		"cyl":
			var c := CylinderMesh.new(); c.radial_segments = seg; c.rings = 1; c.top_radius = 0.5; c.bottom_radius = 0.5; c.height = 1.0; m = c
		"cone":
			var k := CylinderMesh.new(); k.radial_segments = seg; k.rings = 1; k.top_radius = 0.0; k.bottom_radius = 0.5; k.height = 1.0; m = k
		"prism": m = PrismMesh.new()
		"capsule":
			var cp := CapsuleMesh.new(); cp.radial_segments = seg; cp.rings = 2; cp.radius = 0.5; cp.height = 2.0; m = cp
		"torus":
			var t := TorusMesh.new(); t.rings = seg; t.ring_segments = 6; t.inner_radius = 0.8; t.outer_radius = 1.0; m = t
	var a := m.get_mesh_arrays()
	_prims[key] = a
	return a

## Adds a primitive: unit-sized `kind` scaled by `size`, rotated by `rot` (euler, radians), placed at `pos`.
func add(kind: String, pos: Vector3, size: Vector3, col: Color, part: int = PART_BODY, pivot_y: float = 0.0, rot: Vector3 = Vector3.ZERO, seg: int = 8) -> void:
	var a := _prim(kind, seg)
	var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var b := Basis.from_euler(rot) * Basis.from_scale(size)
	var nb := b.inverse().transposed()
	st.set_uv2(Vector2(part, pivot_y))
	st.set_color(col)
	for k in idx.size():
		var vi := idx[k]
		st.set_color(col)
		st.set_uv2(Vector2(part, pivot_y))
		st.set_normal((nb * norms[vi]).normalized())
		st.add_vertex(b * verts[vi] + pos)

## Symmetric pair on +/-Z.
func pair(kind: String, pos: Vector3, size: Vector3, col: Color, part_l: int, part_r: int, pivot_y: float = 0.0, rot: Vector3 = Vector3.ZERO, seg: int = 8) -> void:
	add(kind, Vector3(pos.x, pos.y, -pos.z), size, col, part_l, pivot_y, Vector3(-rot.x, -rot.y, rot.z), seg)
	add(kind, pos, size, col, part_r, pivot_y, rot, seg)

func commit() -> ArrayMesh:
	st.index()
	return st.commit()
