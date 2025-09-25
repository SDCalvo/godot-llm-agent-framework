extends RefCounted

## Message builder for OpenAI Responses API.
##
## This helper normalizes user/system/assistant messages with mixed multimodal
## content (text, images, audio) into a single OpenAI-ready message array.
##
## Most of the time, OpenAI's Responses API accepts multiple content parts in a
## single message. The methods here return an Array containing one Dictionary
## with the expected shape:
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
## - Text + image URL:
## 	var msgs = Message.user([], ["https://example.com/image.png"]) 
## - With audio bytes:
## 	var msgs = Message.user(["Transcribe this"], [], [wav_bytes])
##
## Options
## - image_detail (String): detail parameter for images (default: "auto").
## - audio_format (String): format field for audio parts (default: "wav").
##
## Notes
## - Images are currently accepted as URL strings; raw image resources are not
##   transformed here.
## - Audio must be provided as PackedByteArray; it will be base64-encoded.
## - This class returns an Array of one message; if a future constraint requires
##   splitting, the contract allows returning more than one.
class_name Message

const DEFAULT_IMAGE_DETAIL := "auto"
const DEFAULT_AUDIO_FORMAT := "wav"

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
## [param image_url] Optional image URL string.
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
## [param image_urls] Array of URL strings to include as input_image parts.
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

	# Append image items (URL strings)
	var image_detail := String(opts.get("image_detail", DEFAULT_IMAGE_DETAIL))
	for url in image_urls:
		if url == null or url == "":
			continue
		content.push_back({"type": "input_image", "image_url": url, "detail": image_detail})

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


