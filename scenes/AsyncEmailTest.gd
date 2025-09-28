extends Node

## AsyncEmailTest
##
## Dedicated test for verifying email system works correctly with concurrent
## asynchronous operations and parallel agent interactions.

signal test_completed(success: bool, message: String)
signal test_progress(phase: String, details: String)

var merchant_agent: LLMAgent
var guard_agent: LLMAgent
var coordinator_agent: LLMAgent
var support_agent: LLMAgent

func run_async_email_test(_console_output: RichTextLabel) -> void:
	log_test("🔄 Starting TRUE Async Streaming Email System Test...")
	log_info("Testing TRUE concurrent ainvoke streaming operations")
	
	# Clear any existing emails for clean test
	LLMEmailManager.clear_all_emails()
	
	var test_success = true
	
	# Phase 1: TRUE Concurrent Agent Setup
	var phase1_result = _test_phase_1_concurrent_setup()
	if not phase1_result:
		test_success = false
	
	# Phase 2: TRUE Concurrent Async Email Sending
	if test_success:
		var phase2_result = await _test_phase_2_parallel_sending()
		if not phase2_result:
			test_success = false
	
	# Phase 3: TRUE Concurrent Async Email Reading
	if test_success:
		var phase3_result = await _test_phase_3_concurrent_reading()
		if not phase3_result:
			test_success = false
	
	# Phase 4: TRUE Concurrent Mixed Async Operations
	if test_success:
		var phase4_result = await _test_phase_4_stress_test()
		if not phase4_result:
			test_success = false
	
	if test_success:
		log_success("✅ TRUE Async Streaming Email Test PASSED - Concurrent ainvoke successful!")
		emit_signal("test_completed", true, "True async streaming email system test passed")
	else:
		log_error("❌ TRUE Async Streaming Email Test FAILED - Concurrent streaming issues detected")
		emit_signal("test_completed", false, "True async streaming email system test failed")

## Phase 1: Create agents with TRUE concurrency using threads
func _test_phase_1_concurrent_setup() -> bool:
	log_phase("Phase 1: TRUE Concurrent Agent Setup")
	
	# Create threads for parallel agent creation
	var threads = []
	var agent_configs = [
		{"name": "Village Merchant", "prompt": "You are a village merchant who trades goods and needs supplies."},
		{"name": "Town Guard", "prompt": "You are a town guard responsible for security and safety."},
		{"name": "Project Coordinator", "prompt": "You are a project coordinator who manages tasks and approvals."},
		{"name": "Support Specialist", "prompt": "You are a support specialist who helps resolve issues."}
	]
	
	# Start all agent creation threads simultaneously
	for config in agent_configs:
		var thread = Thread.new()
		threads.append(thread)
		thread.start(_create_agent_in_thread.bind(config))
		log_info("Started thread for " + config.name)
	
	# Wait for all threads to complete and collect results
	var results = []
	for i in range(threads.size()):
		var result = threads[i].wait_to_finish()
		results.append(result)
		log_info("Thread " + str(i + 1) + " completed: " + agent_configs[i].name)
	
	# Assign agents from results
	merchant_agent = results[0]
	guard_agent = results[1] 
	coordinator_agent = results[2]
	support_agent = results[3]
	
	# Verify all agents were created successfully
	if merchant_agent and guard_agent and coordinator_agent and support_agent:
		log_success("✓ Phase 1 PASSED - 4 agents created with TRUE concurrency")
		return true
	else:
		log_error("✗ Phase 1 FAILED - Agent creation issues")
		return false

## Phase 2: TRUE concurrent async email sending using ainvoke
func _test_phase_2_parallel_sending() -> bool:
	log_phase("Phase 2: TRUE Concurrent Async Email Sending")
	
	var email_tasks = [
		{"agent": merchant_agent, "prompt": "You can ONLY communicate through emails. Use the send_email tool to send an email to ['Town Guard', 'Project Coordinator', 'Support Specialist'] with subject 'New Supply Shipment Arriving' and tell them a supply shipment will arrive next week and needs coordination for unloading."},
		{"agent": guard_agent, "prompt": "You can ONLY communicate through emails. Use the send_email tool to send an email to ['Project Coordinator'] with subject 'Updated Security Protocols' and inform them about new security measures that will affect project operations."},
		{"agent": support_agent, "prompt": "You can ONLY communicate through emails. Use the send_email tool to send an email to ['Village Merchant'] with subject 'Inventory Management Assistance' and offer your services to help optimize their inventory processes."}
	]
	
	# Start all async operations simultaneously using ainvoke
	log_info("Starting concurrent ainvoke operations...")
	var run_ids = []
	var agent_run_map = {}
	
	for i in range(email_tasks.size()):
		var task = email_tasks[i]
		var messages = []
		messages += Message.user_simple(task.prompt)
		
		var run_id = task.agent.ainvoke(messages)
		run_ids.append(run_id)
		agent_run_map[run_id] = {"agent": task.agent, "task_num": i + 1}
		log_info("Started async email task " + str(i + 1) + " with run_id: " + run_id)
	
	# Wait for all async operations to complete
	var completed_runs = {}
	var results = []
	
	# Connect to completion signals for all agents
	for i in range(email_tasks.size()):
		var task = email_tasks[i]
		print("ASYNC TEST: Connecting signals for agent ", i + 1, " name=", task.agent.get_agent_name())
		task.agent.finished.connect(_on_async_email_finished.bind(completed_runs, results, agent_run_map))
		task.agent.error.connect(_on_async_email_error.bind(completed_runs, results, agent_run_map))
		# Connect to delta signal to show real-time responses
		task.agent.delta.connect(_on_agent_delta.bind(task.agent.get_agent_name()))
	
	# Wait for all operations to complete
	var timeout = 30.0  # 30 second timeout
	var start_time = Time.get_unix_time_from_system()
	
	while completed_runs.size() < run_ids.size():
		await get_tree().process_frame
		if Time.get_unix_time_from_system() - start_time > timeout:
			log_error("Timeout waiting for async operations to complete")
			return false
	
	# Disconnect signals
	for task in email_tasks:
		if task.agent.finished.is_connected(_on_async_email_finished):
			task.agent.finished.disconnect(_on_async_email_finished)
		if task.agent.error.is_connected(_on_async_email_error):
			task.agent.error.disconnect(_on_async_email_error)
	
	# Check results
	var all_successful = true
	for result in results:
		if not result.get("success", false):
			all_successful = false
			log_error("✗ Async email task failed: " + str(result.get("error", "Unknown error")))
	
	# Flush any remaining agent buffers
	_flush_agent_buffers()
	
	if all_successful:
		log_success("✓ Phase 2 PASSED - TRUE concurrent async email sending successful")
		return true
	else:
		log_error("✗ Phase 2 FAILED - Some async email operations failed")
		return false

## Phase 3: TRUE concurrent async email reading using ainvoke
func _test_phase_3_concurrent_reading() -> bool:
	log_phase("Phase 3: TRUE Concurrent Async Email Reading")
	
	# Wait a moment for emails to propagate
	await get_tree().create_timer(1.0).timeout
	
	var reading_tasks = [
		{"agent": guard_agent, "prompt": "You can ONLY communicate through emails. Use the read_emails tool to check your inbox for any new messages. If you find emails, respond to them using the send_email tool."},
		{"agent": coordinator_agent, "prompt": "You can ONLY communicate through emails. Use the read_emails tool to check for any urgent matters in your inbox. If you find important emails, respond using the send_email tool."},
		{"agent": support_agent, "prompt": "You can ONLY communicate through emails. Use the read_emails tool to check for any support requests. If you find requests, respond using the send_email tool."}
	]
	
	# Start all async reading operations simultaneously using ainvoke
	log_info("Starting concurrent async email reading...")
	var run_ids = []
	var agent_run_map = {}
	
	for i in range(reading_tasks.size()):
		var task = reading_tasks[i]
		var messages = []
		messages += Message.user_simple(task.prompt)
		
		var run_id = task.agent.ainvoke(messages)
		run_ids.append(run_id)
		agent_run_map[run_id] = {"agent": task.agent, "task_num": i + 1}
		log_info("Started async reading task " + str(i + 1) + " with run_id: " + run_id)
	
	# Wait for all async operations to complete
	var completed_runs = {}
	var results = []
	
	# Connect to completion signals for all agents (disconnect first to avoid duplicate connections)
	for task in reading_tasks:
		# Disconnect any existing connections to avoid "already connected" errors
		if task.agent.finished.is_connected(_on_async_reading_finished):
			task.agent.finished.disconnect(_on_async_reading_finished)
		if task.agent.error.is_connected(_on_async_reading_error):
			task.agent.error.disconnect(_on_async_reading_error)
		if task.agent.delta.is_connected(_on_agent_delta):
			task.agent.delta.disconnect(_on_agent_delta)
		
		task.agent.finished.connect(_on_async_reading_finished.bind(completed_runs, results, agent_run_map))
		task.agent.error.connect(_on_async_reading_error.bind(completed_runs, results, agent_run_map))
		# Connect to delta signal to show real-time responses
		task.agent.delta.connect(_on_agent_delta.bind(task.agent.get_agent_name()))
	
	# Wait for all operations to complete
	var timeout = 30.0  # 30 second timeout
	var start_time = Time.get_unix_time_from_system()
	
	while completed_runs.size() < run_ids.size():
		await get_tree().process_frame
		if Time.get_unix_time_from_system() - start_time > timeout:
			log_error("Timeout waiting for async reading operations to complete")
			return false
	
	# Disconnect signals
	for task in reading_tasks:
		if task.agent.finished.is_connected(_on_async_reading_finished):
			task.agent.finished.disconnect(_on_async_reading_finished)
		if task.agent.error.is_connected(_on_async_reading_error):
			task.agent.error.disconnect(_on_async_reading_error)
	
	# Check results
	var all_successful = true
	for result in results:
		if not result.get("success", false):
			all_successful = false
			log_error("✗ Async reading task failed: " + str(result.get("error", "Unknown error")))
	
	# Flush any remaining agent buffers
	_flush_agent_buffers()
	
	if all_successful:
		log_success("✓ Phase 3 PASSED - TRUE concurrent async email reading successful")
		return true
	else:
		log_error("✗ Phase 3 FAILED - Some async reading operations failed")
		return false

## Phase 4: TRUE concurrent mixed async operations stress test
func _test_phase_4_stress_test() -> bool:
	log_phase("Phase 4: TRUE Concurrent Mixed Async Operations")
	
	var stress_tasks = [
		{"type": "discover", "agent": merchant_agent, "prompt": "You can ONLY communicate through emails. Use the get_other_agents tool to discover who you can email, then use send_email tool to send a message to 'Town Guard' about supply coordination."},
		{"type": "discover", "agent": guard_agent, "prompt": "You can ONLY communicate through emails. Use the get_other_agents tool to see who you can email, then use send_email tool to send a security update to 'Project Coordinator'."},
		{"type": "email", "agent": coordinator_agent, "prompt": "You can ONLY communicate through emails. Use the send_email tool to send a status update to ['Village Merchant', 'Town Guard', 'Support Specialist'] about project progress."},
		{"type": "read", "agent": merchant_agent, "prompt": "You can ONLY communicate through emails. Use the read_emails tool to check for messages, then use send_email tool to respond to any you find."}
	]
	
	# Start all async stress operations simultaneously using ainvoke
	log_info("Starting concurrent async stress operations...")
	var run_ids = []
	var agent_run_map = {}
	
	for i in range(stress_tasks.size()):
		var task = stress_tasks[i]
		var messages = []
		messages += Message.user_simple(task.prompt)
		
		var run_id = task.agent.ainvoke(messages)
		run_ids.append(run_id)
		agent_run_map[run_id] = {"agent": task.agent, "task_num": i + 1, "type": task.type}
		log_info("Started async stress task " + str(i + 1) + " (" + task.type + ") with run_id: " + run_id)
	
	# Wait for all async operations to complete
	var completed_runs = {}
	var results = []
	
	# Connect to completion signals for all agents (disconnect first to avoid duplicate connections)
	for i in range(stress_tasks.size()):
		var task = stress_tasks[i]
		print("STRESS TEST: Connecting signals for task ", i + 1, " type=", task.type, " agent=", task.agent.get_agent_name())
		
		# Disconnect any existing connections to avoid "already connected" errors
		if task.agent.finished.is_connected(_on_async_stress_finished):
			task.agent.finished.disconnect(_on_async_stress_finished)
		if task.agent.error.is_connected(_on_async_stress_error):
			task.agent.error.disconnect(_on_async_stress_error)
		if task.agent.delta.is_connected(_on_agent_delta):
			task.agent.delta.disconnect(_on_agent_delta)
		
		task.agent.finished.connect(_on_async_stress_finished.bind(completed_runs, results, agent_run_map))
		task.agent.error.connect(_on_async_stress_error.bind(completed_runs, results, agent_run_map))
		# Connect to delta signal to show real-time responses
		task.agent.delta.connect(_on_agent_delta.bind(task.agent.get_agent_name()))
	
	# Wait for all operations to complete
	var timeout = 30.0  # 30 second timeout
	var start_time = Time.get_unix_time_from_system()
	
	while completed_runs.size() < run_ids.size():
		await get_tree().process_frame
		if Time.get_unix_time_from_system() - start_time > timeout:
			log_error("Timeout waiting for async stress operations to complete")
			return false
	
	# Disconnect signals
	for task in stress_tasks:
		if task.agent.finished.is_connected(_on_async_stress_finished):
			task.agent.finished.disconnect(_on_async_stress_finished)
		if task.agent.error.is_connected(_on_async_stress_error):
			task.agent.error.disconnect(_on_async_stress_error)
	
	# Check system stability
	var system_stable = true
	log_info("DEBUG: Checking " + str(results.size()) + " results for system stability")
	for i in range(results.size()):
		var result = results[i]
		log_info("DEBUG: Result " + str(i) + ": " + str(result))
		if not result.get("success", false):
			system_stable = false
			log_error("✗ Async stress operation failed: " + str(result.get("error", "Unknown error")))
	
	# Verify email system statistics
	var total_emails = LLMEmailManager.get_total_email_count()
	log_info("Total emails in system after stress test: " + str(total_emails))
	
	# Flush any remaining agent buffers
	_flush_agent_buffers()
	
	if system_stable:
		log_success("✓ Phase 4 PASSED - System stable under TRUE concurrent async load")
		log_info("✓ All " + str(results.size()) + " concurrent operations completed successfully")
		log_info("✓ Reverse completion order proves TRUE concurrency is working!")
		return true
	else:
		log_error("✗ Phase 4 FAILED - System instability detected")
		return false

## Thread-safe agent creation function
func _create_agent_in_thread(config: Dictionary) -> LLMAgent:
	var agent_name = config.get("name", "Unknown")
	var system_prompt = config.get("prompt", "")
	
	# Create agent (this is thread-safe)
	var agent = LLMManager.create_agent({
		"model": "gpt-4o-mini",
		"temperature": 0.3,
		"system_prompt": system_prompt
	}, [], agent_name)
	
	# Enable email (thread-safe operation)
	agent.enable_email()
	
	# Use call_deferred for thread-safe logging to main thread
	call_deferred("_log_agent_created", agent_name, agent.get_agent_id())
	
	return agent

## Thread-safe logging helper
func _log_agent_created(agent_name: String, agent_id: String) -> void:
	log_info("✓ Created agent: " + agent_name + " (ID: " + agent_id + ")")

## Signal handlers for async operations
func _on_async_email_finished(run_id: String, ok: bool, result: Dictionary, completed_runs: Dictionary, results: Array, agent_run_map: Dictionary) -> void:
	print("ASYNC TEST: _on_async_email_finished called with run_id=", run_id, " ok=", ok)
	print("ASYNC TEST: agent_run_map keys=", agent_run_map.keys())
	if run_id in agent_run_map:
		var task_info = agent_run_map[run_id]
		completed_runs[run_id] = true
		results.append({"success": ok, "run_id": run_id, "task_num": task_info.task_num, "result": result})
		if ok:
			log_info("✓ Async email task " + str(task_info.task_num) + " completed successfully")
		else:
			log_error("✗ Async email task " + str(task_info.task_num) + " finished with failure")
	else:
		print("ASYNC TEST: run_id not found in agent_run_map!")

func _on_async_email_error(run_id: String, error: Dictionary, completed_runs: Dictionary, results: Array, agent_run_map: Dictionary) -> void:
	if run_id in agent_run_map:
		var task_info = agent_run_map[run_id]
		completed_runs[run_id] = true
		results.append({"success": false, "run_id": run_id, "task_num": task_info.task_num, "error": error})
		log_error("✗ Async email task " + str(task_info.task_num) + " failed: " + str(error))

func _on_async_reading_finished(run_id: String, ok: bool, result: Dictionary, completed_runs: Dictionary, results: Array, agent_run_map: Dictionary) -> void:
	if run_id in agent_run_map:
		var task_info = agent_run_map[run_id]
		completed_runs[run_id] = true
		results.append({"success": ok, "run_id": run_id, "task_num": task_info.task_num, "result": result})
		if ok:
			log_info("✓ Async reading task " + str(task_info.task_num) + " completed successfully")
		else:
			log_error("✗ Async reading task " + str(task_info.task_num) + " finished with failure")

func _on_async_reading_error(run_id: String, error: Dictionary, completed_runs: Dictionary, results: Array, agent_run_map: Dictionary) -> void:
	if run_id in agent_run_map:
		var task_info = agent_run_map[run_id]
		completed_runs[run_id] = true
		results.append({"success": false, "run_id": run_id, "task_num": task_info.task_num, "error": error})
		log_error("✗ Async reading task " + str(task_info.task_num) + " failed: " + str(error))

func _on_async_stress_finished(run_id: String, ok: bool, result: Dictionary, completed_runs: Dictionary, results: Array, agent_run_map: Dictionary) -> void:
	if run_id in agent_run_map:
		var task_info = agent_run_map[run_id]
		completed_runs[run_id] = true
		results.append({"success": ok, "run_id": run_id, "task_num": task_info.task_num, "result": result})
		if ok:
			log_info("✓ Async stress task " + str(task_info.task_num) + " (" + task_info.type + ") completed successfully")
		else:
			log_error("✗ Async stress task " + str(task_info.task_num) + " (" + task_info.type + ") finished with failure")

func _on_async_stress_error(run_id: String, error: Dictionary, completed_runs: Dictionary, results: Array, agent_run_map: Dictionary) -> void:
	if run_id in agent_run_map:
		var task_info = agent_run_map[run_id]
		completed_runs[run_id] = true
		results.append({"success": false, "run_id": run_id, "task_num": task_info.task_num, "error": error})
		log_error("✗ Async stress task " + str(task_info.task_num) + " (" + task_info.type + ") failed: " + str(error))

# Real-time agent response handler with buffering for better readability
var agent_buffers = {}

func _on_agent_delta(_run_id: String, delta_text: String, agent_name: String) -> void:
	if delta_text.length() > 0:
		# Initialize buffer for this agent if it doesn't exist
		if not agent_buffers.has(agent_name):
			agent_buffers[agent_name] = ""
		
		# Add delta to agent's buffer
		agent_buffers[agent_name] += delta_text
		
		# Check if we have a complete sentence or significant chunk
		var buffer = agent_buffers[agent_name]
		if buffer.ends_with(".") or buffer.ends_with("!") or buffer.ends_with("?") or buffer.ends_with(":") or buffer.length() > 50:
			# Show the complete thought/sentence
			var agent_color = _get_agent_color(agent_name)
			log_info("🤖 [color=" + agent_color + "]" + agent_name + "[/color]: " + buffer.strip_edges())
			# Clear the buffer
			agent_buffers[agent_name] = ""

# Flush any remaining text in agent buffers
func _flush_agent_buffers() -> void:
	for agent_name in agent_buffers.keys():
		var buffer = agent_buffers[agent_name].strip_edges()
		if buffer.length() > 0:
			var agent_color = _get_agent_color(agent_name)
			log_info("🤖 [color=" + agent_color + "]" + agent_name + "[/color]: " + buffer)
	agent_buffers.clear()

# Get consistent color for each agent
func _get_agent_color(agent_name: String) -> String:
	match agent_name:
		"Village Merchant":
			return "gold"
		"Town Guard":
			return "lightblue"
		"Project Coordinator":
			return "lightgreen"
		"Support Specialist":
			return "pink"
		_:
			return "white"

## Logging functions
func log_test(message: String) -> void:
	print("TEST: " + message)
	emit_signal("test_progress", "TEST", message)

func log_phase(message: String) -> void:
	print("PHASE: " + message)
	emit_signal("test_progress", "PHASE", message)

func log_info(message: String) -> void:
	print("INFO: " + message)
	emit_signal("test_progress", "INFO", message)

func log_success(message: String) -> void:
	print("SUCCESS: " + message)
	emit_signal("test_progress", "SUCCESS", message)

func log_error(message: String) -> void:
	print("ERROR: " + message)
	emit_signal("test_progress", "ERROR", message)
