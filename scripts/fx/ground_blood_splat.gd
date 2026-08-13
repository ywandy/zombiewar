extends MeshInstance3D
class_name GroundBloodSplat

## 所有地面血迹共享同一份程序化材质。每实例颜色与扩散半径使用 instance uniform，
## 避免尸潮命中时为每片血迹复制材质或重新编译 shader。
const SPLAT_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled;

instance uniform vec4 center_tint : source_color = vec4(0.42, 0.005, 0.01, 0.96);
instance uniform vec4 edge_tint : source_color = vec4(0.58, 0.012, 0.018, 0.26);
instance uniform float reveal_radius = 1.08;

void fragment() {
	vec2 centered_uv = (UV - vec2(0.5)) * 2.0;
	float radius = length(centered_uv);
	float center_weight = 1.0 - smoothstep(0.0, 0.88, radius);
	float outer_fade = 1.0 - smoothstep(0.55, 1.0, radius);
	float reveal_fade = 1.0 - smoothstep(
		max(reveal_radius - 0.08, 0.0),
		max(reveal_radius, 0.001),
		radius
	);
	vec4 blood = mix(edge_tint, center_tint, center_weight);
	ALBEDO = blood.rgb;
	ALPHA = blood.a * outer_fade * reveal_fade;
}
"""

const MIN_REVEAL_RADIUS := 0.08
const MAX_REVEAL_RADIUS := 1.08

static var _shared_shader: Shader
static var _shared_material: ShaderMaterial

@export var surface_offset := 0.012

var base_size := Vector2.ONE
var current_size := Vector2.ONE
var current_tint := Color.WHITE
var current_edge_tint := Color(0.58, 0.012, 0.018, 0.26)
var current_surface_normal := Vector3.UP
var current_rotation := 0.0
var expansion_duration := 0.30
var expansion_elapsed := 0.0
var expansion_progress := 1.0

static func _get_shader() -> Shader:
	if _shared_shader == null:
		_shared_shader = Shader.new()
		_shared_shader.code = SPLAT_SHADER_CODE
	return _shared_shader

static func _get_shared_material() -> ShaderMaterial:
	if _shared_material == null:
		_shared_material = ShaderMaterial.new()
		_shared_material.shader = _get_shader()
	return _shared_material

static func surface_basis(
	surface_normal: Vector3,
	random_rotation: float
) -> Basis:
	var normal := surface_normal.normalized()
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	var reference := Vector3.RIGHT
	if absf(reference.dot(normal)) > 0.95:
		reference = Vector3.FORWARD
	var local_y := normal.cross(reference).normalized()
	var local_x := local_y.cross(normal).normalized()
	return Basis(local_x, local_y, normal).rotated(normal, random_rotation)

func setup(
	surface_position: Vector3,
	surface_normal: Vector3,
	size: Vector2,
	rotation_radians: float,
	center_tint: Color,
	edge_tint: Color,
	duration_seconds: float = 0.30
) -> void:
	var normal := surface_normal.normalized()
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	base_size = Vector2(maxf(size.x, 0.05), maxf(size.y, 0.05))
	current_size = base_size
	current_tint = center_tint
	current_edge_tint = edge_tint
	current_surface_normal = normal
	current_rotation = rotation_radians
	var resolved_position := surface_position + normal * surface_offset
	if is_inside_tree():
		global_position = resolved_position
	else:
		position = resolved_position
	_apply_size_basis()
	material_override = _get_shared_material()
	set_instance_shader_parameter("center_tint", current_tint)
	set_instance_shader_parameter("edge_tint", current_edge_tint)
	retrigger_expansion(duration_seconds)

func retrigger_expansion(duration_seconds: float = 0.30) -> void:
	expansion_duration = maxf(duration_seconds, 0.001)
	expansion_elapsed = 0.0
	expansion_progress = 0.0
	set_instance_shader_parameter("reveal_radius", MIN_REVEAL_RADIUS)
	visible = true
	set_process(true)

func _process(delta: float) -> void:
	expansion_elapsed = minf(
		expansion_elapsed + maxf(delta, 0.0),
		expansion_duration
	)
	expansion_progress = clampf(
		expansion_elapsed / maxf(expansion_duration, 0.001),
		0.0,
		1.0
	)
	var eased := 1.0 - pow(1.0 - expansion_progress, 3.0)
	set_instance_shader_parameter(
		"reveal_radius",
		lerpf(MIN_REVEAL_RADIUS, MAX_REVEAL_RADIUS, eased)
	)
	if expansion_progress >= 1.0:
		set_process(false)

func merge_limited(size_growth: float, darken_amount: float) -> void:
	var maximum_size := base_size * clampf(size_growth, 1.0, 1.15)
	current_size = Vector2(
		minf(current_size.x * 1.03, maximum_size.x),
		minf(current_size.y * 1.03, maximum_size.y)
	)
	current_tint = Color(
		maxf(current_tint.r - maxf(darken_amount, 0.0), 0.24),
		maxf(current_tint.g - maxf(darken_amount, 0.0) * 0.08, 0.002),
		maxf(current_tint.b - maxf(darken_amount, 0.0) * 0.08, 0.006),
		minf(current_tint.a + 0.02, 0.98)
	)
	current_edge_tint = Color(
		maxf(current_edge_tint.r - darken_amount * 0.4, 0.32),
		maxf(current_edge_tint.g - darken_amount * 0.04, 0.002),
		maxf(current_edge_tint.b - darken_amount * 0.04, 0.006),
		minf(current_edge_tint.a + 0.025, 0.42)
	)
	_apply_size_basis()
	set_instance_shader_parameter("center_tint", current_tint)
	set_instance_shader_parameter("edge_tint", current_edge_tint)

func warmup_for_render(context: FxWarmupContext) -> void:
	setup(
		context.position_in_view(3.5, Vector2(0.3, -0.3)),
		-context.forward_direction(),
		Vector2.ONE * 1.8,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)

func finish_render_warmup() -> void:
	visible = false
	set_process(false)

func _apply_size_basis() -> void:
	var resolved_basis := surface_basis(
		current_surface_normal,
		current_rotation
	).scaled(Vector3(current_size.x, current_size.y, 1.0))
	if is_inside_tree():
		global_basis = resolved_basis
	else:
		basis = resolved_basis
