// Long Colt player armor (primary, tintable) with triplanar micro-texture support.
shader_type spatial;

instance uniform vec3 primary_color : source_color = vec3(0.290196, 0.313725, 0.223529);

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform float roughness : hint_range(0.0, 1.0) = 0.8;
uniform float metallic : hint_range(0.0, 1.0) = 0.2;
uniform float uv_scale = 3.5;
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

	// The texture is detail, not colour: its luminance relative to its own average (the 1x1
	// mip) brightens or darkens the tint around 1.0, so the armor shows the chosen colour at
	// its real brightness. Multiplying the raw texture (mean linear luminance ~0.03) made every
	// tint near-black and pulled it toward the texture's slate blue.
	float mean_lum = max(dot(textureLod(albedo_texture, vec2(0.5), 16.0).rgb, LUMA), 0.001);
	float detail = clamp(dot(base, LUMA) / mean_lum, 0.0, 1.5);
	ALBEDO = primary_color * mix(1.0, detail, detail_strength);
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
