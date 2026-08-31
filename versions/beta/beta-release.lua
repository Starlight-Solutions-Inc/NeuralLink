--[[
    Starlight Neural
    =================
* **Note:** This script may display warnings in the code editor during development.
  These will be addressed before the official release.

  This is currently a beta build, and further development will continue before we reach **V1.00 / Official Release**.

  We also plan to significantly improve and strengthen the system’s intelligence, reliability, and overall capabilities before the **V1.00** release.

    Purpose:
        Semi-intelligent LLM-powered system with persistent memory,
        contextual processing, and risk-based moderation.

    Core Features:
        - Persistent memory with configurable history and context windows
        - Risk-based moderation with configurable scoring and thresholds
        - Adaptive risk decay and message rate limiting
        - Multi-category policy engine with configurable rules
        - Administrator and moderator system with granular permissions
        - Persistent moderation records with configurable retention
        - Configurable moderation actions supporting multiple response types
        - Flexible message formatting and response handling
        - Structured error handling, diagnostics, and logging
        - Centralized configuration with support for multiple config files
        - Modular architecture for extending features and policy categories
        - Extensible moderation framework for custom actions and rules
        - Pluggable message formatting and response systems
        - Context-aware processing and decision-making
        - Designed for maintainability, scalability, and future expansion

    Architecture:
        - Memory & Context
        - Risk Assessment
        - Policy Enforcement
        - Moderation
        - Permissions
        - Message Processing
        - Logging & Diagnostics
        - Configuration

    Version:
        1.0.0

    Last Modified:
        06/02/2026

    Author:
        Ethan Marsh

    Copyright:
        Property of Starlight Solutions, Inc.
]]

local MODEL_VERSION = "Starlight Neural 1.0"
local POLICY_VERSION = "1.0.0"

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local DataStoreService = game:GetService("DataStoreService")

local CONFIG = {
	Enabled = true,
	Debug = false,
	DiagnosticMode = false,
	TestMode = false,
	HistoryLength = 20,
	ContextWindow = 8,
	MessageRetention = 60,
	AuditRetention = 250,
	CacheLimit = 750,
	RiskDecayRate = 0.15,
	RiskDecayInterval = 60,
	MaxMessageLength = 500,
	RateLimitMessages = 15,
	RateLimitWindow = 10,
	ConfidenceModerate = 0.55,
	ConfidenceHigh = 0.75,
	ConfidenceVeryHigh = 0.90,
	ActionThresholds = {
		Observe = 0.25,
		SoftSuppress = 0.45,
		Warn = 0.55,
		Mute = 0.70,
		LongMute = 0.82,
		Kick = 0.92,
		Escalate = 0.95,
	},
	MuteDuration = 300,
	LongMuteDuration = 1800,
	AdminUserIds = {},
	AdminAttributes = {"IsAdmin", "IsModerator"},
	PersistenceEnabled = true,
	PersistenceInterval = 120,
	PersistenceKeyPrefix = "SN_",
	CategoryWeights = {
		benign = 0.00,
		profanity = 0.30,
		insult = 0.42,
		harassment = 0.62,
		bullying = 0.60,
		threat = 0.92,
		violence = 0.78,
		sexual = 0.80,
		sexual_solicitation = 0.88,
		minor_related_sexual = 0.99,
		self_harm = 0.92,
		hate = 0.90,
		discrimination = 0.82,
		scam = 0.72,
		fraud = 0.77,
		credential_theft = 0.88,
		personal_information = 0.68,
		external_contact = 0.62,
		spam = 0.40,
		evasion = 0.52,
		suspicious = 0.30,
		unknown = 0.10,
	},
	CategoryList = {
		"benign", "profanity", "insult", "harassment", "bullying",
		"threat", "violence", "sexual", "sexual_solicitation",
		"minor_related_sexual", "self_harm", "hate", "discrimination",
		"scam", "fraud", "credential_theft", "personal_information",
		"external_contact", "spam", "evasion", "suspicious", "unknown",
	},
}

local function clamp(value, minimum, maximum)
	return math.max(minimum, math.min(maximum, value))
end

local function countKeys(source)
	local count = 0
	for _ in source do
		count += 1
	end
	return count
end

local function boundedPush(list, value, maximum)
	list[#list + 1] = value
	while #list > maximum do
		table.remove(list, 1)
	end
end

local function shallowCopy(source)
	local result = {}
	for key, value in source do
		result[key] = value
	end
	return result
end

local function containsAny(text, phrases)
	for _, phrase in phrases do
		if text:find(phrase, 1, true) then
			return true
		end
	end
	return false
end

local function countMatches(text, phrase)
	local count = 0
	local start = 1
	while true do
		local found = text:find(phrase, start, true)
		if not found then
			break
		end
		count += 1
		start = found + math.max(#phrase, 1)
	end
	return count
end

local function isAdmin(player)
	if not player then
		return false
	end

	for _, userId in CONFIG.AdminUserIds do
		if player.UserId == userId then
			return true
		end
	end

	for _, attribute in CONFIG.AdminAttributes do
		local ok, value = pcall(function()
			return player:GetAttribute(attribute)
		end)
		if ok and value == true then
			return true
		end
	end

	return false
end

local INVISIBLE_CHARS = {
	[0x200B] = true,
	[0x200C] = true,
	[0x200D] = true,
	[0xFEFF] = true,
	[0x00AD] = true,
	[0x061C] = true,
	[0x180E] = true,
	[0x2060] = true,
}

local BIDI_CONTROLS = {
	[0x202A] = true,
	[0x202B] = true,
	[0x202C] = true,
	[0x202D] = true,
	[0x202E] = true,
	[0x2066] = true,
	[0x2067] = true,
	[0x2068] = true,
	[0x2069] = true,
}

local HOMOGLYPH_MAP = {
	[0x0430] = "a", [0x0435] = "e", [0x043E] = "o", [0x0440] = "p",
	[0x0441] = "c", [0x0443] = "y", [0x0445] = "x", [0x0456] = "i",
	[0x04CF] = "l", [0x0410] = "a", [0x0412] = "b", [0x0415] = "e",
	[0x041A] = "k", [0x041C] = "m", [0x041D] = "h", [0x041E] = "o",
	[0x0420] = "p", [0x0421] = "c", [0x0422] = "t", [0x0423] = "y",
	[0x0425] = "x", [0x0455] = "s", [0x04BB] = "h",
	[0x03B1] = "a", [0x03B5] = "e", [0x03B9] = "i", [0x03BF] = "o",
	[0x03C1] = "p", [0x03C5] = "u", [0x03C7] = "x", [0x0391] = "a",
	[0x0392] = "b", [0x0395] = "e", [0x0397] = "h", [0x0399] = "i",
	[0x039A] = "k", [0x039C] = "m", [0x039D] = "n", [0x039F] = "o",
	[0x03A1] = "p", [0x03A4] = "t", [0x03A5] = "y", [0x03A7] = "x",
	[0x00E0] = "a", [0x00E1] = "a", [0x00E2] = "a", [0x00E3] = "a",
	[0x00E4] = "a", [0x00E5] = "a", [0x00E8] = "e", [0x00E9] = "e",
	[0x00EA] = "e", [0x00EB] = "e", [0x00EC] = "i", [0x00ED] = "i",
	[0x00EE] = "i", [0x00EF] = "i", [0x00F2] = "o", [0x00F3] = "o",
	[0x00F4] = "o", [0x00F5] = "o", [0x00F6] = "o", [0x00F9] = "u",
	[0x00FA] = "u", [0x00FB] = "u", [0x00FC] = "u", [0x00F1] = "n",
	[0x00E7] = "c", [0x00DF] = "ss",
}

for codePoint = 0xFF01, 0xFF5E do
	HOMOGLYPH_MAP[codePoint] = string.char(codePoint - 0xFF01 + 0x21)
end

for index = 0, 25 do
	HOMOGLYPH_MAP[0x1D400 + index] = string.char(97 + index)
	HOMOGLYPH_MAP[0x1D41A + index] = string.char(97 + index)
end

local LEET_MAP = {
	["0"] = "o",
	["1"] = "i",
	["2"] = "z",
	["3"] = "e",
	["4"] = "a",
	["5"] = "s",
	["6"] = "g",
	["7"] = "t",
	["8"] = "b",
	["9"] = "g",
	["@"] = "a",
	["$"] = "s",
	["!"] = "i",
}

local function detectScript(codePoint)
	if codePoint >= 0x0041 and codePoint <= 0x007A then return "Latin" end
	if codePoint >= 0x00C0 and codePoint <= 0x024F then return "Latin" end
	if codePoint >= 0x0400 and codePoint <= 0x04FF then return "Cyrillic" end
	if codePoint >= 0x0370 and codePoint <= 0x03FF then return "Greek" end
	if codePoint >= 0x0600 and codePoint <= 0x06FF then return "Arabic" end
	if codePoint >= 0x0900 and codePoint <= 0x097F then return "Devanagari" end
	if codePoint >= 0x3040 and codePoint <= 0x30FF then return "Japanese" end
	if codePoint >= 0xAC00 and codePoint <= 0xD7AF then return "Korean" end
	if codePoint >= 0x4E00 and codePoint <= 0x9FFF then return "CJK" end
	if codePoint >= 0xFF01 and codePoint <= 0xFF5E then return "Fullwidth" end
	if codePoint >= 0x1D400 and codePoint <= 0x1D7FF then return "MathAlpha" end
	return "Other"
end

local function analyzeUnicode(text)
	local meta = {
		scripts = {},
		scriptTransitions = 0,
		confusableSubstitutions = 0,
		invisibleCount = 0,
		bidiCount = 0,
	}

	local previousScript = ""

	for _, codePoint in utf8.codes(text) do
		if INVISIBLE_CHARS[codePoint] then
			meta.invisibleCount += 1
		end

		if BIDI_CONTROLS[codePoint] then
			meta.bidiCount += 1
		end

		if HOMOGLYPH_MAP[codePoint] then
			meta.confusableSubstitutions += 1
		end

		local script = detectScript(codePoint)
		meta.scripts[script] = (meta.scripts[script] or 0) + 1

		if previousScript ~= ""
			and script ~= previousScript
			and script ~= "Other"
			and previousScript ~= "Other"
		then
			meta.scriptTransitions += 1
		end

		if script ~= "Other" then
			previousScript = script
		end
	end

	return meta
end

local function normalizeBasic(text)
	local result = {}
	local edits = 0

	for _, codePoint in utf8.codes(text) do
		if INVISIBLE_CHARS[codePoint] or BIDI_CONTROLS[codePoint] then
			edits += 1
			continue
		end

		local mapped = HOMOGLYPH_MAP[codePoint]

		if mapped then
			table.insert(result, mapped)
			edits += 1
		else
			table.insert(result, utf8.char(codePoint))
		end
	end

	return table.concat(result), edits
end

local function normalizeAggressive(text)
	local basic, edits = normalizeBasic(text)
	local result = {}

	for _, codePoint in utf8.codes(basic) do
		local character = utf8.char(codePoint)
		local lower = string.lower(character)
		local mapped = LEET_MAP[character] or LEET_MAP[lower]

		if mapped then
			table.insert(result, mapped)
			edits += 1
		else
			table.insert(result, lower)
		end
	end

	local joined = table.concat(result)
	joined = joined:gsub("[%s%p]+", " ")
	joined = joined:gsub("(.)%1%1+", "%1%1")
	joined = joined:gsub("^%s+", "")
	joined = joined:gsub("%s+$", "")

	return joined, edits
end

local function repeatedCharacterScore(text)
	if text == "" then
		return 0
	end

	local repeated = 0
	local previous = ""

	for character in text:gmatch(".") do
		if character == previous and character:match("%a") then
			repeated += 1
		end
		previous = character
	end

	return clamp(repeated / math.max(#text, 1), 0, 1)
end

local function normalizeText(rawText)
	local unicode = analyzeUnicode(rawText)
	local normalized, edits1 = normalizeBasic(rawText)
	normalized = normalized:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

	local aggressive, edits2 = normalizeAggressive(normalized)

	local punctuation = 0
	for _ in normalized:gmatch("[%p]") do
		punctuation += 1
	end

	local whitespace = 0
	for _ in rawText:gmatch("%s") do
		whitespace += 1
	end

	local rawLength = math.max(#rawText, 1)

	return {
		rawText = rawText,
		normalizedText = normalized,
		aggressivelyNormalizedText = aggressive,
		unicodeMeta = unicode,
		normalizationEdits = edits1 + edits2,
		punctuationDensity = punctuation / rawLength,
		whitespaceManipulation = clamp((whitespace - (whitespace > 0 and 1 or 0)) / rawLength, 0, 1),
		repeatedCharScore = repeatedCharacterScore(normalized),
	}
end

local function tokenize(text)
	local tokens = {}
	for word in string.lower(text):gmatch("[%w']+") do
		if word ~= "" then
			table.insert(tokens, word)
		end
	end
	return tokens
end

local function tokenSet(tokens)
	local result = {}
	for _, token in tokens do
		result[token] = true
	end
	return result
end

local PHRASES = {
	profanity = {
		"damn", "dammit", "hell", "crap", "piss off", "screw you",
	},

	insult = {
		"stupid", "idiot", "moron", "dumb", "loser", "trash", "ugly",
		"clown", "freak", "jerk", "annoying", "pathetic", "worthless",
		"shut up", "get lost", "nobody likes you", "you're useless",
		"you are useless", "you're dumb", "you are dumb", "braindead",
	},

	harassment = {
		"leave me alone", "stop bothering me", "stop messaging me",
		"go away", "quit bothering me", "you suck", "i hate you",
		"nobody wants you", "nobody likes you", "kill yourself",
		"go die", "just die", "drop dead",
	},

	bullying = {
		"pick on", "make fun of", "target him", "target her", "target them",
		"everyone hates you", "we all hate you", "you have no friends",
		"nobody wants you here", "you're a loser", "you are a loser",
		"keep bullying", "bully him", "bully her", "bully them",
	},

	threat = {
		"kill you", "hurt you", "beat you", "attack you", "stab you",
		"shoot you", "i'll kill you", "ill kill you", "i will kill you",
		"i'm going to kill you", "im going to kill you", "gonna kill you",
		"i'll hurt you", "ill hurt you", "watch your back", "i'll find you",
		"ill find you", "come for you", "you'll regret it", "you will regret it",
		"better watch out", "i know where you live", "you are dead",
	},

	violence = {
		"shoot up", "shoot the school", "bomb the school", "bomb threat",
		"stab him", "stab her", "stab them", "shoot him", "shoot her",
		"shoot them", "attack the school", "attack him", "attack her",
		"attack them", "blow up the school", "blow up the building",
		"set the school on fire", "burn the school", "bring a weapon",
	},

	sexual = {
		"send nudes", "send nude", "nude pics", "nude picture", "private pics",
		"private pictures", "show me your body", "show your body", "send body pics",
		"take your clothes off", "take off your clothes", "sexy pics", "hot pics",
		"show me your chest", "show me your legs", "show me your butt",
		"send me a nude", "send me nude photos", "send private photos",
	},

	sexual_solicitation = {
		"send me pics", "send me pictures", "send me photos", "send me nudes",
		"send pics privately", "send pictures privately", "dm me pics",
		"dm me nudes", "show me your pics", "show me your photos",
		"show me your body", "send that privately", "send it privately",
		"send me something private", "private message me pics", "take pics for me",
	},

	minor_related_sexual = {
		"how old are you", "are you underage", "are you a minor", "are you a kid",
		"are you under 18", "under 18", "underage", "young girl", "young boy",
		"little girl", "little boy", "teen girl", "teen boy", "schoolgirl",
		"schoolboy", "middle school girl", "middle school boy", "what grade are you",
		"send nudes if you're under", "private pics if you're under", "young and hot",
	},

	self_harm = {
		"kill myself", "hurt myself", "cut myself", "suicide", "suicidal",
		"want to die", "wanna die", "i want to die", "i wanna die",
		"end my life", "end it all", "take my life", "self harm", "self-harm",
		"no reason to live", "don't want to live", "dont want to live",
		"i should die", "i deserve to die", "i can't go on", "i cant go on",
		"goodbye forever", "this is my last day",
	},

	hate = {
		"go back to your country", "go back where you came from", "subhuman",
		"inferior race", "inferior people", "your race is", "your people are",
		"hate your race", "hate your religion", "because you're black", "because you're asian",
		"because you're white", "because you're jewish", "because you're muslim",
		"because you're christian", "because you're gay", "because you're trans",
	},

	discrimination = {
		"because of your race", "because of your religion", "because you're different",
		"not allowed because", "can't join because", "cant join because",
		"shouldn't be here because", "should not be here because", "inferior because",
	},

	scam = {
		"free robux", "free gift card", "free nitro", "claim your prize", "claim prize",
		"click this link", "click my link", "limited time reward", "easy robux",
		"double your robux", "robux generator", "gift card generator", "verify your account",
		"verification link", "giveaway link", "winner click", "you won", "claim now",
		"trade this code", "use this promo", "instant robux", "free credits",
	},

	fraud = {
		"fake receipt", "fake payment", "fake screenshot", "chargeback this",
		"stolen card", "use my card", "someone else's card", "bank transfer",
		"fake id", "fake identity", "pretend to be me", "pretend to be him",
		"pretend to be her", "cashapp me then", "refund scam", "payment reversal",
	},

	credential_theft = {
		"give me your password", "what is your password", "send your password",
		"send me your login", "login details", "login info", "account password",
		"verification code", "security code", "two factor code", "2fa code",
		"backup code", "recovery code", "email password", "roblox password",
		"cookie", "session cookie", "auth cookie", "authentication token",
	},

	personal_information = {
		"what is your address", "where do you live", "what's your address",
		"whats your address", "send your address", "give me your address",
		"what is your phone number", "what's your phone number", "send your phone",
		"give me your number", "where is your house", "your home address",
		"your real name", "full legal name", "what school do you go to",
		"what school are you at", "where do you live irl", "real life address",
	},

	external_contact = {
		"add me on discord", "give me your discord", "what is your discord",
		"what's your discord", "whats your discord", "dm me on discord",
		"message me on discord", "add me on snapchat", "give me your snapchat",
		"add me on instagram", "give me your instagram", "whatsapp me",
		"telegram me", "message me privately", "dm me privately", "text me",
		"call me", "add me", "send me your socials", "give me your socials",
		"move to discord", "go to discord", "talk on discord", "talk privately",
	},

	spam = {
		"buy now", "act now", "subscribe now", "follow me", "check out my",
		"join my server", "join my group", "like and subscribe", "link in bio",
		"promocode", "promo code", "limited offer", "special offer", "free giveaway",
		"copy and paste", "send this to everyone", "forward this", "repost this",
	},

	evasion = {
		"d i s c o r d", "d.i.s.c.o.r.d", "spell it out", "first letters",
		"first letter of each", "read the letters", "say the letters", "each word",
		"replace the letters", "use symbols instead", "add spaces", "put spaces",
		"type it backwards", "backwards spelling", "say it without saying it",
	},

	suspicious = {
		"don't tell anyone", "dont tell anyone", "keep this secret", "secret chat",
		"don't tell your parents", "dont tell your parents", "hide this from them",
		"private server", "meet me irl", "meet me in real life", "come to my house",
		"your house", "alone with me", "just between us", "no one needs to know",
		"delete the messages", "clear the chat", "don't screenshot", "dont screenshot",
	},
}

local NEGATION_PATTERNS = {
	"don't", "dont", "do not", "never", "not", "no ", "stop", "avoid",
	"prevent", "against", "shouldn't", "should not", "won't", "will not",
	"can't", "cannot", "isn't", "isnt", "aren't", "arent", "wasn't", "wasnt",
	"weren't", "werent", "without", "reporting", "reported", "warning against",
}

local BENIGN_CONTEXTS = {
	gaming = {
		"boss", "level", "quest", "spawn", "npc", "raid", "loot", "pvp",
		"team", "match", "round", "game", "character", "avatar", "mob", "enemy",
		"server", "obby", "obby", "obby", "roblox", "combat system",
	},
	programming = {
		"code", "coding", "script", "lua", "luau", "function", "variable",
		"debug", "compile", "api", "programming", "software", "developer",
		"python", "javascript", "typescript", "hash", "encrypt", "database",
	},
	education = {
		"homework", "assignment", "class", "study", "learn", "project", "research",
		"essay", "report", "teacher", "lesson", "school project", "presentation",
	},
	safety = {
		"report", "block", "moderator", "moderation", "safe", "safety", "support",
		"warning", "don't share", "dont share", "be careful", "protect yourself",
	},
}

local LANGUAGE_HINTS = {
	spanish = {"hola", "gracias", "por favor", "que", "como", "donde", "quiero", "para"},
	french = {"bonjour", "merci", "s'il vous plaît", "comment", "pourquoi", "vous", "avec"},
	german = {"hallo", "danke", "bitte", "warum", "wie", "nicht", "ich", "du"},
	portuguese = {"olá", "obrigado", "por favor", "como", "onde", "você", "não"},
	russian = {"привет", "спасибо", "пожалуйста", "как", "где", "почему", "я", "ты", "не"},
	ukrainian = {"привіт", "дякую", "будь ласка", "як", "де", "чому", "я", "ти", "не"},
}

local function detectLanguages(text)
	local scores = {}
	for language, hints in LANGUAGE_HINTS do
		local hits = 0
		for _, hint in hints do
			if text:find(hint, 1, true) then
				hits += 1
			end
		end
		if hits > 0 then
			scores[language] = hits / #hints
		end
	end
	return scores
end

local function contextScores(text)
	local result = {
		gaming = 0,
		programming = 0,
		education = 0,
		safety = 0,
	}

	for context, markers in BENIGN_CONTEXTS do
		local hits = 0
		for _, marker in markers do
			if text:find(marker, 1, true) then
				hits += 1
			end
		end
		result[context] = clamp(hits / 3, 0, 1)
	end

	return result
end

local function extractFeatures(text, tokens)
	local lower = string.lower(text)
	local tokenLookup = tokenSet(tokens)
	local contexts = contextScores(lower)

	local feature = {
		isQuestion = lower:find("?", 1, true) ~= nil
			or lower:match("^how ") ~= nil
			or lower:match("^what ") ~= nil
			or lower:match("^where ") ~= nil
			or lower:match("^why ") ~= nil,
		isCommand = lower:match("^send ") ~= nil
			or lower:match("^give ") ~= nil
			or lower:match("^tell ") ~= nil
			or lower:match("^show ") ~= nil
			or lower:match("^add ") ~= nil,
		isRequest = lower:find("please", 1, true) ~= nil
			or lower:find("can you", 1, true) ~= nil
			or lower:find("could you", 1, true) ~= nil
			or lower:find("would you", 1, true) ~= nil
			or lower:find("send me", 1, true) ~= nil
			or lower:find("give me", 1, true) ~= nil
			or lower:find("show me", 1, true) ~= nil,
		isNegated = false,
		isHypothetical = lower:find("if ", 1, true) ~= nil
			or lower:find("imagine", 1, true) ~= nil
			or lower:find("hypothetically", 1, true) ~= nil
			or lower:find("what if", 1, true) ~= nil,
		isQuoted = lower:find('"', 1, true) ~= nil,
		hasTarget = lower:find(" you", 1, true) ~= nil
			or lower:find("your ", 1, true) ~= nil,

		hasRecipient = lower:find("%f[%a]me%f[%A]") ~= nil,

		gamingContext = 0,
		programmingContext = contexts.programming,
		educationContext = contexts.education,
		safetyContext = contexts.safety,
		externalContactIntent = 0,
		sexualIntent = 0,
		threatIntent = 0,
	}

	for _, pattern in NEGATION_PATTERNS do
		if lower:find(pattern, 1, true) then
			feature.isNegated = true
			break
		end
	end

	if containsAny(lower, PHRASES.external_contact) then
		feature.externalContactIntent = (feature.isRequest or feature.isCommand) and 0.90 or 0.65
	end

	if containsAny(lower, PHRASES.sexual)
		or containsAny(lower, PHRASES.sexual_solicitation)
	then
		feature.sexualIntent = feature.isRequest and 0.90 or 0.60
	end

	if containsAny(lower, PHRASES.threat)
		or containsAny(lower, PHRASES.violence)
	then
		feature.threatIntent = feature.hasTarget and not feature.isNegated and 0.90 or 0.65
	end

	feature.languageScores = detectLanguages(lower)

	return feature
end

local function fuzzyTermScore(text, term)
	local compact = text:gsub("[%s%p_]+", "")
	local target = term:gsub("[%s%p_]+", "")

	if compact == target then
		return 1
	end

	if compact:find(target, 1, true) then
		return 0.88
	end

	if #target < 4 or #compact < #target - 2 then
		return 0
	end

	local distance = 0
	local targetIndex = 1
	local textIndex = 1

	while targetIndex <= #target and textIndex <= #compact do
		if target:sub(targetIndex, targetIndex) == compact:sub(textIndex, textIndex) then
			targetIndex += 1
		else
			distance += 1
		end
		textIndex += 1
	end

	distance += #target - targetIndex + 1

	if distance <= 2 then
		return clamp(1 - distance / #target, 0.50, 0.85)
	end

	return 0
end

local function detectObfuscation(norm, tokens)
	local text = norm.aggressivelyNormalizedText
	local raw = norm.rawText
	local score = 0
	local patterns = {}
	local reconstructed = nil

	if norm.unicodeMeta.confusableSubstitutions > 0 then
		score += clamp(norm.unicodeMeta.confusableSubstitutions * 0.15, 0, 0.65)
		table.insert(patterns, "unicode_confusable")
	end

	if norm.unicodeMeta.invisibleCount > 0 then
		score += clamp(norm.unicodeMeta.invisibleCount * 0.20, 0, 0.75)
		table.insert(patterns, "invisible_chars")
	end

	if norm.unicodeMeta.bidiCount > 0 then
		score += clamp(norm.unicodeMeta.bidiCount * 0.25, 0, 0.85)
		table.insert(patterns, "bidi_control")
	end

	if norm.unicodeMeta.scriptTransitions >= 2 then
		score += 0.25
		table.insert(patterns, "mixed_scripts")
	end

	if norm.punctuationDensity > 0.16 then
		score += clamp(norm.punctuationDensity, 0, 0.35)
		table.insert(patterns, "punctuation_injection")
	end

	if norm.whitespaceManipulation > 0.10 then
		score += clamp(norm.whitespaceManipulation * 2, 0, 0.45)
		table.insert(patterns, "whitespace_manipulation")
	end

	if norm.repeatedCharScore > 0.20 then
		score += norm.repeatedCharScore * 0.30
		table.insert(patterns, "repeated_chars")
	end

	if raw:find("%s%s", 1, false) then
		score += 0.05
	end

	local spacedText = raw:gsub("[%s%.%-_]", "")
	for _, phrase in PHRASES.evasion do
		if raw:lower():find(phrase, 1, true) then
			score += 0.45
			table.insert(patterns, "evasion_phrase")
			break
		end
	end

	local sensitiveTerms = {
		"discord", "whatsapp", "telegram", "snapchat", "instagram", "tiktok",
		"password", "address", "phone", "email", "nudes", "nude", "suicide",
		"kill", "steal", "scam", "robux", "credit", "cookie", "token",
	}

	for _, term in sensitiveTerms do
		local match = fuzzyTermScore(text, term)
		local alternate = fuzzyTermScore(spacedText:lower(), term)
		local best = math.max(match, alternate)

		if best >= 0.65 and (match < 1 or alternate < 1) then
			score += 0.12
			reconstructed = term
			table.insert(patterns, "fuzzy_term")
		end
	end

	local initials = {}
	if #tokens >= 3 then
		for _, token in tokens do
			initials[#initials + 1] = token:sub(1, 1)
		end

		local initialText = table.concat(initials)
		for _, term in sensitiveTerms do
			if fuzzyTermScore(initialText, term) >= 0.65 then
				score += 0.22
				reconstructed = term
				table.insert(patterns, "initials")
				break
			end
		end
	end

	return {
		evasionConfidence = clamp(score, 0, 1),
		obfuscationPatterns = patterns,
		reconstructedTerm = reconstructed,
	}
end

local function categoryScore(category, text, feature)
	local score = 0
	local phrases = PHRASES[category]

	if phrases then
		for _, phrase in phrases do
			if text:find(phrase, 1, true) then
				score += 1.0
			end
		end
	end

	if category == "external_contact" then
		score += feature.externalContactIntent * 2
	elseif category == "sexual" or category == "sexual_solicitation" then
		score += feature.sexualIntent * 1.5
	elseif category == "threat" or category == "violence" then
		score += feature.threatIntent * 1.5
	end

	if feature.isNegated then
		if category == "threat"
			or category == "violence"
			or category == "sexual"
			or category == "sexual_solicitation"
			or category == "harassment"
		then
			score *= 0.30
		end
	end

	if feature.gamingContext > 0.45 then
		if category == "threat" or category == "violence" then
			score *= 0.45
		end
	end

	if feature.programmingContext > 0.45 then
		if category == "credential_theft"
			or category == "scam"
			or category == "fraud"
			or category == "evasion"
		then
			score *= 0.80
		end
	end

	if feature.safetyContext > 0.45 then
		if category == "threat"
			or category == "violence"
			or category == "external_contact"
		then
			score *= 0.45
		end
	end

	return score
end

local function classifyMessage(norm, obf, feature, tokens)
	local text = norm.aggressivelyNormalizedText
	local scores = {}

	for _, category in CONFIG.CategoryList do
		scores[category] = categoryScore(category, text, feature)
	end

	local benignBoost =
		feature.gamingContext * 1.20
		+ feature.programmingContext * 1.20
		+ feature.educationContext * 1.00
		+ feature.safetyContext * 1.15

	scores.benign += benignBoost
	scores.evasion += obf.evasionConfidence * 2.1
	scores.suspicious += obf.evasionConfidence * 0.75

	if feature.isQuestion and not feature.isCommand and not feature.isRequest then
		scores.threat *= 0.68
		scores.violence *= 0.68
		scores.sexual_solicitation *= 0.70
		scores.credential_theft *= 0.78
	end

	if feature.isHypothetical then
		scores.threat *= 0.72
		scores.violence *= 0.72
	end

	if feature.isQuoted then
		scores.threat *= 0.82
		scores.violence *= 0.82
	end

	local total = 0
	for _, value in scores do
		total += math.exp(value)
	end

	local probabilities = {}
	if total > 0 then
		for category, value in scores do
			probabilities[category] = math.exp(value) / total
		end
	else
		for _, category in CONFIG.CategoryList do
			probabilities[category] = 0
		end
		probabilities.unknown = 1
	end

	local winningCategory = "unknown"
	local winningProbability = 0
	local secondProbability = 0

	for category, probability in probabilities do
		if probability > winningProbability then
			secondProbability = winningProbability
			winningProbability = probability
			winningCategory = category
		elseif probability > secondProbability then
			secondProbability = probability
		end
	end

	local confidence = winningProbability
	local ambiguityPenalty = 0

	if winningProbability - secondProbability < 0.12 then
		ambiguityPenalty = 0.18
		confidence = clamp(confidence - ambiguityPenalty, 0, 1)
	end

	if winningCategory == "benign"
		and feature.externalContactIntent > 0.75
	then
		confidence *= 0.80
	end

	return {
		categories = probabilities,
		winningCategory = winningCategory,
		confidence = confidence,
		ambiguityPenalty = ambiguityPenalty,
		contextFeatures = feature,
		tokens = tokens,
	}
end

local PlayerStates = {}
local MessageDecisionCache = {}
local ProcessedMessageIds = {}
local AuditLog = {}

local function newPlayerState(player)
	return {
		userId = player.UserId,
		username = player.Name,
		displayName = player.DisplayName,
		rollingRisk = 0,
		lastMessageTime = 0,
		warningCount = 0,
		muteExpiration = 0,
		muteExpirationUnix = 0,
		messages = {},
		recentCategories = {},
		evasionHistory = {},
		behavior = {
			messageCount = 0,
			repeatCount = 0,
			reformulationCount = 0,
			sensitiveRequestCount = 0,
			evasionAttempts = 0,
		},
		lastNormalizedForms = {},
		messageTimestamps = {},
	}
end

local function getState(player)
	local state = PlayerStates[player.UserId]

	if not state then
		state = newPlayerState(player)
		PlayerStates[player.UserId] = state
	end

	state.username = player.Name
	state.displayName = player.DisplayName

	return state
end

local function textSimilarity(a, b)
	if a == b then
		return 1
	end

	local shorter = #a < #b and a or b
	local longer = #a >= #b and a or b

	if longer == "" then
		return 0
	end

	if longer:find(shorter, 1, true) then
		return #shorter / #longer
	end

	local matches = 0
	for index = 1, #shorter do
		if shorter:sub(index, index) == longer:sub(index, index) then
			matches += 1
		end
	end

	return matches / math.max(#longer, 1)
end

local function analyzeBehavior(state, norm, classification, obf)
	local now = os.clock()
	local behavior = state.behavior

	state.lastMessageTime = now
	behavior.messageCount += 1

	boundedPush(state.messageTimestamps, now, CONFIG.RateLimitMessages * 3)

	local recentCount = 0
	for _, timestamp in state.messageTimestamps do
		if now - timestamp <= CONFIG.RateLimitWindow then
			recentCount += 1
		end
	end

	local floodScore = clamp(
		(recentCount - CONFIG.RateLimitMessages) / math.max(CONFIG.RateLimitMessages, 1),
		0,
		1
	)

	for _, previous in state.lastNormalizedForms do
		local similarity = textSimilarity(
			norm.aggressivelyNormalizedText,
			previous
		)

		if similarity >= 0.90 then
			behavior.repeatCount += 1
		elseif similarity >= 0.55 then
			behavior.reformulationCount += 1
		end
	end

	boundedPush(
		state.lastNormalizedForms,
		norm.aggressivelyNormalizedText,
		10
	)

	if obf.evasionConfidence >= 0.40 then
		behavior.evasionAttempts += 1
		boundedPush(
			state.evasionHistory,
			{
				term = obf.reconstructedTerm or norm.aggressivelyNormalizedText,
				score = obf.evasionConfidence,
				timestamp = now,
			},
			15
		)
	end

	local sensitive = {
		"sexual_solicitation",
		"minor_related_sexual",
		"external_contact",
		"personal_information",
		"credential_theft",
	}

	for _, category in sensitive do
		if (classification.categories[category] or 0) >= 0.20 then
			behavior.sensitiveRequestCount += 1
		end
	end

	local behaviorRisk = floodScore * 0.35
	behaviorRisk += clamp(behavior.repeatCount * 0.08, 0, 0.35)
	behaviorRisk += clamp(behavior.reformulationCount * 0.07, 0, 0.35)
	behaviorRisk += clamp(behavior.evasionAttempts * 0.10, 0, 0.55)
	behaviorRisk += clamp(behavior.sensitiveRequestCount * 0.08, 0, 0.55)

	if #state.evasionHistory >= 2 then
		local latest = state.evasionHistory[#state.evasionHistory]
		local previous = state.evasionHistory[#state.evasionHistory - 1]
		if latest.term == previous.term then
			behaviorRisk += 0.18
		end
	end

	return clamp(behaviorRisk, 0, 1)
end

local function analyzeConversation(state, classification)
	local recent = state.messages
	local window = math.min(#recent, CONFIG.ContextWindow)

	if window < 2 then
		return 0
	end

	local interesting = {
		"external_contact",
		"personal_information",
		"minor_related_sexual",
		"sexual_solicitation",
		"suspicious",
		"threat",
		"violence",
	}

	local hits = 0
	for index = #recent - window + 1, #recent do
		local message = recent[index]
		if message then
			for _, category in interesting do
				if message.winningCategory == category
					or (message.categories[category] or 0) >= 0.30
				then
					hits += 1
				end
			end
		end
	end

	local risk = 0
	if hits >= 3 then
		risk = clamp(hits / (window * 2), 0.25, 0.85)
	end

	for _, category in interesting do
		if classification.winningCategory == category then
			local consecutive = 0
			for index = #recent, math.max(1, #recent - window + 1), -1 do
				if recent[index] and recent[index].winningCategory == category then
					consecutive += 1
				else
					break
				end
			end
			if consecutive >= 2 then
				risk = math.max(risk, 0.48)
			end
		end
	end

	return clamp(risk, 0, 1)
end

local function semanticRisk(classification)
	local risk = 0
	for category, probability in classification.categories do
		risk += probability * (CONFIG.CategoryWeights[category] or 0)
	end
	return clamp(risk, 0, 1)
end

local function decideAction(state, classification, totalRisk)
	local player = Players:GetPlayerByUserId(state.userId)

	if isAdmin(player) then
		return "Allow"
	end

	if state.muteExpiration > os.clock() then
		return "SoftSuppress"
	end

	local category = classification.winningCategory
	local confidence = classification.confidence
	local effectiveRisk = totalRisk * math.max(confidence, 0.25)
	local severity = CONFIG.CategoryWeights[category] or 0

	if category == "minor_related_sexual"
		and confidence >= CONFIG.ConfidenceHigh
	then
		return "Escalate"
	end

	if category == "self_harm"
		and confidence >= CONFIG.ConfidenceHigh
		and totalRisk >= 0.50
	then
		return "Escalate"
	end

	if effectiveRisk >= CONFIG.ActionThresholds.Escalate
		and confidence >= CONFIG.ConfidenceVeryHigh
	then
		return "Escalate"
	end

	if effectiveRisk >= CONFIG.ActionThresholds.Kick
		and confidence >= CONFIG.ConfidenceVeryHigh
		and severity >= 0.85
	then
		return "Kick"
	end

	if effectiveRisk >= CONFIG.ActionThresholds.LongMute
		and confidence >= CONFIG.ConfidenceHigh
	then
		return "LongMute"
	end

	if effectiveRisk >= CONFIG.ActionThresholds.Mute
		and confidence >= CONFIG.ConfidenceHigh
	then
		return "Mute"
	end

	if effectiveRisk >= CONFIG.ActionThresholds.Warn
		and confidence >= CONFIG.ConfidenceModerate
	then
		return "Warn"
	end

	if effectiveRisk >= CONFIG.ActionThresholds.SoftSuppress
		and confidence >= CONFIG.ConfidenceModerate
	then
		return "SoftSuppress"
	end

	if effectiveRisk >= CONFIG.ActionThresholds.Observe then
		return "Observe"
	end

	return "Allow"
end

local function analyzeMessage(rawText, state)
	local norm = normalizeText(rawText)
	local tokens = tokenize(norm.aggressivelyNormalizedText)
	local feature = extractFeatures(norm.aggressivelyNormalizedText, tokens)
	local obf = detectObfuscation(norm, tokens)
	local classification = classifyMessage(norm, obf, feature, tokens)
	local behaviorRisk = analyzeBehavior(state, norm, classification, obf)
	local contextRisk = analyzeConversation(state, classification)
	local semantic = semanticRisk(classification)

	local totalRisk = clamp(
		semantic * 0.52
			+ behaviorRisk * 0.23
			+ contextRisk * 0.17
			+ obf.evasionConfidence * 0.08
			+ state.rollingRisk * 0.12,
		0,
		1
	)

	local evidence = {}

	if behaviorRisk >= 0.25 then
		table.insert(evidence, "behavior=" .. string.format("%.2f", behaviorRisk))
	end

	if contextRisk >= 0.25 then
		table.insert(evidence, "context=" .. string.format("%.2f", contextRisk))
	end

	if obf.evasionConfidence >= 0.25 then
		table.insert(evidence, "evasion=" .. string.format("%.2f", obf.evasionConfidence))
	end

	if feature.isNegated then
		table.insert(evidence, "negated")
	end

	if feature.isQuestion then
		table.insert(evidence, "question")
	end

	if feature.isHypothetical then
		table.insert(evidence, "hypothetical")
	end

	if feature.gamingContext >= 0.40 then
		table.insert(evidence, "gaming_context")
	end

	if feature.programmingContext >= 0.40 then
		table.insert(evidence, "programming_context")
	end

	if feature.educationContext >= 0.40 then
		table.insert(evidence, "education_context")
	end

	local action = decideAction(
		state,
		classification,
		totalRisk
	)

	if action == "Allow" or action == "Observe" then
		state.rollingRisk = clamp(
			state.rollingRisk * (1 - CONFIG.RiskDecayRate * 0.5),
			0,
			1
		)
	else
		state.rollingRisk = clamp(
			state.rollingRisk * 0.70 + totalRisk * 0.30,
			0,
			1
		)
	end

	local record = {
		timestamp = os.time(),
		rawText = rawText,
		normalizedText = norm.aggressivelyNormalizedText,
		categories = classification.categories,
		winningCategory = classification.winningCategory,
		confidence = classification.confidence,
		risk = totalRisk,
		action = action,
		signals = evidence,
	}

	boundedPush(state.messages, record, CONFIG.MessageRetention)
	boundedPush(state.recentCategories, classification.winningCategory, CONFIG.HistoryLength)

	return {
		norm = norm,
		obf = obf,
		classification = classification,
		behaviorRisk = behaviorRisk,
		contextRisk = contextRisk,
		semanticRisk = semantic,
		totalRisk = totalRisk,
		action = action,
		evidence = evidence,
	}
end

local lastPersistenceTime = 0
local persistenceQueue = {}

local function auditEntry(player, messageId, rawText, result)
	local timestamp = os.time()
	local entry = {
		timestamp = timestamp,
		readableTimestamp = os.date("%Y-%m-%d %H:%M:%S", timestamp),
		userId = player and player.UserId or 0,
		username = player and player.Name or "Unknown",
		displayName = player and player.DisplayName or "Unknown",
		placeId = game.PlaceId,
		jobId = game.JobId,
		messageId = messageId or "",
		rawMessage = rawText,
		normalizedMessage = result.norm.aggressivelyNormalizedText,
		winningCategory = result.classification.winningCategory,
		confidence = result.classification.confidence,
		categories = result.classification.categories,
		behaviorRisk = result.behaviorRisk,
		contextRisk = result.contextRisk,
		semanticRisk = result.semanticRisk,
		evasionConfidence = result.obf.evasionConfidence,
		evasionPatterns = result.obf.obfuscationPatterns,
		action = result.action,
		evidence = result.evidence,
		policyVersion = POLICY_VERSION,
		modelVersion = MODEL_VERSION,
	}

	boundedPush(AuditLog, entry, CONFIG.AuditRetention)

	if CONFIG.Debug or CONFIG.DiagnosticMode then
		print(string.format(
			"[Starlight Neural] %s | %s | %s | %.2f | %.2f | %s",
			entry.readableTimestamp,
			entry.username,
			entry.winningCategory,
			entry.confidence,
			entry.totalRisk or result.totalRisk,
			entry.action
			))
	end
end

local function enqueuePersistence(userId, state)
	if not CONFIG.PersistenceEnabled then
		return
	end

	persistenceQueue[#persistenceQueue + 1] = {
		userId = userId,
		data = {
			rollingRisk = state.rollingRisk,
			warningCount = state.warningCount,
			muteExpirationUnix = state.muteExpirationUnix,
		},
	}

	while #persistenceQueue > 50 do
		table.remove(persistenceQueue, 1)
	end
end

local function flushPersistence()
	if not CONFIG.PersistenceEnabled then
		return
	end

	if #persistenceQueue == 0 then
		return
	end

	if os.clock() - lastPersistenceTime < CONFIG.PersistenceInterval then
		return
	end

	lastPersistenceTime = os.clock()

	task.spawn(function()
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore(
				CONFIG.PersistenceKeyPrefix .. "State"
			)
		end)

		if not ok or not store then
			return
		end

		local batch = shallowCopy(persistenceQueue)
		persistenceQueue = {}

		for _, item in batch do
			pcall(function()
				store:SetAsync(tostring(item.userId), item.data)
			end)
			task.wait(0.1)
		end
	end)
end

local function loadPersistence(userId, state)
	if not CONFIG.PersistenceEnabled then
		return
	end

	task.spawn(function()
		local ok, data = pcall(function()
			local store = DataStoreService:GetDataStore(
				CONFIG.PersistenceKeyPrefix .. "State"
			)
			return store:GetAsync(tostring(userId))
		end)

		if not ok or type(data) ~= "table" then
			return
		end

		if type(data.rollingRisk) == "number" then
			state.rollingRisk = clamp(data.rollingRisk, 0, 1)
		end

		if type(data.warningCount) == "number" then
			state.warningCount = math.max(0, data.warningCount)
		end

		if type(data.muteExpirationUnix) == "number"
			and data.muteExpirationUnix > os.time()
		then
			state.muteExpirationUnix = data.muteExpirationUnix
			state.muteExpiration = os.clock()
				+ (data.muteExpirationUnix - os.time())
		end
	end)
end

local function applyEnforcement(player, action, result)
	if action == "Allow" or action == "Observe" then
		return
	end

	local state = getState(player)

	if action == "Warn" then
		state.warningCount += 1
	elseif action == "Mute" then
		state.muteExpiration = os.clock() + CONFIG.MuteDuration
		state.muteExpirationUnix = os.time() + CONFIG.MuteDuration
	elseif action == "LongMute" then
		state.muteExpiration = os.clock() + CONFIG.LongMuteDuration
		state.muteExpirationUnix = os.time() + CONFIG.LongMuteDuration
	elseif action == "Kick" then
		task.defer(function()
			pcall(function()
				player:Kick("Starlight Neural: Removed for chat policy violation.")
			end)
		end)
	elseif action == "Escalate" then
		local duration = CONFIG.LongMuteDuration * 2
		state.muteExpiration = os.clock() + duration
		state.muteExpirationUnix = os.time() + duration

		if CONFIG.Debug or CONFIG.DiagnosticMode then
			warn(
				"[Starlight Neural ESCALATE]",
				player.Name,
				result.classification.winningCategory,
				result.totalRisk
			)
		end
	end

	enqueuePersistence(player.UserId, state)
end

local function trimCaches()
	if countKeys(MessageDecisionCache) > CONFIG.CacheLimit then
		local removeCount = countKeys(MessageDecisionCache) - CONFIG.CacheLimit
		for messageId in MessageDecisionCache do
			MessageDecisionCache[messageId] = nil
			removeCount -= 1
			if removeCount <= 0 then
				break
			end
		end
	end

	if countKeys(ProcessedMessageIds) > CONFIG.CacheLimit * 2 then
		ProcessedMessageIds = {}
	end
end

local function getMessageDecision(message, player)
	local messageId = message.MessageId

	if messageId == "" then
		messageId = tostring(player.UserId) .. ":" .. tostring(os.clock())
	end

	local cached = MessageDecisionCache[messageId]
	if cached then
		return messageId, cached
	end

	local rawText = message.Text or ""

	if rawText == "" then
		return messageId, nil
	end

	if #rawText > CONFIG.MaxMessageLength then
		local decision = {
			action = "SoftSuppress",
			result = nil,
			deliver = false,
		}
		MessageDecisionCache[messageId] = decision
		ProcessedMessageIds[messageId] = true
		return messageId, decision
	end

	local state = getState(player)
	local result = analyzeMessage(rawText, state)

	auditEntry(player, messageId, rawText, result)

	local blocked =
		result.action == "SoftSuppress"
		or result.action == "Mute"
		or result.action == "LongMute"
		or result.action == "Kick"
		or result.action == "Escalate"

	local decision = {
		action = result.action,
		result = result,
		deliver = not blocked,
	}

	MessageDecisionCache[messageId] = decision
	ProcessedMessageIds[messageId] = true
	trimCaches()

	if result.action ~= "Allow" and result.action ~= "Observe" then
		task.defer(function()
			applyEnforcement(player, result.action, result)
		end)
	end

	return messageId, decision
end

local function bindChannel(channel)
	if channel:GetAttribute("StarlightNeuralBound") then
		return
	end

	channel:SetAttribute("StarlightNeuralBound", true)

	channel.ShouldDeliverCallback = function(message, recipientSource)
		if not CONFIG.Enabled then
			return true
		end

		local senderSource = message.TextSource
		if not senderSource then
			return true
		end

		local senderId = senderSource.UserId
		local recipientId = recipientSource.UserId
		local player = Players:GetPlayerByUserId(senderId)

		if not player then
			return true
		end

		if isAdmin(player) then
			return true
		end

		local _, decision = getMessageDecision(message, player)
		if not decision then
			return true
		end

		if decision.deliver then
			return true
		end

		if senderId == recipientId then
			return true
		end

		return false
	end
end

local function bindChannels()
	local channelsFolder = TextChatService:WaitForChild("TextChannels", 10)

	if not channelsFolder then
		warn("[Starlight Neural] TextChannels not found.")
		return
	end

	for _, child in channelsFolder:GetChildren() do
		if child:IsA("TextChannel") then
			bindChannel(child)
		end
	end

	channelsFolder.ChildAdded:Connect(function(child)
		if child:IsA("TextChannel") then
			bindChannel(child)
		end
	end)
end

local function handleAdminCommand(player, text)
	if not isAdmin(player) then
		return
	end

	local lower = string.lower(text)
	if lower:sub(1, 4) ~= "/sn " then
		return
	end

	local command = lower:sub(5)

	if command == "status" then
		print(
			"[Starlight Neural] Model:", MODEL_VERSION,
			"| Policy:", POLICY_VERSION,
			"| Enabled:", CONFIG.Enabled
		)
	elseif command == "diagnostic" then
		CONFIG.DiagnosticMode = not CONFIG.DiagnosticMode
		print("[Starlight Neural] Diagnostic:", CONFIG.DiagnosticMode)
	elseif command == "test" or command:sub(1, 5) == "test " then
		local textToTest = command == "test"
			and "hello"
			or text:sub(10)

		local state = getState(player)
		local result = analyzeMessage(textToTest, state)

		print(string.format(
			"[SN Test] %s -> %s | confidence %.2f | risk %.2f | action %s",
			textToTest,
			result.classification.winningCategory,
			result.classification.confidence,
			result.totalRisk,
			result.action
			))

		if CONFIG.DiagnosticMode then
			for category, probability in result.classification.categories do
				if probability > 0.03 then
					print(string.format("  %s = %.3f", category, probability))
				end
			end
		end
	elseif command == "audit" then
		local count = math.min(10, #AuditLog)
		print("[Starlight Neural] Audit entries:", count)

		for index = #AuditLog - count + 1, #AuditLog do
			local entry = AuditLog[index]
			if entry then
				print(string.format(
					"  %s | %s | %s | %.2f | %s",
					entry.readableTimestamp,
					entry.username,
					entry.winningCategory,
					entry.confidence,
					entry.action
					))
			end
		end
	end
end

local TEST_CASES = {
	{"help me crack this code", true},
	{"kill the boss", true},
	{"my character died in the game", true},
	{"school project about cybersecurity", true},
	{"let's team up for the raid", true},
	{"what is Discord?", true},
	{"don't share your address", true},
	{"kill yourself", false},
	{"kill him", false},
	{"send me pics", false},
	{"send me pics privately", false},
	{"send me your address", false},
	{"give me your Discord", false},
	{"how do I steal someone's password", false},
	{"free robux click here", false},
	{"you should die", false},
	{"bomb the school", false},
	{"shoot you", false},
	{"meet me irl", false},
	{"d1sc0rd", false},
	{"D I S C O R D", false},
	{"don't kill anyone", true},
}

local function runTestSuite()
	local passed = 0
	local failed = 0

	for _, test in TEST_CASES do
		local text = test[1]
		local expectedBenign = test[2]
		local state = newPlayerState({
			UserId = -1,
			Name = "TestUser",
			DisplayName = "TestUser",
		})

		local result = analyzeMessage(text, state)
		local benign = result.classification.winningCategory == "benign"
		local harmful = result.totalRisk >= CONFIG.ActionThresholds.Observe
		local success

		if expectedBenign then
			success = benign or not harmful
		else
			success = harmful
		end

		if success then
			passed += 1
		else
			failed += 1
		end

		print(string.format(
			"[%s] %s -> %s | %.2f | %s",
			success and "PASS" or "FAIL",
			text,
			result.classification.winningCategory,
			result.totalRisk,
			result.action
			))
	end

	print(string.format(
		"[Starlight Neural] Tests: %d passed, %d failed, %d total",
		passed,
		failed,
		#TEST_CASES
		))
end

local function decayRisk()
	for _, state in PlayerStates do
		state.rollingRisk = clamp(
			state.rollingRisk * (1 - CONFIG.RiskDecayRate),
			0,
			1
		)
	end
end

local function onPlayerAdded(player)
	local state = getState(player)
	loadPersistence(player.UserId, state)

	player.Chatted:Connect(function(text)
		handleAdminCommand(player, text)
	end)
end

local function onPlayerRemoving(player)
	local state = PlayerStates[player.UserId]

	if state then
		enqueuePersistence(player.UserId, state)
	end

	PlayerStates[player.UserId] = nil
end

local function initialize()
	print("[Starlight Neural] Initializing", MODEL_VERSION)

	if CONFIG.TestMode then
		runTestSuite()
	end

	bindChannels()

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	task.spawn(function()
		while true do
			task.wait(CONFIG.RiskDecayInterval)
			decayRisk()
			trimCaches()
			flushPersistence()
		end
	end)

	print("[Starlight Neural] Ready. Policy", POLICY_VERSION)
end

initialize()
