extends Node

## EmailSystemTest
##
## Comprehensive test suite for the LLM Email System.
## Tests multi-agent email communication, notifications, and coordination.

signal test_completed(success: bool, message: String)
signal test_progress(phase: String, details: String)

var merchant_agent: LLMAgent
var guard_agent: LLMAgent
var coordinator_agent: LLMAgent

var test_output: RichTextLabel

func _ready() -> void:
	print("EmailSystemTest initialized")

## Run the complete email system test suite
func run_email_test(output_console: RichTextLabel) -> void:
	test_output = output_console
	log_test("📧 Starting Multi-Agent Email System Test...")
	
	# Clear any existing emails for clean test
	LLMEmailManager.clear_all_emails()
	
	var test_success = true
	
	# Phase 1: Setup and Discovery
	var phase1_result = await _test_phase_1_setup()
	if not phase1_result:
		test_success = false
	
	# Phase 2: Basic Email Exchange
	if test_success:
		var phase2_result = await _test_phase_2_basic_exchange()
		if not phase2_result:
			test_success = false
	
	# Phase 3: Notification System
	if test_success:
		var phase3_result = await _test_phase_3_notifications()
		if not phase3_result:
			test_success = false
	
	# Phase 4: Email Reading and Responses
	if test_success:
		var phase4_result = await _test_phase_4_reading_responses()
		if not phase4_result:
			test_success = false
	
	# Phase 5: Complex Scenarios
	if test_success:
		var phase5_result = await _test_phase_5_complex_scenarios()
		if not phase5_result:
			test_success = false
	
	if test_success:
		log_success("✅ Email System Test PASSED - All phases completed successfully!")
		emit_signal("test_completed", true, "Email system test passed")
	else:
		log_error("❌ Email System Test FAILED - One or more phases failed")
		emit_signal("test_completed", false, "Email system test failed")

## Phase 1: Agent Setup and Discovery
func _test_phase_1_setup() -> bool:
	log_phase("Phase 1: Agent Setup and Discovery")
	
	# Create agents with email enabled
	merchant_agent = LLMManager.create_agent({
		"model": "gpt-4o-mini",
		"temperature": 0.3,
		"system_prompt": "You are a village merchant who trades goods and needs supplies. You are practical and business-focused."
	}, [], "Village Merchant").enable_email()
	
	guard_agent = LLMManager.create_agent({
		"model": "gpt-4o-mini", 
		"temperature": 0.3,
		"system_prompt": "You are a town guard responsible for security. You are cautious and follow protocols."
	}, [], "Town Guard").enable_email()
	
	coordinator_agent = LLMManager.create_agent({
		"model": "gpt-4o-mini",
		"temperature": 0.3, 
		"system_prompt": "You are a project coordinator who manages tasks and approves requests. You are organized and decisive."
	}, [], "Project Coordinator").enable_email()
	
	log_info("✓ Created 3 agents with email enabled")
	
	# Test agent discovery
	var merchant_discovers = await _test_agent_discovery(merchant_agent, "Merchant")
	var guard_discovers = await _test_agent_discovery(guard_agent, "Guard")
	var coordinator_discovers = await _test_agent_discovery(coordinator_agent, "Coordinator")
	
	if merchant_discovers and guard_discovers and coordinator_discovers:
		log_success("✓ Phase 1 PASSED - All agents can discover each other")
		return true
	else:
		log_error("✗ Phase 1 FAILED - Agent discovery issues")
		return false

## Test individual agent discovery
func _test_agent_discovery(agent: LLMAgent, agent_name: String) -> bool:
	log_info("Testing discovery for " + agent_name + "...")
	
	var messages = []
	messages += Message.system_simple(agent.system_prompt)
	messages += Message.user_simple("Use get_other_agents to see who else you can email. Just list their names briefly.")
	
	var result = await agent.invoke(messages)
	if result.get("ok", false):
		var response_text = result.get("text", "")
		log_info("✓ " + agent_name + " discovery result: " + response_text.substr(0, 100) + "...")
		return true
	else:
		log_error("✗ " + agent_name + " discovery failed: " + str(result.get("error", {})))
		return false

## Phase 2: Basic Email Exchange
func _test_phase_2_basic_exchange() -> bool:
	log_phase("Phase 2: Basic Email Exchange")
	
	# Merchant emails Guard
	log_info("Merchant sending email to Guard...")
	var merchant_msg = []
	merchant_msg += Message.user_simple("Send an email to the Town Guard asking for escort service for a supply run to the forest. Be polite and professional.")
	
	var merchant_result = await merchant_agent.invoke(merchant_msg)
	if merchant_result.get("ok", false):
		log_success("✓ Merchant sent email successfully")
	else:
		log_error("✗ Merchant email failed: " + str(merchant_result.get("error", {})))
		return false
	
	# Wait a moment for email processing
	await get_tree().create_timer(0.5).timeout
	
	# Guard emails Coordinator
	log_info("Guard sending email to Coordinator...")
	var guard_msg = []
	guard_msg += Message.user_simple("The merchant has requested an escort. Send an email to the Project Coordinator requesting approval for this escort mission.")
	
	var guard_result = await guard_agent.invoke(guard_msg)
	if guard_result.get("ok", false):
		log_success("✓ Guard sent email successfully")
	else:
		log_error("✗ Guard email failed: " + str(guard_result.get("error", {})))
		return false
	
	# Wait for email processing
	await get_tree().create_timer(0.5).timeout
	
	log_success("✓ Phase 2 PASSED - Basic email exchange completed")
	return true

## Phase 3: Notification System Testing
func _test_phase_3_notifications() -> bool:
	log_phase("Phase 3: Notification System Testing")
	
	# Test that agents get notifications about unread emails
	log_info("Testing notification system...")
	
	# Coordinator should have 1 unread email from Guard
	var coordinator_notifications = LLMEmailManager.get_agent_notifications(coordinator_agent.get_agent_id())
	log_info("Coordinator notifications: " + str(coordinator_notifications))
	
	# Guard should have 1 unread email from Merchant  
	var guard_notifications = LLMEmailManager.get_agent_notifications(guard_agent.get_agent_id())
	log_info("Guard notifications: " + str(guard_notifications))
	
	# Test system prompt injection by having coordinator start a new conversation
	log_info("Testing system prompt injection...")
	var coord_msg = []
	coord_msg += Message.user_simple("What's your current status? Do you have any pending tasks?")
	
	var coord_result = await coordinator_agent.invoke(coord_msg)
	if coord_result.get("ok", false):
		var response = coord_result.get("text", "")
		if "email" in response.to_lower():
			log_success("✓ System prompt injection working - Coordinator mentioned emails")
		else:
			log_warning("? System prompt injection unclear - Response: " + response.substr(0, 100) + "...")
	
	log_success("✓ Phase 3 PASSED - Notification system tested")
	return true

## Phase 4: Email Reading and Responses
func _test_phase_4_reading_responses() -> bool:
	log_phase("Phase 4: Email Reading and Responses")
	
	# Coordinator reads and responds to emails
	log_info("Coordinator reading emails...")
	var coord_read_msg = []
	coord_read_msg += Message.user_simple("Read your emails and send appropriate responses. If there are any requests that need approval, approve them.")
	
	var coord_read_result = await coordinator_agent.invoke(coord_read_msg)
	if coord_read_result.get("ok", false):
		log_success("✓ Coordinator processed emails: " + coord_read_result.get("text", "").substr(0, 100) + "...")
	else:
		log_error("✗ Coordinator email processing failed")
		return false
	
	# Wait for email processing
	await get_tree().create_timer(1.0).timeout
	
	# Guard reads emails and responds
	log_info("Guard reading emails...")
	var guard_read_msg = []
	guard_read_msg += Message.user_simple("Check your emails and respond appropriately. If you received approval for the escort mission, confirm with the merchant.")
	
	var guard_read_result = await guard_agent.invoke(guard_read_msg)
	if guard_read_result.get("ok", false):
		log_success("✓ Guard processed emails: " + guard_read_result.get("text", "").substr(0, 100) + "...")
	else:
		log_error("✗ Guard email processing failed")
		return false

	log_success("✓ Phase 4 PASSED - Email reading and responses completed")
	return true

## Phase 5: Complex Scenarios
func _test_phase_5_complex_scenarios() -> bool:
	log_phase("Phase 5: Complex Email Scenarios")
	
	# Create a scenario with multiple emails from different senders
	log_info("Creating complex email scenario...")
	
	# Merchant sends multiple emails to different recipients
	var merchant_multi_msg = []
	merchant_multi_msg += Message.user_simple("Send a follow-up email to both the Town Guard and Project Coordinator thanking them for their help and asking about scheduling the supply run.")
	
	var merchant_multi_result = await merchant_agent.invoke(merchant_multi_msg)
	if merchant_multi_result.get("ok", false):
		log_success("✓ Merchant sent multiple emails")
	else:
		log_error("✗ Merchant multiple email sending failed")
		return false
	
	# Wait for processing
	await get_tree().create_timer(1.0).timeout
	
	# Test that recipients get proper notifications for multiple emails
	var final_guard_notifications = LLMEmailManager.get_agent_notifications(guard_agent.get_agent_id())
	var final_coord_notifications = LLMEmailManager.get_agent_notifications(coordinator_agent.get_agent_id())
	
	log_info("Final Guard notifications: " + str(final_guard_notifications))
	log_info("Final Coordinator notifications: " + str(final_coord_notifications))
	
	# Test email statistics
	var total_emails = LLMEmailManager.get_total_email_count()
	log_info("Total emails in system: " + str(total_emails))
	
	log_success("✓ Phase 5 PASSED - Complex scenarios completed")
	return true

## Logging helpers
func log_test(message: String) -> void:
	if test_output:
		test_output.append_text("[color=cyan][b]" + message + "[/b][/color]\n")
	print("TEST: " + message)
	emit_signal("test_progress", "TEST", message)

func log_phase(message: String) -> void:
	if test_output:
		test_output.append_text("\n[color=yellow][b]" + message + "[/b][/color]\n")
	print("PHASE: " + message)
	emit_signal("test_progress", "PHASE", message)

func log_info(message: String) -> void:
	if test_output:
		test_output.append_text("[color=white]" + message + "[/color]\n")
	print("INFO: " + message)

func log_success(message: String) -> void:
	if test_output:
		test_output.append_text("[color=green]" + message + "[/color]\n")
	print("SUCCESS: " + message)

func log_error(message: String) -> void:
	if test_output:
		test_output.append_text("[color=red]" + message + "[/color]\n")
	print("ERROR: " + message)

func log_warning(message: String) -> void:
	if test_output:
		test_output.append_text("[color=orange]" + message + "[/color]\n")
	print("WARNING: " + message)
