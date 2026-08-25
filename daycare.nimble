version     = "0.1.0"
author      = "daveey"
description = "Daycare: one cog can reach the fruit, the other knows which fruit it wants, and neither can say a word. Asymmetric cooperation for the Softmax Coworld platform."
license     = "MIT"

srcDir = "src"

bin = @["daycare", "daycare_player"]

requires "nim >= 2.2.4"
requires "bitworld >= 0.1.0"
requires "pixie"
requires "mummy >= 0.4.7"
requires "curly >= 1.1.1"
requires "whisky"
requires "supersnappy >= 2.1.3"
requires "flatty >= 0.3.4"
