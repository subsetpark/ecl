### def soak-step
# Consume a count and redefine one top-level name once per count. A replaced
# definition nothing holds is reclaimed, so the history does not accumulate.
# Module reload is deliberately absent: a Session keeps every published image
# until teardown.
(dup 0 = (pop)
 (
  ### def hot-binding
  (1) `hot-binding def 1 - soak-step) if) `soak-step def
soak-step
