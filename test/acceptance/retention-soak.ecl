### def soak-step
# Consume a count; once per count, redefine one top-level name and reload one
# module. A replaced definition or module image nothing holds is reclaimed, so
# neither history accumulates.
(dup 0 = (pop)
 (
  ### def hot-binding
  (1) `hot-binding def
  (
   ### def value
   (1) `value def) `hot-module @defm
  1 - soak-step) if) `soak-step def
soak-step
