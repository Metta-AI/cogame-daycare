## Daycare player: a policy is just a prompt.
##
## Forked from `cogame-bullwhip/src/bullwhip_player.nim`. Connects to the game,
## delivers its prompt (from PLAYER_PROMPT, or a default caregiving strategy),
## then only listens until the final frame. ALL decision-making happens inside
## the game container, which is what makes one parallel batch per turn possible.
##
## PLAYER_SCRIPTED=caretaker (or 1) registers the seat as the built-in working
## baseline instead; PLAYER_SCRIPTED=stubborn as the anti-theory-of-mind foil.
## The server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <daycare-image> --name my-daycare \
##     --run /bin/daycare-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Whichever role you draw, the game is reading the other cog. AS THE PARENT: your
score is whatever the child eats, tripled when it is the fruit it secretly
wants, so work out which fruit that is and keep it coming. Trust failed reaches
at tall trees first (the child cannot pick them, so reaching there is pure
desire), then fruit it walked over WITHOUT eating (that species is the one it
does not want), then ticks spent adjacent to a species, then what it ate. Set
`guess` to the species with the most failed reaches and `provide` that species
every turn; never eat a fruit yourself. AS THE CHILD: be legible. `seek` your
own species when any is reachable, otherwise spend the turn on `show` under a
tall tree of your species — you cannot pick it, but it is the only way to say
what you want.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "daycare player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "daycare player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's `receiveMessage` RAISES on a close frame or a truncated read (only
  ## a timeout returns `none`), and mummy's `send` only queues — so the game's
  ## `quit(0)` can outrun the flushed `final` frame. Wrapping the whole receive
  ## loop and exiting 0 on a dead socket is what makes certification stop
  ## failing intermittently with "Player container exited with status 1"
  ## (raid 0.1.3 -> 0.1.4, 2026-08-23).
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "daycare player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "daycare player: seated at slot ", payload{"slot"}.getInt(),
            " as ", payload{"name"}.getStr(), " (",
            payload{"role"}.getStr(), ")"
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "daycare player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "daycare player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "daycare player: socket ended (", error.msg, "), exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
