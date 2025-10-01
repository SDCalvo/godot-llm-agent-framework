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
	
	# Ensure clean state (destroy if exists from previous run)
	if ElevenLabsWrapper.character_contexts.has(context_id):
		log_warning("⚠️ Context already exists from previous run - destroying it first...")
		ElevenLabsWrapper.destroy_character_context(context_id)
	
	log_info("📝 Creating real-time streaming context...")
	var created = await ElevenLabsWrapper.create_character_context(context_id, voice_id)
	
	if not created:
		_record_test_result("streaming_realtime", false, "Failed to create context")
		return
	
	# ✨ NEW: Simple one-line player creation using helper!
	var player = await ElevenLabsWrapperScript.create_realtime_player(self, context_id)
	if not player:
		log_error("❌ Failed to create real-time player")
		_record_test_result("streaming_realtime", false, "Failed to create player")
		return
	
	log_success("✅ Real-time player created and ready!")
	
	var state = {"audio_received": false, "synthesis_complete": false}
	
	# Track when audio is received (for test validation)
	var audio_received_handler = func(_audio: PackedByteArray, ctx_id: String):
		if ctx_id == context_id:
			state["audio_received"] = true
	
	var complete_handler = func(ctx_id: String):
		if ctx_id == context_id:
			state["synthesis_complete"] = true
			log_success("✅ Real-time synthesis completed")
	
	var error_handler = func(ctx_id: String, error: Dictionary):
		if ctx_id == context_id:
			log_error("❌ Synthesis error: " + str(error))
	
	ElevenLabsWrapper.audio_chunk_ready.connect(audio_received_handler)
	ElevenLabsWrapper.synthesis_completed.connect(complete_handler)
	ElevenLabsWrapper.synthesis_error.connect(error_handler)
	
	# Create agent using LLMManager (simple and clean!)
	log_info("🤖 Creating LLMAgent via LLMManager...")
	var agent = LLMManager.create_agent({
		"model": "gpt-4o-mini",
		"temperature": 0.7,
		"system_prompt": "You are a helpful assistant."
	}, [])
	
	if not agent:
		log_error("❌ Failed to create agent")
		_record_test_result("streaming_realtime", false, "Agent creation failed")
		player.cleanup()
		return
	
	# Define the prompt
	var prompt = "Please tell me a bit about yourself. Include details about your capabilities, personality, and purpose. Aim for around 100 words max."
	
	log_info("🤖 Starting LLM stream...")
	log_info("   Prompt: '" + prompt + "'")
	
	# ✨ SIMPLIFIED: Just feed text directly - batching is automatic!
	var delta_handler = func(_run_id: String, text_delta: String):
		if text_delta and text_delta.length() > 0:
			log_info("   📝 LLM chunk: '" + text_delta + "'")
			# Wrapper handles batching automatically! Just feed text.
			ElevenLabsWrapper.feed_text_to_character(context_id, text_delta)
	
	var finished_handler = func(_run_id: String, _ok: bool, _result: Dictionary):
		log_success("✅ LLM finished generating")
		# Flush any remaining buffered text (Python SDK text_chunker does this)
		var final_buffer = ElevenLabsWrapper.character_contexts[context_id]["batch_buffer"]
		if final_buffer and final_buffer.length() > 0:
			log_info("   📤 Flushing final buffer: '%s'" % final_buffer)
			# Feed with flush_immediately=true to force send
			ElevenLabsWrapper.feed_text_to_character(context_id, "", true)
		
		# Python SDK: Send {"text":""} and drain remaining messages
		log_info("   🏁 Sending close signal and draining...")
		await ElevenLabsWrapper.finish_character_speech(context_id)
	
	# Wait for playback to finish (signal-based, no arbitrary timeouts!)
	var playback_complete = {"finished": false}
	var playback_handler = func(ctx_id: String):
		if ctx_id == context_id:
			playback_complete["finished"] = true
			log_success("✅ Playback finished - all audio played!")
	
	ElevenLabsWrapper.playback_finished.connect(playback_handler)
	
	agent.delta.connect(delta_handler)
	agent.finished.connect(finished_handler)
	
	# Start LLM streaming (ainvoke = streaming, returns run_id)
	agent.ainvoke(Message.user_simple(prompt))
	
	# Wait for synthesis and playback to complete
	log_info("⏳ Waiting for synthesis...")
	while not state["synthesis_complete"]:
		await get_tree().create_timer(0.1).timeout
	
	# Synthesis done, now wait for playback
	log_success("✅ Synthesis complete! Waiting for all audio to finish playing...")
	while not playback_complete["finished"]:
		await get_tree().create_timer(0.1).timeout
	
	# Cleanup
	log_info("🧹 Cleaning up test resources...")
	ElevenLabsWrapper.playback_finished.disconnect(playback_handler)
	agent.delta.disconnect(delta_handler)
	agent.finished.disconnect(finished_handler)
	ElevenLabsWrapper.audio_chunk_ready.disconnect(audio_received_handler)
	ElevenLabsWrapper.synthesis_completed.disconnect(complete_handler)
	ElevenLabsWrapper.synthesis_error.disconnect(error_handler)
	player.cleanup()
	
	# Destroy context (cleanup is synchronous, no wait needed)
	if ElevenLabsWrapper.character_contexts.has(context_id):
		log_info("   🗑️ Destroying context: " + context_id)
		ElevenLabsWrapper.destroy_character_context(context_id)
	
	# Record result
	var success = state["audio_received"] and state["synthesis_complete"]
	var msg = "Real-time LLM→TTS successful!" if success else "No audio received"
	_record_test_result("streaming_realtime", success, msg)
	log_success("✅ Real-time LLM streaming test complete")

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
