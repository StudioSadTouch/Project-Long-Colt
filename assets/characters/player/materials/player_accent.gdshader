// Long Colt player team accent (left pauldron + left helmet stripe). Shared material
// (player_accent.tres, never duplicated); PlayerModel.set_accent_color() writes the
// accent_color instance uniform per MeshInstance3D, so each player can carry its own team colour.
shader_type spatial;

// Default: stencil red #b3261e.
instance uniform vec3 accent_color : source_color = vec3(0.701961, 0.149020, 0.117647);

uniform float roughness : hint_range(0.0, 1.0) = 0.9;

void fragment() {
	ALBEDO = accent_color;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
}
