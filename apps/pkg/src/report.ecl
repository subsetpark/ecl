### module pkg.report
[]
(
 ### defp edges
 (entry lock -- lines : "Render selected direct edges in canonical alias order.")
 (|entry lock|
  entry 1 at pkg.data.sorted-entries entry first lock pair (edge) with each) 'edges defp

 ### defp edge
 (entry parent lock -- line : "Show one selected dependency version.")
 (|entry parent lock|
  parent entry 1 at 'package at lock 'packages at entry 1 at 'package at at 'version at
  3 pack "{} -> {} {}" str.format) 'edge defp

 ### def tree
 (lock -- text : "Render the root and deterministic direct selected edges.")
 (pkg.resolution.validate
  (|lock|
   lock 'requires at pkg.data.sorted-entries lock (edges) partial each raze
   lock 'root at swap cons "\n" join "\n" cat) call) 'tree def

 ### defp enqueue
 (state child -- state : "Enqueue each package once, bounding path search by the selected graph.")
 (|state child|
  state 'seen at child (match?) partial any?
  state () partial state child pair (enqueue-new) with if) 'enqueue defp

 ### defp enqueue-new
 (state child -- state : "Record one canonical shortest path to an unseen child.")
 (|state child|
  state 'seen state 'seen at child append put
  'pending state 'pending at state 'current at child append append put) 'enqueue-new defp

 ### defp expand
 (state -- state : "Expand one path in sorted package order.")
 (dup 'lock at 'requires at over 'current at last at dict.vals ('package at) each distinct sort
  swap (enqueue) fold) 'expand defp

 ### defp step
 (state -- state : "Stop at the first canonical shortest owner path.")
 (|state|
  state 'current state 'pending at first put 'pending state 'pending at 1 drop put
  dup 'current at last over 'target at match?
  ('found over 'current at put) (expand) if) 'step defp

 ### defp path
 (lock target -- path : "Find one deterministic root-to-owner path without enumerating all paths.")
 (|lock target|
  {'found []} 'lock lock put 'target target put
  'pending lock 'root at wrap wrap put 'seen lock 'root at wrap put
  (dup 'found at empty? over 'pending at empty? not and) (step) while 'found at) 'path defp

 ### defp node
 (name lock -- text : "Render a selected version while leaving the root unversioned.")
 (|name lock|
  name lock 'root at match? name () partial
  name lock pair (|name lock| name lock 'packages at name at 'version at pair "{} {}" str.format)
  with if)
 'node defp

 ### def why
 (lock module -- text : "Explain one locked package owner using a bounded canonical path search.")
 (|lock module|
  lock pkg.resolution.validate pop
  module pkg.name.valid? 'domain error.new "pkg why expects a canonical module name"
  error.with-message assert
  lock 'packages at dict.keys module (pkg.name.owns?) partial filter
  dup len 1 = 'domain error.new "no locked package owns the requested module" error.with-message
  assert
  first lock swap path lock (node) partial each " -> " join
  module ": " cat swap cat "\n" cat) 'why def
) 'pkg.report @defm
