extends Node

## LLMEmailManager
##
## Simple email-based communication system for LLM agents. Provides a familiar
## email metaphor for agent-to-agent messaging with automatic notification injection
## into agent system prompts.
##
## Core Features:
## - Agent registration and discovery
## - Email sending with multiple recipients
## - Inbox filtering and read tracking
## - Automatic unread notifications in agent prompts
##
## Usage:
## ```gdscript
## # Register agents
## LLMEmailManager.register_agent("merchant", {"name": "Village Merchant", "role": "trader"})
## 
## # Agents get three tools automatically when email is enabled:
## # - get_other_agents: Discover available agents
## # - send_email: Send messages to one or more agents  
## # - read_emails: Read inbox (unread first, then recent)
## ```

# Email storage and management
var _emails: Array[Dictionary] = []
var _agent_registry: Dictionary = {}  # agent_id -> agent_info
var _unread_counts: Dictionary = {}   # agent_id -> unread_count
var _agent_contexts: Dictionary = {}  # agent_id -> Array[notification_string]

func _ready() -> void:
    print("LLMEmailManager initialized - Email system ready")

# === EMAIL OPERATIONS ===

## Send an email from one agent to one or more recipients
func send_email(from_id: String, recipients: Array, subject: String, content: String) -> Dictionary:
    var email = {
        "id": "email_" + str(Time.get_unix_time_from_system()) + "_" + str(randi()),
        "from": from_id,
        "to": recipients,
        "subject": subject,
        "content": content,
        "timestamp": Time.get_unix_time_from_system(),
        "read_by": [],
        "metadata": {}
    }
    
    _emails.append(email)
    
    # Update unread counts and add notifications for recipients
    for recipient in recipients:
        if recipient != from_id:  # Don't notify sender
            _unread_counts[recipient] = _unread_counts.get(recipient, 0) + 1
            _add_email_notification(recipient)
    
    print("Email sent from ", from_id, " to ", recipients, " - Subject: ", subject)
    return {"ok": true, "email_id": email.id}

## Read emails for a specific agent
func read_emails(agent_id: String, limit: int = 10, unread_only: bool = false) -> Dictionary:
    var agent_emails = []
    
    # Filter emails for this agent
    for email in _emails:
        if agent_id in email.to:
            if unread_only and agent_id in email.read_by:
                continue
            agent_emails.append(email)
    
    # Sort by timestamp (newest first)
    agent_emails.sort_custom(func(a, b): return a.timestamp > b.timestamp)
    
    # Limit results
    if limit > 0:
        agent_emails = agent_emails.slice(0, limit)
    
    # Mark as read
    for email in agent_emails:
        if agent_id not in email.read_by:
            email.read_by.append(agent_id)
    
    # Clear unread count
    _unread_counts[agent_id] = 0
    
    print("Agent ", agent_id, " read ", agent_emails.size(), " emails")
    return {"emails": agent_emails}

# === AGENT REGISTRY ===

## Register an agent in the email system
func register_agent(agent_id: String, agent_info: Dictionary) -> void:
    var info = agent_info.duplicate()
    info["id"] = agent_id
    if not info.has("name"):
        info["name"] = agent_id.capitalize()
    
    _agent_registry[agent_id] = info
    _unread_counts[agent_id] = 0
    
    print("Agent registered: ", agent_id, " (", info.get("name", agent_id), ")")

## Get list of available agents (excluding the requesting agent)
func get_available_agents(requesting_agent_id: String) -> Array:
    var agents = []
    for agent_id in _agent_registry:
        if agent_id != requesting_agent_id:  # Don't include self
            agents.append(_agent_registry[agent_id])
    return agents

# === NOTIFICATION SYSTEM ===

## Add email notification to agent's context for next prompt
func _add_email_notification(agent_id: String) -> void:
    var unread_count = _unread_counts.get(agent_id, 0)
    if unread_count > 0:
        # Get unread emails to extract sender information
        var unread_emails = []
        for email in _emails:
            if agent_id in email.to and agent_id not in email.read_by:
                unread_emails.append(email)
        
        # Create notification with sender information
        var notification = ""
        if unread_count == 1:
            var sender_name = _get_agent_display_name(unread_emails[0].from)
            notification = "You have 1 unread email from %s. Use read_emails to check it." % sender_name
        else:
            # For multiple emails, list unique senders
            var senders = {}
            for email in unread_emails:
                var sender_id = email.from
                var sender_name = _get_agent_display_name(sender_id)
                senders[sender_name] = true
            
            var sender_list = senders.keys()
            if sender_list.size() == 1:
                notification = "You have %d unread emails from %s. Use read_emails to check them." % [unread_count, sender_list[0]]
            elif sender_list.size() == 2:
                notification = "You have %d unread emails from %s and %s. Use read_emails to check them." % [unread_count, sender_list[0], sender_list[1]]
            else:
                var others_count = sender_list.size() - 2
                notification = "You have %d unread emails from %s, %s and %d other%s. Use read_emails to check them." % [
                    unread_count, sender_list[0], sender_list[1], others_count, "s" if others_count > 1 else ""
                ]
        
        _add_agent_context(agent_id, notification)

## Get pending notifications for an agent
func get_agent_notifications(agent_id: String) -> Array:
    return _agent_contexts.get(agent_id, [])

## Clear notifications for an agent (called after prompt injection)
func clear_agent_notifications(agent_id: String) -> void:
    _agent_contexts[agent_id] = []

## Add a notification to agent's context
func _add_agent_context(agent_id: String, context: String) -> void:
    if not _agent_contexts.has(agent_id):
        _agent_contexts[agent_id] = []
    _agent_contexts[agent_id].append(context)

## Get display name for an agent (fallback to ID if not registered)
func _get_agent_display_name(agent_id: String) -> String:
    var agent_info = _agent_registry.get(agent_id, {})
    return agent_info.get("name", agent_id)

# === UTILITY FUNCTIONS ===

## Get all recent emails (for game monitoring)
func get_all_recent_emails(limit: int = 50) -> Array:
    var recent = _emails.duplicate()
    recent.sort_custom(func(a, b): return a.timestamp > b.timestamp)
    if limit > 0:
        recent = recent.slice(0, limit)
    return recent

## Get unread count for an agent
func get_agent_unread_count(agent_id: String) -> int:
    return _unread_counts.get(agent_id, 0)

## Get total number of emails in the system
func get_total_email_count() -> int:
    return _emails.size()

## Clear all emails (for testing/reset)
func clear_all_emails() -> void:
    _emails.clear()
    _unread_counts.clear()
    _agent_contexts.clear()
    print("All emails cleared")