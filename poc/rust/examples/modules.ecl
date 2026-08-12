# A module has its own environment. Public words can reach private bindings.
'counter (
  1 'step letp
  (step +) 'advance def
) module

10 counter.advance pp

# use is scoped; aliases qualify through the same registry.
'counter use
'c 'counter alias
20 advance pp
30 c.advance pp

# Re-registration hot-heals qualified, used, and aliased callers.
'counter (
  2 'step letp
  (step +) 'advance def
) module

10 counter.advance pp
20 advance pp
30 c.advance pp
