## Jev ranks standing orders from this player's private observation.

import std/[json, os, strutils]
import curly

proc chooseOrder*(observation: JsonNode, guidance: string): JsonNode =
  let role = observation["role"].getStr()
  var criteria = newJObject()
  var orders = newJObject()
  if role == "parent":
    for guess in ["apple", "banana"]:
      for fruit in ["apple", "banana"]:
        for job in ["provide", "stock"]:
          let key = job & "_" & fruit & "_guess_" & guess
          criteria[key] = %(if job == "provide":
            "Deliver " & fruit & " beside the child to feed it; guess " & guess
          else:
            "Put " & fruit & " on the basket mat for the child; guess " & guess)
          orders[key] = %*{"job": job, "fruit": fruit, "guess": guess}
      for job in ["watch", "idle"]:
        let key = job & "_guess_" & guess
        criteria[key] = %(if job == "watch":
          "Observe the child without providing food; guess " & guess
        else:
          "Do nothing and provide no food; guess " & guess)
        orders[key] = %*{"job": job, "guess": guess}
  elif role == "child":
    for fruit in ["apple", "banana"]:
      for job in ["seek", "show"]:
        let key = job & "_" & fruit
        criteria[key] = %(if job == "seek":
          "Seek and eat reachable " & fruit
        else:
          "Signal desire for " & fruit & " at a tall tree without eating")
        orders[key] = %*{"job": job, "fruit": fruit}
    for job in ["graze", "beg", "idle"]:
      criteria[job] = %job
      orders[job] = %*{"job": job}
  else:
    raise newException(ValueError, "unknown Daycare role")

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "typesafe/jev-1.13")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Jev player has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing Daycare. Both seats share the score, awarded " &
      "only when the child eats. The parent can harvest tall trees but the " &
      "child cannot. Delivering fruit lets the child eat; watching and idling " &
      "provide no food. The parent infers the child's hidden fruit preference " &
      "from behavior; the child signals its own preference through actions. Use only this " &
      "seat observation:\n" & $observation &
      "\nStrategy guidance: " & guidance,
    "questions": {"order": {
      "type": "choice",
      "instructions": "Choose one standing order for this turn.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["order"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "Daycare Jev player: choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  orders[selected]
