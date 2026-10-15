// Lockout sky: cold high-altitude gradient, sun disk, a procedural snow-capped alien
// mountain ring on the horizon, a banded gas giant and a small moon.
// Original procedural shader written for Project Long Colt (no third-party code or textures).
// Static (no TIME), so the radiance cubemap only updates when the sun moves.
shader_type sky;

group_uniforms Sky;
uniform vec3 zenith_color : source_color = vec3(0.075, 0.13, 0.24);     // deep thin-air blue
uniform vec3 upper_color : source_color = vec3(0.22, 0.33, 0.47);
uniform vec3 horizon_color : source_color = vec3(0.66, 0.73, 0.80);     // ~#a9b8c4 (board frozen blue-grey)
uniform vec3 ground_color : source_color = vec3(0.16, 0.18, 0.21);
uniform float sky_energy : hint_range(0.0, 4.0) = 1.0;
uniform float sun_glow : hint_range(0.0, 2.0) = 0.35;
uniform float sun_disk_size : hint_range(0.0, 0.1) = 0.012;  // radians; used when the light's angular size is 0

group_uniforms Mountains;
uniform vec3 far_rock : source_color = vec3(0.36, 0.42, 0.49);         // ~#6e8191 darkened
uniform vec3 near_rock : source_color = vec3(0.15, 0.17, 0.20);
uniform vec3 snow_color : source_color = vec3(0.875, 0.902, 0.918);     // #dfe6ea
uniform float far_height : hint_range(0.0, 0.5) = 0.2;
uniform float near_height : hint_range(0.0, 0.5) = 0.11;
uniform float haze : hint_range(0.0, 1.0) = 0.3;

group_uniforms Bodies;
uniform vec3 planet_direction = vec3(0.40, 0.375, -0.836);  // NE sky, ~22 deg up (-Z is north)
uniform float planet_radius : hint_range(0.0, 0.5) = 0.13;  // radians
uniform vec3 planet_color_a : source_color = vec3(0.76, 0.70, 0.60);
uniform vec3 planet_color_b : source_color = vec3(0.55, 0.45, 0.36);
uniform vec3 moon_direction = vec3(-0.78, 0.47, -0.42);
uniform float moon_radius : hint_range(0.0, 0.2) = 0.022;
uniform vec3 moon_color : source_color = vec3(0.62, 0.62, 0.60);
group_uniforms;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float ridge_fbm(vec2 p) {
	float amp = 0.5;
	float sum = 0.0;
	for (int k = 0; k < 5; k++) {
		float n = 1.0 - abs(value_noise(p) * 2.0 - 1.0);
		sum += amp * n * n;
		p = p * 2.03 + vec2(1.7, 9.2);
		amp *= 0.5;
	}
	return sum;
}

// Ridge height (sine of elevation) for an azimuth; sampled on a circle so there is no seam.
float ridge_height(float az, float freq, vec2 seed, float base, float height) {
	vec2 c = vec2(cos(az), sin(az)) * freq + seed;
	return height * (base + (1.0 - base) * pow(clamp(ridge_fbm(c) * 1.5, 0.0, 1.5), 1.35));
}

// Lit sphere seen from inside the sky. Returns rgb + coverage.
vec4 sky_body(vec3 eye, vec3 dir, float radius, vec3 col_a, vec3 col_b, float bands, vec3 sun_dir) {
	vec3 d = normalize(dir);
	float ang = acos(clamp(dot(eye, d), -1.0, 1.0));
	if (ang > radius * 1.04) {
		return vec4(0.0);
	}
	vec3 t = normalize(cross(d, vec3(0.0, 1.0, 0.0)));
	vec3 b = cross(t, d);
	vec2 uv = vec2(dot(eye, t), dot(eye, b)) / sin(radius);
	float r2 = dot(uv, uv);
	vec3 n = t * uv.x + b * uv.y - d * sqrt(max(1.0 - r2, 0.0));
	float lit = smoothstep(-0.05, 0.25, dot(n, sun_dir));
	float pattern;
	if (bands > 0.5) {
		pattern = 0.5 + 0.5 * sin((uv.y + 0.18 * uv.x) * 17.0 + value_noise(uv * 5.0) * 2.5);
	} else {
		pattern = value_noise(uv * 7.0) * 0.6 + value_noise(uv * 19.0) * 0.4;
	}
	vec3 albedo = mix(col_b, col_a, pattern);
	float rim = pow(clamp(sqrt(r2), 0.0, 1.0), 6.0);
	vec3 rgb = albedo * (0.08 + 0.92 * lit) + vec3(0.55, 0.65, 0.8) * rim * 0.25 * lit;
	float cover = 1.0 - smoothstep(0.96, 1.0, sqrt(r2));
	return vec4(rgb, cover);
}

void sky() {
	vec3 eye = normalize(EYEDIR);
	float e = eye.y;
	vec3 sun_dir = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION) : vec3(0.0, 1.0, 0.0);

	// Gradient: horizon band -> upper sky -> zenith.
	vec3 col = mix(horizon_color, upper_color, smoothstep(0.0, 0.25, e));
	col = mix(col, zenith_color, smoothstep(0.25, 0.9, e));
	if (e < 0.0) {
		col = mix(horizon_color, ground_color, smoothstep(0.0, -0.3, e));
	}

	// Sun disk and a tight glare; high altitude keeps the halo small.
	if (LIGHT0_ENABLED) {
		float sd = distance(eye, sun_dir);
		float disk_r = max(LIGHT0_SIZE, sun_disk_size);
		float disk = 1.0 - smoothstep(disk_r * 0.9, disk_r * 1.1, sd);
		col += LIGHT0_COLOR * LIGHT0_ENERGY * disk * 8.0;
		col += LIGHT0_COLOR * pow(max(dot(eye, sun_dir), 0.0), 48.0) * sun_glow;
	}

	// Bodies sit behind the mountains, in front of the sky.
	vec4 planet = sky_body(eye, planet_direction, planet_radius, planet_color_a, planet_color_b, 1.0, sun_dir);
	float body_haze = smoothstep(0.0, 0.3, e);
	col = mix(col, mix(col, planet.rgb, 0.85 * body_haze + 0.15), planet.a);
	vec4 moon = sky_body(eye, moon_direction, moon_radius, moon_color, moon_color * 0.6, 0.0, sun_dir);
	col = mix(col, moon.rgb, moon.a * body_haze);

	// Mountain ring: a hazy far range and a darker near range, snow above a ragged line.
	float az = atan(eye.x, eye.z);
	vec2 sun_flat = normalize(vec2(sun_dir.x, sun_dir.z) + vec2(1e-4, 0.0));
	float eps = 0.004;
	float hf = ridge_height(az, 4.0, vec2(7.3, 1.1), 0.12, far_height);
	float hn = ridge_height(az, 7.0, vec2(-3.1, 4.7), 0.08, near_height);
	if (e < hf && e > -0.35) {
		float slope = (ridge_height(az + eps, 4.0, vec2(7.3, 1.1), 0.12, far_height) - ridge_height(az - eps, 4.0, vec2(7.3, 1.1), 0.12, far_height)) / (2.0 * eps);
		float face = dot(normalize(vec2(-slope * cos(az) + sin(az), slope * sin(az) + cos(az))), sun_flat);
		float snow_line = hf * (0.62 + 0.2 * value_noise(vec2(az * 30.0, e * 30.0)));
		vec3 rock = mix(far_rock, snow_color, smoothstep(snow_line - 0.01, snow_line + 0.01, e));
		rock *= 0.75 + 0.35 * clamp(face, -1.0, 1.0);
		col = mix(rock, horizon_color, haze);
	}
	if (e < hn && e > -0.35) {
		float snow_line = hn * (0.6 + 0.25 * value_noise(vec2(az * 45.0, e * 45.0)));
		vec3 rock = mix(near_rock, snow_color * 0.9, smoothstep(snow_line - 0.008, snow_line + 0.008, e));
		col = mix(rock, horizon_color, haze * 0.45);
	}
	// Valley haze below the ranges.
	col = mix(col, horizon_color * 0.8, smoothstep(-0.05, -0.35, e) * 0.6);

	COLOR = col * sky_energy;
}
