class_name NewOttomanSounds
extends RefCounted
## Gritty, grounded sound cues for the New Ottoman faction.
## Replaces all cartoonish synth beeps, boops, laser sweeps, and electronic buzzes
## with heavy, visceral, militaristic acoustic cues:
##   horn_advance   the Bolukbasi's brass war horn: deep guttural rising call
##   horn_withdraw  the Bolukbasi's brass war horn: solemn falling baritone call
##   cymbal         heavy Turkish Zil bronze war crash on a Corbaci's break order
##   glint          an Akinji marksman's optical acquisition & mechanical shutter latch
##   hum            the yatagan / kilij vibro-blade: menacing industrial motor & blade flutter
##   ricochet       ballistic kinetic deflection crack & heavy armor plate ring
##   vent           high-pressure hydraulic steam hiss when Janissary armor breaks (EXPOSED)
##   spall          heavy ballistic plate fracture when pauldrons/plates break off
##   humbara_fire   heavy pneumatic concussive mortar lob

const CUE_ASSETS := {
	&"horn_advance": "res://assets/audio/enemies/new_ottoman/horn_advance.wav",
	&"horn_withdraw": "res://assets/audio/enemies/new_ottoman/horn_withdraw.wav",
	&"cymbal": "res://assets/audio/enemies/new_ottoman/cymbal.wav",
	&"glint": "res://assets/audio/enemies/new_ottoman/glint.wav",
	&"hum": "res://assets/audio/enemies/new_ottoman/hum.wav",
	&"ricochet": "res://assets/audio/enemies/new_ottoman/ricochet.wav",
	&"vent": "res://assets/audio/enemies/new_ottoman/hydraulic_vent.wav",
	&"spall": "res://assets/audio/enemies/new_ottoman/armor_spall.wav",
	&"humbara_fire": "res://assets/audio/enemies/new_ottoman/humbara_fire.wav",
}

const RATE := 22050

static var _cache: Dictionary = {}


static func get_stream(cue: StringName) -> AudioStreamWAV:
	if _cache.has(cue):
		return _cache[cue]
	var stream: AudioStreamWAV = null
	if CUE_ASSETS.has(cue):
		var path: String = CUE_ASSETS[cue]
		if ResourceLoader.exists(path):
			stream = load(path) as AudioStreamWAV
	if stream == null:
		stream = _synthesize_fallback(cue)
	if stream != null and cue == &"hum":
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = stream.data.size() / 2
	_cache[cue] = stream
	return stream


static func _synthesize_fallback(cue: StringName) -> AudioStreamWAV:
	match cue:
		&"horn_advance":
			return _horn(true)
		&"horn_withdraw":
			return _horn(false)
		&"cymbal":
			return _cymbal()
		&"glint":
			return _glint()
		&"hum":
			return _hum()
		&"ricochet":
			return _ricochet()
		&"vent":
			return _vent()
		&"spall":
			return _spall()
		&"humbara_fire":
			return _humbara_fire()
		_:
			push_warning("NewOttomanSounds: unknown cue %s" % cue)
			return _to_stream(PackedFloat32Array([0.0]))


## Deep guttural Ottoman brass war horn: rich harmonics with brass bell formant and breath grit.
static func _horn(rising: bool) -> AudioStreamWAV:
	var notes := [146.8, 174.6, 220.0] if rising else [220.0, 174.6, 146.8]
	var note_len := 0.35
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * note_len * notes.size() + RATE * 0.4))
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for n in notes.size():
		var start := int(n * note_len * RATE)
		var last := n == notes.size() - 1
		var dur := note_len + (0.35 if last else 0.05)
		for i in int(dur * RATE):
			var t := float(i) / RATE
			var env := minf(t / 0.045, 1.0) * minf((dur - t) / 0.1, 1.0)
			var f: float = notes[n] * (1.0 - 0.03 * exp(-t * 25.0))
			var tone := 0.0
			for k in range(1, 9):
				var h_freq := f * k
				var formant := exp(-0.5 * pow((h_freq - 900.0) / 350.0, 2.0)) * 1.4
				var gain: float = (1.0 / pow(k, 0.9)) * (1.0 + formant)
				tone += sin(TAU * h_freq * t) * gain
			var breath := rng.randf_range(-0.15, 0.15) * sin(TAU * f * t)
			var raw := (tone + breath) * env * 0.35
			# Soft clipping for brass rasp
			samples[start + i] += tanh(raw * 1.5) * 0.4
	return _to_stream(samples)


## Turkish Zil heavy bronze clash with modal resonance.
static func _cymbal() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * 1.5))
	var rng := RandomNumberGenerator.new()
	rng.seed = 88
	var modes := [380.0, 540.0, 760.0, 1080.0, 1450.0, 1980.0, 2620.0, 3750.0]
	var decay_rates := [2.0, 2.4, 3.0, 3.5, 4.0, 4.8, 5.5, 6.5]
	var prev_noise := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var tone := 0.0
		for m in modes.size():
			tone += sin(TAU * modes[m] * t) * exp(-t * decay_rates[m]) * 0.15
		var noise := rng.randf_range(-1.0, 1.0)
		var shimmer := (noise - prev_noise) * exp(-t * 3.8) * 0.35
		prev_noise = noise
		var punch := sin(TAU * 140.0 * exp(-t * 30.0) * t) * exp(-t * 22.0) * 0.3
		samples[i] = tanh((tone + shimmer + punch) * 1.3) * 0.55
	return _to_stream(samples)


## Grounded military sniper scope aperture click & mechanical shutter lock. NO BEEP.
static func _glint() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * 0.3))
	var rng := RandomNumberGenerator.new()
	rng.seed = 101
	for i in samples.size():
		var t := float(i) / RATE
		# First click
		var click1 := sin(TAU * 1800.0 * t) * exp(-t * 120.0) * 0.4 + rng.randf_range(-0.4, 0.4) * exp(-t * 90.0)
		# Second aperture latch at 38ms
		var click2 := 0.0
		if t > 0.038:
			var t2 := t - 0.038
			click2 = sin(TAU * 2400.0 * t2) * exp(-t2 * 140.0) * 0.45 + rng.randf_range(-0.5, 0.5) * exp(-t2 * 110.0)
		# Low mechanical body thump
		var thump := sin(TAU * 180.0 * exp(-t * 35.0) * t) * exp(-t * 30.0) * 0.25
		# Subtle crystal lens ring (not a beep, quiet high-Q glass tap)
		var ping := sin(TAU * 3400.0 * t) * exp(-t * 25.0) * 0.12
		samples[i] = tanh((click1 + click2 + thump + ping) * 1.2) * 0.55
	return _to_stream(samples)


## Industrial vibro-blade loop with sub-bass motor rumble & 36Hz blade flutter.
static func _hum() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * 0.5))
	var f0 := 52.0
	for i in samples.size():
		var t := float(i) / RATE
		var motor := (sin(TAU * f0 * t) * 0.5 + sin(TAU * 2.0 * f0 * t) * 0.35 + sin(TAU * 3.0 * f0 * t) * 0.2)
		var flutter := (0.6 + 0.4 * sin(TAU * 36.0 * t)) * sin(TAU * 416.0 * t) * 0.35
		var edge := sin(TAU * 3328.0 * t) * 0.08
		var raw := motor + flutter + edge
		samples[i] = tanh(raw * 1.5) * 0.4
	return _to_stream(samples, true)


## Ballistic kinetic steel plate deflection crack & heavy armor thud. NO CARTOON LASER PEW.
static func _ricochet() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * 0.32))
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for i in samples.size():
		var t := float(i) / RATE
		# Hypersonic impact snap (1.5ms transient)
		var snap := rng.randf_range(-1.0, 1.0) * exp(-t * 220.0) * 0.6
		# Heavy plate body punch (160 Hz thump)
		var punch := sin(TAU * 160.0 * exp(-t * 35.0) * t) * exp(-t * 22.0) * 0.45
		# Metallic modal ring
		var ring := (sin(TAU * 2250.0 * t) * 0.3 + sin(TAU * 3680.0 * t) * 0.25) * exp(-t * 30.0)
		samples[i] = tanh((snap + punch + ring) * 1.4) * 0.6
	return _to_stream(samples)


## High-pressure pneumatic steam hiss & relief valve release for Janissary armor break.
static func _vent() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * 0.75))
	var rng := RandomNumberGenerator.new()
	rng.seed = 55
	var prev := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var valve_click := rng.randf_range(-0.8, 0.8) * exp(-t * 120.0)
		var noise := rng.randf_range(-1.0, 1.0)
		var hiss := (noise - 0.6 * prev) * (exp(-t * 3.5) - exp(-t * 35.0)) * 0.5
		prev = noise
		var rumble := sin(TAU * 95.0 * t) * exp(-t * 4.0) * 0.2
		samples[i] = tanh((valve_click + hiss + rumble) * 1.3) * 0.55
	return _to_stream(samples)


## Ballistic ceramic / steel armor plate fracture & shatter.
static func _spall() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * 0.4))
	var rng := RandomNumberGenerator.new()
	rng.seed = 66
	for i in samples.size():
		var t := float(i) / RATE
		var crack := rng.randf_range(-1.0, 1.0) * exp(-t * 110.0) * 0.6
		var stress_ping := (sin(TAU * 3100.0 * t) * 0.4 + sin(TAU * 4800.0 * t) * 0.2) * exp(-t * 28.0)
		var clatter := sin(TAU * 240.0 * t) * exp(-t * 18.0) * 0.35
		samples[i] = tanh((crack + stress_ping + clatter) * 1.4) * 0.6
	return _to_stream(samples)


## Concussive grenade / mortar lob launch.
static func _humbara_fire() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * 0.6))
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for i in samples.size():
		var t := float(i) / RATE
		var pitch_env: float = 45.0 + 75.0 * exp(-t * 30.0)
		var thump := sin(TAU * pitch_env * t) * exp(-t * 12.0) * 0.55
		var pop := rng.randf_range(-0.8, 0.8) * exp(-t * 45.0) * 0.35
		var tube := sin(TAU * 210.0 * t) * exp(-t * 18.0) * 0.3
		samples[i] = tanh((thump + pop + tube) * 1.5) * 0.7
	return _to_stream(samples)


static func _to_stream(samples: PackedFloat32Array, loop: bool = false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = data
	if loop:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = samples.size()
	return stream


## Fire-and-forget positional cue under parent (frees itself when done).
static func play_at(parent: Node, cue: StringName, at: Vector3, volume_db: float = 0.0) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var stream := get_stream(cue)
	if stream == null:
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = volume_db
	player.unit_size = 12.0
	player.max_distance = 120.0
	parent.add_child(player)
	player.global_position = at
	player.finished.connect(player.queue_free)
	player.play()
