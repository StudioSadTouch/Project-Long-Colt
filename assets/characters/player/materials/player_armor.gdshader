// Long Colt player armor (primary, tintable). Contract agreed with LC Programmer:
//   instance uniform primary_color, set per MeshInstance3D by PlayerModel.set_primary_color().
// The material resource (player_armor_primary.tres) stays SHARED and is never duplicated.
// tint_mask (R channel) is optional: white = fully tinted. A future textured model can paint
// untinted areas black and supply albedo_texture; the block-out uses neither (flat colour).
shader_type spatial;

// Default: field olive #4a5039 (board section 7, "Field olive / armour plate").
instance uniform vec3 primary_color : source_color = vec3(0.290196, 0.313725, 0.223529);

uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap;
uniform sampler2D tint_mask : hint_default_white, filter_linear_mipmap;
uniform float roughness : hint_range(0.0, 1.0) = 0.9;

void fragment() {
	vec3 base = texture(albedo_texture, UV).rgb;
	float mask = texture(tint_mask, UV).r;
	ALBEDO = base * mix(vec3(1.0), primary_color, mask);
	ROUGHNESS = roughness;
	METALLIC = 0.0;
}
