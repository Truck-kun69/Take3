class_name CrowdCompute
extends RefCounted
## GPU crowd separation on a local RenderingDevice (Vulkan / Forward Mobile only).
##
## Each frame: upload [x, y, radius, uid] per foe, dispatch a tiled O(n^2) push solver (shared
## memory tiles of 64 bodies), and read the result back ONE FRAME LATER. Reading in the same frame
## would stall the CPU on the GPU (rd.sync blocks); a frame of latency on a soft separation force
## is invisible. Results are mapped back by uid, because swap-removal reorders the swarm between
## dispatch and collect.
##
## When no RenderingDevice exists (Compatibility renderer, headless, old GLES devices) `init()`
## returns false and World falls back to Swarm.cpu_separation (spatial-grid, O(n * k)).

const SRC := """
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) restrict readonly buffer Bodies { vec4 b[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer Push { vec2 p[]; };
layout(push_constant, std430) uniform Params { uint n; float strength; float pad0; float pad1; } pc;
shared vec4 tile[64];
void main() {
	uint i = gl_GlobalInvocationID.x;
	vec4 me = i < pc.n ? b[i] : vec4(0.0);
	vec2 acc = vec2(0.0);
	for (uint base = 0u; base < pc.n; base += 64u) {
		uint j = base + gl_LocalInvocationID.x;
		tile[gl_LocalInvocationID.x] = j < pc.n ? b[j] : vec4(1e9, 1e9, 0.0, -1.0);
		barrier();
		for (uint k = 0u; k < 64u; k++) {
			vec4 o = tile[k];
			vec2 dv = me.xy - o.xy;
			float rr = me.z + o.z;
			float d2 = dot(dv, dv);
			if (d2 < rr * rr && d2 > 1e-4) {
				float d = sqrt(d2);
				acc += dv / d * (rr - d);
			}
		}
		barrier();
	}
	if (i < pc.n) p[i] = acc * pc.strength;
}
"""

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var buf_in: RID
var buf_out: RID
var uset: RID
var ready := false
var in_flight := false
var flight_n := 0
var flight_uids := PackedInt32Array()
var _bodies := PackedFloat32Array()
var last_error := ""
var dispatches := 0

func init() -> bool:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		last_error = "no local RenderingDevice (compatibility/headless renderer)"
		return false
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = SRC
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		last_error = spirv.compile_error_compute
		push_warning("crowd shader: " + last_error)
		return false
	shader = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		last_error = "shader_create_from_spirv failed"
		return false
	pipeline = rd.compute_pipeline_create(shader)
	buf_in = rd.storage_buffer_create(Swarm.CAP * 16)
	buf_out = rd.storage_buffer_create(Swarm.CAP * 8)
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(buf_in)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(buf_out)
	uset = rd.uniform_set_create([u0, u1], shader, 0)
	_bodies.resize(Swarm.CAP * 4)
	flight_uids.resize(Swarm.CAP)
	ready = true
	return true

func dispatch(sw: Swarm) -> void:
	var n := sw.n
	if n == 0:
		return
	var pos := sw.pos
	var rad := sw.rad
	var fl := sw.flags
	for i in n:
		var p := pos[i]
		var o := i * 4
		_bodies[o] = p.x
		_bodies[o + 1] = p.y
		# bosses push others but are not pushed (they skip `sep` in step_move); allies do not collide
		_bodies[o + 2] = 0.0 if (fl[i] & Swarm.F_ALLY) != 0 else rad[i]
		_bodies[o + 3] = 0.0
		flight_uids[i] = sw.uid[i]
	rd.buffer_update(buf_in, 0, n * 16, _bodies.slice(0, n * 4).to_byte_array())
	var pc := PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, n)
	pc.encode_float(4, 6.0)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_set_push_constant(cl, pc, 16)
	rd.compute_list_dispatch(cl, int(ceil(n / 64.0)), 1, 1)
	rd.compute_list_end()
	rd.submit()
	in_flight = true
	flight_n = n
	dispatches += 1

func collect(sw: Swarm) -> void:
	if not in_flight:
		return
	rd.sync()
	in_flight = false
	var out := rd.buffer_get_data(buf_out, 0, flight_n * 8).to_float32_array()
	sw.apply_sep(out, flight_uids, flight_n)

func release() -> void:
	if rd == null:
		return
	if in_flight:
		rd.sync()
	for r in [uset, buf_in, buf_out, pipeline, shader]:
		if r.is_valid(): rd.free_rid(r)
	rd.free()
	rd = null
	ready = false
