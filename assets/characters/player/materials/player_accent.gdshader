// Long Colt player team accent with triplanar detail support.
shader_type spatial;

instance uniform vec3 accent_color : source_color = vec3(0.701961, 0.149020, 0.117647);

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform float roughness : hint_range(0.0, 1.0) = 0.8;
uniform float metallic : hint_range(0.0, 1.0) = 0.1;
uniform float uv_scale = 4.0;
// How much the texture's light/dark detail shows over the tint (0 = flat tint).
uniform float detail_strength : hint_range(0.0, 1.0) = 0.6;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

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

	// Texture luminance around its own average modulates the tint (see player_armor.gdshader);
	// the raw multiply made team accents near-black.
	float mean_lum = max(dot(textureLod(albedo_texture, vec2(0.5), 16.0).rgb, LUMA), 0.001);
	float detail = clamp(dot(base, LUMA) / mean_lum, 0.0, 1.5);
	ALBEDO = accent_color * mix(1.0, detail, detail_strength);
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
