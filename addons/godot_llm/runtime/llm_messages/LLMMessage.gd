extends RefCounted

## LLMMessage - Message builder for OpenAI Responses API.
##
## This helper normalizes user/system/assistant messages with mixed multimodal
## content (text, images, audio) into OpenAI-ready message arrays. Essential for
## building conversation history and handling multimodal inputs in games.
##
## The OpenAI Responses API accepts multiple content parts in a single message.
## The methods here return an Array containing one Dictionary with the expected shape:
##
## [{
## 	role = "user"|"assistant"|"system",
## 	content = [
## 		{ type = "input_text", text = "..." },
## 		{ type = "input_image", image_url = "https://...", detail = "auto" },
## 		{ type = "input_audio", audio = { format = "wav", data = <base64> } },
## 		...
## 	]
## }]
##
## Usage examples
## - Text only (array form):
## 	var msgs = Message.user(["Hello world"]) 
## - Text only (single-value helper):
## 	var msgs = Message.user_simple("Hello world")
## - Text + Base64 image (recommended for games):
## 	var base64_img = Message.image_to_base64(my_image, "png")
## 	var msgs = Message.user(["What's in this image?"], [base64_img]) 
## - Text + image URL (if using external resources):
## 	var msgs = Message.user(["Describe this"], ["https://example.com/image.png"]) 
## - With audio bytes:
## 	var msgs = Message.user(["Transcribe this"], [], [wav_bytes])
## - Building conversation history:
##   var history = []
##   history.append_array(Message.system_simple("You are a helpful NPC"))
##   history.append_array(Message.user_simple("What's in this image?", base64_img))
##   history.append_array(Message.assistant_simple("I see a magical sword."))
##
## Options
## - image_detail (String): detail parameter for images (default: "auto").
## - audio_format (String): format field for audio parts (default: "wav").
##
## Notes
## - Images can be provided as Base64 strings (recommended for games) or URL strings.
##   Base64 strings should start with "data:image/" for automatic detection.
## - Audio must be provided as PackedByteArray; it will be base64-encoded automatically.
## - This class returns an Array of one message; append to conversation history as needed.
##   splitting, the contract allows returning more than one.
class_name Message

const DEFAULT_IMAGE_DETAIL := "auto"
const DEFAULT_AUDIO_FORMAT := "wav"

## Helper to convert Godot Image to Base64 data URL for LLM consumption.
##
## [param image] Godot Image resource to convert.
## [param format] Image format ("png", "jpg", "webp"). Default: "png".
## [return] Base64 data URL string ready for OpenAI API.
static func image_to_base64(image: Image, format: String = "png") -> String:
	if image == null:
		return ""
	
	var bytes: PackedByteArray
	match format.to_lower():
		"jpg", "jpeg":
			bytes = image.save_jpg_to_buffer(0.9)
		"webp":
			bytes = image.save_webp_to_buffer()
		_: # Default to PNG
			bytes = image.save_png_to_buffer()
	
	var base64 := Marshalls.raw_to_base64(bytes)
	return "data:image/" + format.to_lower() + ";base64," + base64

static func user(texts: Array[String] = [], images: Array[String] = [], audios: Array[PackedByteArray] = [], opts: Dictionary = {}) -> Array:
	return make("user", texts, images, audios, opts)

static func system(texts: Array[String] = [], images: Array[String] = [], audios: Array[PackedByteArray] = [], opts: Dictionary = {}) -> Array:
	return make("system", texts, images, audios, opts)

static func assistant(texts: Array[String] = [], images: Array[String] = [], audios: Array[PackedByteArray] = [], opts: Dictionary = {}) -> Array:
	return make("assistant", texts, images, audios, opts)

# Convenience single-value helpers
## Build a user message from single values.
##
## [param text] Optional single text string.
## [param image_url] Optional image string (Base64 data URL or regular URL).
## [param audio] Optional audio bytes; will be base64-encoded as input_audio.
## [param opts] Optional options: image_detail, audio_format.
## [return] Array containing one OpenAI-ready message.
static func user_simple(text: String = "", image_url: String = "", audio: PackedByteArray = PackedByteArray(), opts: Dictionary = {}) -> Array:
	var texts: Array[String] = []
	if text != "":
		texts.append(text)
	var images: Array[String] = []
	if image_url != "":
		images.append(image_url)
	var audios: Array[PackedByteArray] = []
	if audio.size() > 0:
		audios.append(audio)
	return user(texts, images, audios, opts)

## Build a system message from single values.
## See [method user_simple] for parameter meanings.
static func system_simple(text: String = "", image_url: String = "", audio: PackedByteArray = PackedByteArray(), opts: Dictionary = {}) -> Array:
	var texts: Array[String] = []
	if text != "":
		texts.append(text)
	var images: Array[String] = []
	if image_url != "":
		images.append(image_url)
	var audios: Array[PackedByteArray] = []
	if audio.size() > 0:
		audios.append(audio)
	return system(texts, images, audios, opts)

## Build an assistant message from single values.
## See [method user_simple] for parameter meanings.
static func assistant_simple(text: String = "", image_url: String = "", audio: PackedByteArray = PackedByteArray(), opts: Dictionary = {}) -> Array:
	var texts: Array[String] = []
	if text != "":
		texts.append(text)
	var images: Array[String] = []
	if image_url != "":
		images.append(image_url)
	var audios: Array[PackedByteArray] = []
	if audio.size() > 0:
		audios.append(audio)
	return assistant(texts, images, audios, opts)

## Core builder that mixes text/image/audio content into a single message.
##
## [param role] One of "user", "assistant", "system".
## [param texts] Array of text strings to include as input_text parts.
## [param image_urls] Array of image strings (Base64 data URLs or regular URLs) to include as input_image parts.
## [param audios] Array of audio byte arrays to include as input_audio parts.
## [param opts] Optional options: image_detail (String), audio_format (String).
## [return] Array with one message Dictionary for OpenAI Responses API.
static func make(role: String, texts: Array[String], image_urls: Array[String], audios: Array[PackedByteArray], opts: Dictionary = {}) -> Array:
	var content: Array = []

	# Append text items
	for t in texts:
		if t == null:
			continue
		content.push_back({"type": "input_text", "text": t})

	# Append image items (Base64 data URLs or regular URLs)
	var image_detail := String(opts.get("image_detail", DEFAULT_IMAGE_DETAIL))
	for url in image_urls:
		if url == null or url == "":
			continue
		# OpenAI API expects images in image_url field regardless of Base64 or URL
		content.push_back({"type": "input_image", "image_url": {"url": url, "detail": image_detail}})

	# Append audio items (PackedByteArray)
	var audio_format := String(opts.get("audio_format", DEFAULT_AUDIO_FORMAT))
	for bytes in audios:
		if bytes.is_empty():
			continue
		var b64 := Marshalls.raw_to_base64(bytes)
		content.push_back({"type": "input_audio", "audio": {"format": audio_format, "data": b64}})

	return [{
		"role": role,
		"content": content,
	}]


