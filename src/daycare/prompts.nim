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
  PromptBankVersion* = "daycare-rules-v2"

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

proc communicationBriefing*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvCanonical:
    """THERE IS NO MESSAGE CHANNEL IN EITHER DIRECTION. You cannot talk to the other
cog and it cannot talk to you. The other cog is a different policy and it is
deciding at the SAME MOMENT as you, without seeing your choice. Your `hunch` is
seen only by spectators; your `notes` are seen only by you, next turn.
"""
  of pvPlain:
    """No messages pass between the two cogs. The other cog uses a different policy and chooses simultaneously, before seeing your choice. Your `hunch` reaches spectators only; your `notes` return only to you on the next turn.
"""
  of pvNumbered:
    """1. Neither cog can message the other.
2. The other cog runs a different policy and decides at the same time, without seeing your choice.
3. Only spectators see your `hunch`.
4. Only you see your `notes`, next turn.
"""
  of pvQuestions:
    """Can either cog talk to the other? No. When does the other policy decide? At the same moment, without seeing your choice. Who sees your `hunch`? Spectators only. Who sees your `notes`? You alone, next turn.
"""
  of pvReordered:
    """Keep `notes` for your own next turn; spectators alone see your `hunch`. The other cog follows a different policy and commits simultaneously without seeing your choice. Neither direction has a message channel.
"""
  of pvHeldoutBriefing:
    """Coordinate through behavior: there is no direct message channel between cogs. Your partner is another policy making its choice simultaneously and cannot see yours first. A `hunch` is spectator-only, while `notes` remain private to your next turn.
"""
  of pvHeldoutReference:
    """Communication: no messages in either direction. Decisions: simultaneous across distinct policies; the other policy cannot see your current choice. `hunch` visibility: spectators only. `notes` visibility: yourself on the following turn only.
"""
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")

proc preferenceBriefing*(selection: PromptSelection, parent: bool): string =
  case selection.selectedVariant
  of pvCanonical:
    if parent: """THE CHILD'S PREFERENCE IS NEVER SHOWN TO YOU — infer it from where it walks,
what it reaches for, and what it refuses to eat."""
    else: """YOU KNOW YOUR OWN PREFERENCE and you are told it every turn. The parent is not."""
  of pvPlain:
    if parent: """You never receive the child's preference directly. Infer it by observing its movement, reaching, and refusal to eat."""
    else: """Your preference is given to you each turn; the parent does not receive it."""
  of pvNumbered:
    if parent: """1. The child's preference is hidden from you.
2. Use where it walks, what it reaches toward, and what it refuses to eat as evidence."""
    else: """1. You know your preference.
2. Every turn repeats it to you.
3. The parent is not told."""
  of pvQuestions:
    if parent: """What does the child prefer? You are never told. How can you infer it? Watch where it walks, what it reaches for, and what food it refuses."""
    else: """Who knows your preference? You do: each turn tells you again. Is the parent told? No."""
  of pvReordered:
    if parent: """Where the child walks, reaches, and refuses food are your clues. Its actual preference is never shown to you."""
    else: """The parent is not told what you prefer. You know your own preference and receive it again every turn."""
  of pvHeldoutBriefing:
    if parent: """Your task is inference from behavior: the child's preference is withheld, but its walking, reaching, and refusal to eat provide clues."""
    else: """You have private knowledge of your preference, refreshed in each turn's instructions. The parent lacks that information."""
  of pvHeldoutReference:
    if parent: """Hidden information: the child's preference. Available evidence: movement, reaching targets, and food refusals."""
    else: """Preference visibility: known to the child and supplied every turn; not disclosed to the parent."""
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
