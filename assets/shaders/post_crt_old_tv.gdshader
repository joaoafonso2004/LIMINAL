// post_crt_old_tv.gdshader — LIMINAL
// Purpose: fullscreen old-TV/CRT post filter. Samples the rendered frame and
//   replays it through a dying set: barrel curvature, chromatic aberration,
//   scanlines + interlace, TV snow, VHS tracking tears, rolling band, vignette.
// Driven by: `dread` (0..1, long-term fear level) and `pulse` (0..1, transient
//   glitch spike on jumpscares) — set from scripts/ui/overlay.gd.
// Pipeline: Compatibility (WebGL 2). Budget: 3 screen samples/px, no loops.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float dread : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;

// Look constants (documented in docs/design/game-design.md).
// Grade target: dark A24-still — heavy red/cyan fringing, crushed brown-black
// shadows, drained sepia colour.
const float CURVATURE = 0.11;          // barrel distortion strength
const float ABERRATION_BASE = 0.0022;  // RGB split at rest, in UV units
const float SCANLINE_BASE = 0.13;      // scanline darkening at rest
const float SNOW_BASE = 0.06;          // TV snow amount at rest
const float SHADOW_GAMMA = 1.14;       // >1 crushes shadows toward black
const vec3 PHOSPHOR_TINT = vec3(1.06, 0.97, 0.8); // dirty sepia push

// Cheap deterministic hash -> [0,1)
float hash21(vec2 p) {
	p = fract(p * vec2(233.34, 851.73));
	p += dot(p, p + 34.45);
	return fract(p.x * p.y);
}

// Subtle CRT barrel distortion.
vec2 curve(vec2 uv) {
	vec2 c = uv - 0.5;
	float r2 = dot(c, c);
	return uv + c * r2 * CURVATURE;
}

void fragment() {
	vec2 uv = curve(SCREEN_UV);

	// --- VHS tracking tear: a thin band that yanks rows sideways sometimes ---
	float band_seed = floor(TIME * 2.0);
	float band_on = step(0.86 - dread * 0.2 - pulse * 0.55, hash21(vec2(band_seed, 7.0)));
	float band_y = fract(hash21(vec2(band_seed, 3.0)) + TIME * 0.07);
	float band = smoothstep(0.014, 0.0, abs(uv.y - band_y)) * band_on;
	uv.x += band * (hash21(vec2(TIME * 60.0, uv.y * 240.0)) - 0.5) * 0.09;

	// --- Chromatic aberration: worse as the signal sickens ---
	float ab = ABERRATION_BASE + dread * 0.0026 + pulse * 0.004;
	float r = texture(screen_tex, uv + vec2(ab, 0.0)).r;
	float g = texture(screen_tex, uv).g;
	float b = texture(screen_tex, uv - vec2(ab, 0.0)).b;
	vec3 col = vec3(r, g, b);

	// --- Drained colour, pushed toward dirty sepia; shadows crushed black ---
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(lum), 0.32 + dread * 0.18);
	col *= PHOSPHOR_TINT;
	col = pow(max(col, vec3(0.0)), vec3(SHADOW_GAMMA));

	// --- Scanlines + interlace shimmer ---
	float sl = sin(uv.y * 900.0 + TIME * 6.0) * 0.5 + 0.5;
	col *= 1.0 - sl * (SCANLINE_BASE + dread * 0.07);
	float interlace = step(0.5, fract(uv.y * 240.0 + floor(TIME * 30.0) * 0.5));
	col *= 1.0 - interlace * 0.03;

	// --- Slow rolling brightness band ---
	float roll = smoothstep(0.0, 0.35, abs(fract(uv.y * 0.7 - TIME * 0.04) - 0.5));
	col *= 0.95 + roll * 0.07;

	// --- TV snow: constant, thicker when something is wrong ---
	float n = hash21(uv * vec2(640.0, 360.0) + fract(TIME) * 91.7);
	col += (n - 0.5) * (SNOW_BASE + dread * 0.1 + pulse * 0.12 + band * 0.5);

	// --- Vignette + curved-glass border (heavy — the corners belong to it) ---
	float d = distance(uv, vec2(0.5));
	col *= 1.0 - smoothstep(0.28, 0.75, d) * (0.6 + dread * 0.28 + pulse * 0.3);
	vec2 edge = abs(uv - 0.5);
	col *= smoothstep(0.5, 0.487, max(edge.x, edge.y));

	// --- Faint phosphor breathing ---
	col *= 0.98 + 0.02 * sin(TIME * 1.7);

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
