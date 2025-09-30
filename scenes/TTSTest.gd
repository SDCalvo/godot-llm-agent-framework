## ElevenLabs TTS Test Script
##
## Tests the WebSocket-based ElevenLabsWrapper with 3 isolated test scenarios:
## 1. One-Shot Generation (speak_as_character)
## 2. Streaming Buffered (MP3 - collect & play)
## 3. Streaming Real-Time (PCM - play as received)

extends Node

## Imports (top of file, Python-style!)
const ElevenLabsWrapperScript = preload("res://addons/godot_llm/runtime/audio_services/elevenlabs_wrapper/ElevenLabsWrapper.gd")

## UI References (set by parent scene)
var console_output: RichTextLabel

## Test state (minimal - each test manages its own resources)
var test_results: Dictionary = {}

func _ready() -> void:
	# No global setup needed - each test manages its own resources!
	pass

## Main test entry point - runs 3 isolated test scenarios
func run_tts_test(output_console: RichTextLabel) -> void:
	console_output = output_console
	test_results.clear()
	
	log_info("🔊 Starting ElevenLabs WebSocket TTS Test Suite...")
	log_info("⚠️ Running ONLY Test 3 (Real-Time LLM) to save credits!")
	log_info("   (Tests 1 & 2 disabled until Test 3 works)")
	await get_tree().create_timer(1.0).timeout
	
	# ========== TEST 1: ONE-SHOT GENERATION (DISABLED) ==========
	#log_info("")
	#log_info("=".repeat(60))
	#log_info("🎯 TEST 1: ONE-SHOT GENERATION")
	#log_info("=".repeat(60))
	#await _test_one_shot_generation()
	#
	#await get_tree().create_timer(1.0).timeout
	
	# ========== TEST 2: STREAMING BUFFERED (DISABLED) ==========
	#log_info("")
	#log_info("=".repeat(60))
	#log_info("🎯 TEST 2: STREAMING BUFFERED (MP3)")
	#log_info("=".repeat(60))
	#await _test_streaming_buffered()
	#
	#await get_tree().create_timer(1.0).timeout
	
	# ========== TEST 3: STREAMING REAL-TIME (PCM) - ONLY THIS ONE! ==========
	log_info("")
	log_info("=".repeat(60))
	log_info("🎯 TEST 3: STREAMING REAL-TIME (LLM → TTS)")
	log_info("=".repeat(60))
	await _test_streaming_realtime()
	
	# ========== DISPLAY SUMMARY ==========
	_display_test_summary()

## Test 1: One-Shot Generation (speak_as_character)
func _test_one_shot_generation() -> void:
	log_info("📦 Testing one-shot generation with speak_as_character()")
	log_info("   Creates context → Speaks complete text → Auto-closes")
	
	# Set mode to BUFFERED
	ElevenLabsWrapper.set_streaming_mode(ElevenLabsWrapper.StreamingMode.BUFFERED)
	
	# Create isolated context for this test
	var context_id = "oneshot_test"
	var voice_id = "21m00Tcm4TlvDq8ikWAM"  # Rachel
	
	log_info("📝 Creating one-shot context...")
	var created = await ElevenLabsWrapper.create_character_context(context_id, voice_id)
	
	if not created:
		_record_test_result("one_shot", false, "Failed to create context")
		return
	
	# Create audio player for this test
	var player = AudioStreamPlayer.new()
	add_child(player)
	
	log_info("🎤 Speaking: 'This is a one-shot generation test using speak_as_character.'")
	
	# Use speak_as_character (one-shot, auto-closes)
	var success = ElevenLabsWrapper.speak_as_character(context_id, "This is a one-shot generation test using speak_as_character.")
	
	if not success:
		_record_test_result("one_shot", false, "Failed to speak")
		player.queue_free()
		return
	
	# Wait for ready-to-play AudioStream (high-level API!)
	var state = {"stream_ready": false}
	
	var stream_handler = func(stream: AudioStream, ctx_id: String):
		if ctx_id == context_id:
			# High-level API: just assign and play!
			player.stream = stream
			player.play()
			state["stream_ready"] = true
			log_success("🔊 Playing one-shot audio (AudioStreamMP3 ready!)")
	
	ElevenLabsWrapper.audio_stream_ready.connect(stream_handler)
	
	# Wait for AudioStream to be ready (should be quick, connection auto-closes)
	var timeout = 10.0
	var elapsed = 0.0
	while not state["stream_ready"] and elapsed < timeout:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	
	ElevenLabsWrapper.audio_stream_ready.disconnect(stream_handler)
	
	if state["stream_ready"]:
		await get_tree().create_timer(3.0).timeout  # Let audio play
		_record_test_result("one_shot", true, "One-shot generation successful")
	else:
		_record_test_result("one_shot", false, "Timeout waiting for audio stream")
	
	# Cleanup
	player.queue_free()
	ElevenLabsWrapper.destroy_character_context(context_id)
	log_info("✅ One-shot test complete")

## Test 2: Streaming Buffered (MP3 - collect and play)
func _test_streaming_buffered() -> void:
	log_info("📦 Testing streaming with buffered playback (MP3)")
	log_info("   Creates context → Feeds chunks → Collects MP3 → Plays complete audio")
	
	# Set mode to BUFFERED
	ElevenLabsWrapper.set_streaming_mode(ElevenLabsWrapper.StreamingMode.BUFFERED)
	
	# Create isolated context for this test
	var context_id = "buffered_test"
	var voice_id = "AZnzlk1XvdvUeBnXmlld"  # Domi
	
	log_info("📝 Creating buffered streaming context...")
	var created = await ElevenLabsWrapper.create_character_context(context_id, voice_id)
	
	if not created:
		_record_test_result("streaming_buffered", false, "Failed to create context")
		return
	
	# Create audio player
	var player = AudioStreamPlayer.new()
	add_child(player)
	
	# Wait for ready-to-play AudioStream
	var state = {"stream_ready": false}
	
	var stream_handler = func(stream: AudioStream, ctx_id: String):
		if ctx_id == context_id:
			# High-level API: just assign and play!
			player.stream = stream
			player.play()
			state["stream_ready"] = true
			log_success("🔊 Playing buffered audio (AudioStreamMP3 ready!)")
	
	ElevenLabsWrapper.audio_stream_ready.connect(stream_handler)
	
	# Feed text chunks (simulate LLM streaming)
	var text_chunks = ["Buffered ", "streaming ", "test. ", "Collecting ", "MP3 ", "chunks!"]
	log_info("📝 Feeding text chunks...")
	
	for chunk in text_chunks:
		ElevenLabsWrapper.feed_text_to_character(context_id, chunk)
		log_info("   → '" + chunk + "'")
		await get_tree().create_timer(0.5).timeout
	
	# Finish speech
	ElevenLabsWrapper.finish_character_speech(context_id)
	log_info("🏁 Finished feeding text")
	
	# Wait for AudioStream to be ready
	var timeout = 10.0
	var elapsed = 0.0
	while not state["stream_ready"] and elapsed < timeout:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	
	ElevenLabsWrapper.audio_stream_ready.disconnect(stream_handler)
	
	if state["stream_ready"]:
		await get_tree().create_timer(3.0).timeout  # Let audio play
		_record_test_result("streaming_buffered", true, "Buffered streaming successful")
	else:
		_record_test_result("streaming_buffered", false, "Timeout waiting for audio stream")
	
	# Cleanup
	player.queue_free()
	ElevenLabsWrapper.destroy_character_context(context_id)
	log_info("✅ Buffered streaming test complete")

## Test 3: Streaming Real-Time (PCM - REAL LLM Integration!)
func _test_streaming_realtime() -> void:
	log_info("⚡ Testing streaming with REAL LLM output (PCM)")
	log_info("   LLM generates text → Streams to TTS → Plays in real-time")
	log_info("   ✨ This tests the ACTUAL integration flow!")
	
	# Set mode to REAL-TIME
	ElevenLabsWrapper.set_streaming_mode(ElevenLabsWrapper.StreamingMode.REAL_TIME)
	
	# Create isolated context for this test
	var context_id = "realtime_llm_test"
	var voice_id = "EXAVITQu4vr4xnSDxMaL"  # Bella
	
	log_info("📝 Creating real-time streaming context...")
	var created = await ElevenLabsWrapper.create_character_context(context_id, voice_id)
	
	if not created:
		_record_test_result("streaming_realtime", false, "Failed to create context")
		return
	
	# Create AudioStreamGenerator for real-time playback
	var player = AudioStreamPlayer.new()
	add_child(player)
	var generator = AudioStreamGenerator.new()
	generator.mix_rate = ElevenLabsWrapper.PCM_SAMPLE_RATE
	generator.buffer_length = 2.0  # 2 seconds = 32000 frames (plenty of headroom!)
	player.stream = generator
	player.play()
	
	await get_tree().process_frame  # Wait for generator to initialize
	
	var playback: AudioStreamGeneratorPlayback = player.get_stream_playback()
	if not playback:
		log_error("❌ Failed to get AudioStreamGeneratorPlayback")
		_record_test_result("streaming_realtime", false, "Failed to setup playback")
		player.queue_free()
		return
	
	var state = {"audio_received": false, "synthesis_complete": false, "llm_complete": false}
	
	# Create a DEDICATED Node for queue processing (survives hot-reloads!)
	var queue_processor_node = Node.new()
	queue_processor_node.name = "AudioQueueProcessor"
	add_child(queue_processor_node)
	
	# Add script to the node
	var queue_script = GDScript.new()
	queue_script.source_code = """
extends Node

var audio_queue: Array[PackedByteArray] = []
var playback: AudioStreamGeneratorPlayback
var wrapper_script
var log_callback: Callable

func add_chunk(chunk: PackedByteArray) -> void:
	audio_queue.append(chunk)

func queue_size() -> int:
	return audio_queue.size()

func _process(_delta):
	if not playback or audio_queue.is_empty():
		return
	
	var chunks_processed = 0
	while not audio_queue.is_empty():
		var next_chunk = audio_queue[0]
		var frames_needed = int(next_chunk.size() / 2.0)
		var frames_available = playback.get_frames_available()
		
		if frames_available >= frames_needed:
			var chunk = audio_queue.pop_front()
			wrapper_script.convert_pcm_to_frames(playback, chunk)
			chunks_processed += 1
		else:
			break
	
	if chunks_processed > 0 and log_callback:
		log_callback.call("🔄 Processed " + str(chunks_processed) + " chunk(s), " + str(audio_queue.size()) + " remaining in queue")
"""
	queue_script.reload()
	queue_processor_node.set_script(queue_script)
	queue_processor_node.set("playback", playback)
	queue_processor_node.set("wrapper_script", ElevenLabsWrapperScript)
	queue_processor_node.set("log_callback", log_info)
	
	# Real-time audio handler - queues chunks for smooth playback
	var chunk_handler = func(audio: PackedByteArray, ctx_id: String):
		print("[TTSTest] 🎧 chunk_handler called! ctx_id='%s', expected='%s', size=%d" % [ctx_id, context_id, audio.size()])
		if ctx_id == context_id:
			state["audio_received"] = true
			var frames_needed = int(audio.size() / 2.0)
			var frames_available = playback.get_frames_available()
			var queue_size_now = queue_processor_node.queue_size()
			
			print("[TTSTest] 📊 Buffer check: needed=%d, available=%d, queue_size=%d" % [frames_needed, frames_available, queue_size_now])
			
			if frames_available >= frames_needed and queue_size_now == 0:
				# Buffer has space AND no queue - push immediately
				log_info("⚡ Real-time chunk (" + str(audio.size()) + " bytes) - Pushing to buffer NOW!")
				ElevenLabsWrapperScript.convert_pcm_to_frames(playback, audio)
			else:
				# Buffer full OR queue has items - add to queue
				log_info("📦 Real-time chunk (" + str(audio.size()) + " bytes) - Queued (buffer: " + str(frames_available) + "/" + str(frames_needed) + ")")
				queue_processor_node.add_chunk(audio)
		else:
			print("[TTSTest] ⚠️ Received chunk for DIFFERENT context: '%s' (expected '%s')" % [ctx_id, context_id])
	
	var complete_handler = func(ctx_id: String):
		if ctx_id == context_id:
			state["synthesis_complete"] = true
			log_success("✅ Real-time synthesis completed")
	
	var error_handler = func(ctx_id: String, error: Dictionary):
		if ctx_id == context_id:
			log_error("❌ Synthesis error: " + str(error))
	
	ElevenLabsWrapper.audio_chunk_ready.connect(chunk_handler)
	ElevenLabsWrapper.synthesis_completed.connect(complete_handler)
	ElevenLabsWrapper.synthesis_error.connect(error_handler)
	
	# Create agent using LLMManager (simple and clean!)
	log_info("🤖 Creating LLMAgent via LLMManager...")
	var agent_config = {
		"model": "gpt-4o-mini",
		"temperature": 0.7,
		"system_prompt": "You are a helpful assistant.",
		"max_output_tokens": 100
	}
	
	# Use LLMManager factory - handles wrapper injection automatically!
	var agent = LLMManager.create_agent(agent_config, [])
	
	if not agent:
		log_error("❌ Failed to create agent (LLMManager not configured?)")
		_record_test_result("streaming_realtime", false, "Agent creation failed")
		player.queue_free()
		return
	
	log_info("🤖 Starting LLM stream...")
	log_info("   Prompt: 'Say hello in exactly 10 words'")
	
	# Connect to LLM's delta signal to stream text to TTS
	var delta_handler = func(_run_id: String, text_delta: String):
		if text_delta and text_delta.length() > 0:
			log_info("   📝 LLM chunk: '" + text_delta + "' → Feeding to TTS")
			ElevenLabsWrapper.feed_text_to_character(context_id, text_delta)
	
	var finished_handler = func(_run_id: String, _ok: bool, _result: Dictionary):
		log_success("✅ LLM finished generating")
		state["llm_complete"] = true
		# Close TTS input stream
		ElevenLabsWrapper.finish_character_speech(context_id)
		log_info("🏁 TTS input closed")
	
	agent.delta.connect(delta_handler)
	agent.finished.connect(finished_handler)
	
	# Start LLM streaming (ainvoke = streaming, returns run_id)
	agent.ainvoke(Message.user_simple("Say hello in exactly 10 words"))
	
	# Wait for LLM to complete
	var timeout = 15.0
	var elapsed = 0.0
	while not state["llm_complete"] and elapsed < timeout:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	
	if not state["llm_complete"]:
		log_error("❌ LLM timeout!")
	
	# Wait for synthesis to complete
	elapsed = 0.0
	while not state["synthesis_complete"] and elapsed < timeout:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	
	# Wait for queue to be fully processed
	var current_queue_size = queue_processor_node.queue_size()
	log_info("⏳ Waiting for audio queue to be processed... Queue size: " + str(current_queue_size))
	elapsed = 0.0
	var last_queue_size = current_queue_size
	while current_queue_size > 0 and elapsed < timeout:
		await get_tree().create_timer(0.05).timeout  # Check more frequently
		elapsed += 0.05
		current_queue_size = queue_processor_node.queue_size()
		if current_queue_size != last_queue_size:
			log_info("   Queue draining: " + str(current_queue_size) + " chunks remaining")
			last_queue_size = current_queue_size
	
	if current_queue_size == 0:
		log_info("✅ Queue empty!")
	else:
		log_error("❌ Queue timeout! Still " + str(current_queue_size) + " chunks in queue")
	
	# Wait for buffer to be played out (buffer_length + safety margin)
	var buffer_drain_time = generator.buffer_length + 0.5  # Buffer time + 0.5s safety
	log_info("⏳ Waiting " + str(buffer_drain_time) + "s for buffer to drain...")
	await get_tree().create_timer(buffer_drain_time).timeout
	
	# Cleanup signals
	agent.delta.disconnect(delta_handler)
	agent.finished.disconnect(finished_handler)
	ElevenLabsWrapper.audio_chunk_ready.disconnect(chunk_handler)
	ElevenLabsWrapper.synthesis_completed.disconnect(complete_handler)
	ElevenLabsWrapper.synthesis_error.disconnect(error_handler)
	
	if state["audio_received"] and state["llm_complete"]:
		_record_test_result("streaming_realtime", true, "Real-time LLM→TTS streaming successful!")
	else:
		var reason = "LLM complete: " + str(state["llm_complete"]) + ", Audio received: " + str(state["audio_received"])
		_record_test_result("streaming_realtime", false, reason)
	
	# Cleanup resources
	queue_processor_node.queue_free()  # Remove dedicated processor node
	player.queue_free()
	# Agent managed by LLMManager - no manual cleanup needed!
	ElevenLabsWrapper.destroy_character_context(context_id)
	log_info("✅ Real-time LLM streaming test complete")

## ========== UTILITY METHODS ==========

## Record test result
func _record_test_result(test_name: String, success: bool, message: String) -> void:
	test_results[test_name] = {
		"success": success,
		"message": message
	}

## Display test summary
func _display_test_summary() -> void:
	log_info("")
	log_info("=".repeat(60))
	log_info("📊 FINAL TEST SUMMARY")
	log_info("=".repeat(60))
	
	var total_tests = test_results.size()
	var passed_tests = 0
	
	for test_name in test_results:
		var result = test_results[test_name]
		if result["success"]:
			passed_tests += 1
			log_success("✅ " + test_name + ": " + result["message"])
		else:
			log_error("❌ " + test_name + ": " + result["message"])
	
	log_info("")
	var pass_rate = float(passed_tests) / float(total_tests) * 100.0 if total_tests > 0 else 0.0
	log_info("📈 Pass Rate: " + str(passed_tests) + "/" + str(total_tests) + " (" + str(pass_rate) + "%)")
	log_info("")
	log_info("💡 KEY OBSERVATIONS:")
	log_info("   📦 BUFFERED MODE: Collect all audio → Play complete (smoother, ~2-3s delay)")
	log_info("   ⚡ REAL-TIME MODE: Play chunks immediately (lowest latency, ~100-500ms)")
	log_info("")
	
	if pass_rate >= 80.0:
		log_success("🎉 TTS Test Suite PASSED!")
	else:
		log_error("💥 TTS Test Suite FAILED!")

## ========== LOGGING METHODS ==========

func log_info(message: String) -> void:
	if console_output:
		console_output.append_text("[color=white]" + message + "[/color]\n")
		console_output.scroll_to_line(console_output.get_line_count())

func log_success(message: String) -> void:
	if console_output:
		console_output.append_text("[color=green]" + message + "[/color]\n")
		console_output.scroll_to_line(console_output.get_line_count())

func log_error(message: String) -> void:
	if console_output:
		console_output.append_text("[color=red]" + message + "[/color]\n")
		console_output.scroll_to_line(console_output.get_line_count())

func log_warning(message: String) -> void:
	if console_output:
		console_output.append_text("[color=yellow]" + message + "[/color]\n")
		console_output.scroll_to_line(console_output.get_line_count())
