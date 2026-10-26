// Long Colt player visor: a flat tinted shell. The Hospitaller's visor is the helmet's whole
// front dome; through the old triplanar texture path those big facets blew out into white
// glare (bloom), so the tint is applied straight.
shader_type spatial;

// Own instance_index: a mesh can mix armor, accent and visor surfaces, and instance
// uniforms of different shaders on one instance share slot 0 unless told apart.
instance uniform vec3 visor_color : source_color, instance_index(2) = vec3(0.658824, 0.478431, 0.117647);

uniform float roughness : hint_range(0.0, 1.0) = 0.35;
uniform float metallic : hint_range(0.0, 1.0) = 0.3;
// How dark the visor reads against its tint (1 = the tint itself).
uniform float tint_strength : hint_range(0.0, 1.0) = 0.75;

void fragment() {
	ALBEDO = visor_color * tint_strength;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
