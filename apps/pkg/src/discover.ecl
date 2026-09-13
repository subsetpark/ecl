### module pkg.discover
# Discovery is used only for an absent lock or an explicit dependency update.
[]
(
 ### defp require
 (condition -- : "Reject a mismatched or oversized discovered dependency graph.")
 ('domain error.new "invalid discovered package graph" error.with-message assert) 'require defp

 ### defp known?
 (state requirement -- bool : "Recognize an exact manifest already inspected for this resolution.")
 (|state requirement|
  state 'catalog at requirement 'package at {} at-or requirement 'version at dict.has?) 'known? defp

 ### defp fetched
 (state requirement manifest -- state :
  "Retain only manifest metadata and enqueue its declared edges.")
 (|state requirement manifest|
  manifest 'name at requirement 'package at match? require
  manifest 'version at requirement 'version at match? require
  state 'count at 4096 < require
  state 'count state 'count at 1 + put
  'pending state 'pending at manifest 'requires at dict.vals cat put
  'catalog state 'catalog at requirement 'package at
  state 'catalog at requirement 'package at {} at-or requirement 'version at manifest put put put)
 'fetched defp

 ### defp visit-new
 (state requirement -- state : "Pin and inspect a previously unseen exact source artifact.")
 (|state requirement|
  state requirement state 'context at requirement pkg.obtain.requirement
  pkg.bundle.inspect 'manifest at fetched) 'visit-new defp

 ### defp visit
 (state requirement -- state :
  "Skip exact nodes already discovered; the resolver checks all edges.")
 (|state requirement|
  state requirement known? state () partial state requirement pair (visit-new) with if) 'visit defp

 ### defp step
 (state -- state : "Remove one pending declaration before processing its artifact.")
 (|state|
  state 'pending state 'pending at 1 drop put state 'pending at first visit) 'step defp

 ### def catalog
 (context manifest -- catalog :
  "Discover a bounded exact-manifest catalog without retaining archive bytes.")
 (|context manifest|
  {'catalog {} 'count 0} 'context context put 'pending manifest 'requires at dict.vals put
  (dup 'pending at empty? not) (step) while 'catalog at) 'catalog def
) 'pkg.discover @defm
