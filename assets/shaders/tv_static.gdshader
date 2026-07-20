shader_type canvas_item;
// Full-screen analogue snow used between the escape film and the credits.
// Quantising UV and TIME keeps the pattern sharp and television-like.

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = UV;
	float frame = floor(TIME * 29.97);
	vec2 pixels = floor(uv * vec2(720.0, 480.0));
	float coarse = hash21(pixels + vec2(frame * 17.0, frame * 41.0));
	float fine = hash21(pixels * 1.91 + vec2(frame * 73.0, frame * 11.0));
	float snow = clamp(coarse * 0.78 + fine * 0.38, 0.0, 1.0);

	float scanline = sin(uv.y * 960.0 + TIME * 24.0) * 0.06;
	float tear_y = fract(hash21(vec2(frame, 8.0)) + TIME * 0.13);
	float tear = smoothstep(0.026, 0.0, abs(uv.y - tear_y));
	snow = mix(snow, hash21(vec2(pixels.y, frame)) * 0.9, tear * 0.75);

	float vignette = 1.0 - smoothstep(0.28, 0.74, distance(uv, vec2(0.5))) * 0.55;
	float value = clamp((snow - scanline) * vignette, 0.0, 1.0);
	COLOR = vec4(vec3(value), 1.0);
}
