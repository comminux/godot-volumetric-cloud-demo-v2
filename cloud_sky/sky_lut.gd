@tool
class_name SkyLut
extends Texture2DRD

var texture_size: Vector2i = Vector2i(200, 100)
var light_direction: Vector3 = Vector3(0.0, -1.0, 0.0)
var needs_update: bool = true
var initialized: bool = false
var back_texture: Array = [Texture2DRD.new(), Texture2DRD.new()]
var needs_full_update: bool = true
var rd: RenderingDevice
var shader: RID
var pipeline: RID
# We need three copies so we can synchronize with the clouds
var texture_rd: Array = [RID(), RID(), RID()]
var texture_set: Array = [RID(), RID(), RID()]
var current_texture: int = 0
var lut_set: RID
var sampler: RID
var script_path: String = get_script().resource_path
var script_dir: String = script_path.get_base_dir()
var transmittance_tex: TransmittanceLut = load(script_dir + "/transmittance_lut.tres")
var uniform_set_rid: RID
var _push_back: bool


func _init() -> void:
	rd = RenderingServer.get_rendering_device()
	RenderingServer.call_on_render_thread(_initialize_texture)
	RenderingServer.call_on_render_thread.call_deferred(_initialize_compute_code)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if not rd:
			print_debug("[sky_lut] Error: 'rd' (Rendering Device) is null!")
			return

		if is_instance_valid(self):
			RenderingServer.call_on_render_thread(Callable(_free_rids_on_render_thread))


func request_update() -> void:
	needs_update = true


# This should be called once to update the entire sky.
func update_lut(sun_direction: Vector3) -> void:
	light_direction = sun_direction
	if not initialized:
		print("Attempting to update uninitialized sky lut")
		return
	RenderingServer.call_on_render_thread(render_lut)
	if needs_full_update:
		RenderingServer.call_on_render_thread(render_lut)
		RenderingServer.call_on_render_thread(render_lut)
		needs_full_update = false


func render_lut() -> void:
	var push_constant: PackedFloat32Array = PackedFloat32Array()
	_push_back = push_constant.push_back(texture_size.x)
	_push_back = push_constant.push_back(texture_size.y)
	_push_back = push_constant.push_back(0.0)
	_push_back = push_constant.push_back(0.0)

	_push_back = push_constant.push_back(light_direction.x)
	_push_back = push_constant.push_back(light_direction.y)
	_push_back = push_constant.push_back(light_direction.z)
	_push_back = push_constant.push_back(0.0)

	# Run our compute shader.
	var compute_list: int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_set_push_constant(
		compute_list,
		push_constant.to_byte_array(),
		push_constant.size() * 4,
	)
	uniform_set_rid = texture_set[current_texture]
	rd.compute_list_bind_uniform_set(compute_list, uniform_set_rid, 0)
	rd.compute_list_bind_uniform_set(compute_list, lut_set, 1)
	rd.compute_list_dispatch(compute_list, 25, 13, 1)
	rd.compute_list_end()

	texture_rd_rid = texture_rd[current_texture]
	current_texture = (current_texture + 1) % 3
	back_texture[0].texture_rd_rid = texture_rd[current_texture]
	back_texture[1].texture_rd_rid = texture_rd[(current_texture + 1) % 3]

	needs_update = false


func _free_rids_on_render_thread() -> void:
	var texture_rid: RID
	for i: int in range(3):
		texture_rid = texture_rd[i]
		if texture_rid and rd.texture_is_valid(texture_rid):
			rd.free_rid(texture_rid)
	if shader and shader.is_valid():
		rd.free_rid(shader)
	if sampler and sampler.is_valid():
		rd.free_rid(sampler)


func _create_uniform_set(p_texture_rd: RID) -> RID:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(p_texture_rd)
	return rd.uniform_set_create([uniform], shader, 0)


func _create_uniform_set_for_sampling() -> RID:
	var sampler_state: RDSamplerState = RDSamplerState.new()
	var texture_rid: RID
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR

	sampler = rd.sampler_create(sampler_state)

	var uniforms: Array = []
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = 0
	uniform.add_id(sampler)
	texture_rid = transmittance_tex.texture_rd
	uniform.add_id(texture_rid)
	uniforms.push_back(uniform)

	return rd.uniform_set_create(uniforms, shader, 1)


func _initialize_texture() -> void:
	var tf: RDTextureFormat = RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = texture_size.x
	tf.height = texture_size.y
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT + \
			RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT + \
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + \
			RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + \
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	if Engine.is_editor_hint():
		tf.usage_bits += RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

	# Create our textures
	texture_rd[0] = rd.texture_create(tf, RDTextureView.new(), [])
	texture_rd[1] = rd.texture_create(tf, RDTextureView.new(), [])
	texture_rd[2] = rd.texture_create(tf, RDTextureView.new(), [])


func _initialize_compute_code() -> void:
	# Create our shader
	var shader_file: RDShaderFile = load(script_dir + "/sky-lut.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	if not shader.is_valid():
		print("you got an invalid shader buddy")
		return
	pipeline = rd.compute_pipeline_create(shader)

	var texture_rid: RID
	# Now create our uniform set so we can use these textures in our shader
	for i: int in range(3):
		texture_rid = texture_rd[i]
		texture_set[i] = _create_uniform_set(texture_rid)
	lut_set = _create_uniform_set_for_sampling()

	texture_rd_rid = texture_rd[0]
	back_texture[0].texture_rd_rid = texture_rd[1]
	back_texture[1].texture_rd_rid = texture_rd[2]

	initialized = true
