class_name AudioLoader
extends RefCounted
## Runtime audio loader supporting .ogg and .wav files.


static func load_audio(path: String) -> AudioStream:
	if not FileAccess.file_exists(path):
		push_error("AudioLoader: file not found at '%s'" % path)
		return null

	var ext := path.get_extension().to_lower()
	if ext == "ogg":
		return _load_ogg(path)
	elif ext == "wav":
		return _load_wav(path)
	else:
		push_warning("AudioLoader: unsupported extension '%s'" % ext)
		return null


static func _load_ogg(path: String) -> AudioStream:
	var stream := AudioStreamOggVorbis.load_from_file(path)
	if stream == null:
		push_error("AudioLoader: failed to parse OGG file '%s'" % path)
	return stream


static func _load_wav(path: String) -> AudioStream:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("AudioLoader: cannot open WAV '%s'" % path)
		return null

	var bytes := file.get_buffer(file.get_length())
	file.close()

	if bytes.size() < 44:
		push_error("AudioLoader: WAV file too small '%s'" % path)
		return null

	# Verify RIFF & WAVE header
	if bytes.slice(0, 4).get_string_from_ascii() != "RIFF" or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		push_error("AudioLoader: Invalid WAV header in '%s'" % path)
		return null

	var stream := AudioStreamWAV.new()
	var channels: int = bytes.decode_u16(22)
	var sample_rate: int = bytes.decode_u32(24)
	var bits_per_sample: int = bytes.decode_u16(34)

	stream.mix_rate = sample_rate
	stream.stereo = (channels == 2)
	if bits_per_sample == 8:
		stream.format = AudioStreamWAV.FORMAT_8_BITS
	elif bits_per_sample == 16:
		stream.format = AudioStreamWAV.FORMAT_16_BITS
	else:
		stream.format = AudioStreamWAV.FORMAT_IMA_ADPCM

	# Search for "data" chunk
	var data_pos := 36
	while data_pos + 8 <= bytes.size():
		var chunk_id := bytes.slice(data_pos, data_pos + 4).get_string_from_ascii()
		var chunk_size := bytes.decode_u32(data_pos + 4)
		if chunk_id == "data":
			var data_start := data_pos + 8
			var data_end := mini(data_start + chunk_size, bytes.size())
			stream.data = bytes.slice(data_start, data_end)
			return stream
		data_pos += 8 + chunk_size

	# Fallback if no explicit data chunk found
	stream.data = bytes.slice(44)
	return stream
