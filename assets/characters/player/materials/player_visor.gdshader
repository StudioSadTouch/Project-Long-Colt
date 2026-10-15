// Long Colt player visor (tintable). Same contract as player_armor.gdshader:
//   instance uniform visor_color, set per MeshInstance3D by PlayerModel.set_visor_color().
// The material resource (player_visor.tres) stays SHARED and is never duplicated.
shader_type spatial;

// Default: amber gold #a87a1e (the block-out's mat_visor albedo).
instance uniform vec3 visor_color : source_color = vec3(0.658824, 0.478431, 0.117647);

uniform float roughness : hint_range(0.0, 1.0) = 0.9;

void fragment() {
	ALBEDO = visor_color;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
}
