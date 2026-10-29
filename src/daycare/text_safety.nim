## Pure RFC 3629 scalar validation for consumed native text and private evidence.
## Reused verbatim from the reviewed native-capture validator; no normalization.

proc scalarUtf8*(text: string): bool =
  ## RFC 3629: Nim's validateUtf8 alone permits encoded surrogate code points.
  var index = 0
  while index < text.len:
    let first = ord(text[index])
    var size = 1
    if first <= 0x7f: discard
    elif first in 0xc2 .. 0xdf: size = 2
    elif first in 0xe0 .. 0xef: size = 3
    elif first in 0xf0 .. 0xf4: size = 4
    else: return false
    if index + size > text.len: return false
    for offset in 1 ..< size:
      if ord(text[index + offset]) notin 0x80 .. 0xbf: return false
    if size >= 3:
      let second = ord(text[index + 1])
      if first == 0xe0 and second < 0xa0 or first == 0xed and second > 0x9f or
          first == 0xf0 and second < 0x90 or first == 0xf4 and second > 0x8f:
        return false
    index += size
  true
