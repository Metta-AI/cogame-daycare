## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "daycare-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, me, role, other, otherRole: string): string =
  case selection.selectedVariant
  of pvCanonical:
    "You are " & me & ", the " & role & " in a walled yard with one other cog, " & other & " (the " & otherRole & ").\n"
  of pvPlain:
    "You play " & me & ", the " & role & ". You share a walled yard with one other cog: " & other & ", the " & otherRole & ".\n"
  of pvNumbered:
    "1. Your cog is " & me & ", the " & role & ". 2. The other cog is " & other & ", the " & otherRole & ". 3. You are together in a walled yard.\n"
  of pvQuestions:
    "Who are you? " & me & ", the " & role & ". Who else is here? " & other & ", the " & otherRole & ", the one other cog. Where are you? A walled yard.\n"
  of pvReordered:
    "In a walled yard are two cogs: " & other & " (the " & otherRole & ") and you, " & me & " (the " & role & ").\n"
  of pvHeldoutBriefing:
    "Take the role of " & me & ", the " & role & ", in a walled yard. Your sole fellow cog is " & other & ", the " & otherRole & ".\n"
  of pvHeldoutReference:
    "Setting: walled yard. Your identity: " & me & ", " & role & ". One other cog: " & other & ", " & otherRole & ".\n"
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
