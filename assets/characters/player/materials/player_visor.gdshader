// Long Colt player visor with triplanar metallic detail.
shader_type spatial;

instance uniform vec3 visor_color : source_color = vec3(0.658824, 0.478431, 0.117647);

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform float roughness : hint_range(0.0, 1.0) = 0.3;
uniform float metallic : hint_range(0.0, 1.0) = 0.85;
uniform float uv_scale = 6.0;

varying vec3 model_pos;
varying vec3 model_normal;

void vertex() {
	model_pos = VERTEX;
	model_normal = abs(NORMAL);
}

void fragment() {
	vec3 blend = pow(model_normal, vec3(4.0));
	blend /= max(0.0001, blend.x + blend.y + blend.z);

	vec3 col_x = texture(albedo_texture, model_pos.zy * uv_scale).rgb;
	vec3 col_y = texture(albedo_texture, model_pos.xz * uv_scale).rgb;
	vec3 col_z = texture(albedo_texture, model_pos.xy * uv_scale).rgb;
	vec3 base = col_x * blend.x + col_y * blend.y + col_z * blend.z;

	ALBEDO = base * visor_color * 1.5;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	EMISSION = visor_color * 0.15;
}
