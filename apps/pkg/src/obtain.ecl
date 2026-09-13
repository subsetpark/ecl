### module pkg.obtain
# Every selected download is pinned in the private generation before reuse.
[]
(
 ### defp optional
 (result -- bytes :
  "Treat unavailable optimization inputs as misses while preserving cancellation.")
 (dup result.ok? ('ok at first)
  ('err at dup 'kind at 'io match? (pop []) (raise) if) if) 'optional defp

 ### defp active-read
 (context hash -- bytes : "Read a sealed artifact from the captured previous generation.")
 (|context hash|
  context 'project at context 'active at "/archives" cat fs.child-dir
  dup hash pkg.cache.read-at swap port.close) 'active-read defp

 ### defp previous
 (context hash -- bytes : "An absent or damaged previous generation is only an optimization miss.")
 (|context hash|
  context 'active at empty? ([])
  context hash pair (pair (active-read) @attempt optional) with if) 'previous defp

 ### defp network
 (context requirement -- bytes : "Offline operation never starts a network request.")
 (|context requirement|
  context 'offline at not
  'io error.new "offline package artifact is unavailable" error.with-message assert
  requirement pkg.fetch.requirement) 'network defp

 ### defp external
 (context requirement -- bytes :
  "Try the captured generation and cache before the pinned network source.")
 (|context requirement|
  context requirement 'hash at previous
  context requirement pair (cached-or-network) with call) 'external defp

 ### defp cached-or-network
 (bytes context requirement -- bytes :
  "Fill one missing artifact from the optional cache or source.")
 (|bytes context requirement|
  bytes empty?
  context requirement pair (cache-or-network) with bytes () partial if) 'cached-or-network defp

 ### defp cache-or-network
 (context requirement -- bytes : "Require exact bytes even when a shared cache is present.")
 (|context requirement|
  context 'cache at requirement 'hash at pkg.cache.read
  context requirement pair (network-if-empty) with call) 'cache-or-network defp

 ### defp network-if-empty
 (bytes context requirement -- bytes : "Fetch only an artifact unavailable from local inputs.")
 (|bytes context requirement|
  bytes empty? context requirement pair (network) with bytes () partial if) 'network-if-empty defp

 ### defp pin
 (context requirement -- bytes :
  "Retain verified bytes privately before permitting cache collection.")
 (|context requirement|
  context requirement external context requirement pin-bytes) 'pin defp

 ### defp pin-bytes
 (bytes context requirement -- bytes : "Publish private bytes before the disposable cache copy.")
 (|bytes context requirement|
  context 'downloads at requirement 'hash at bytes pkg.cache.write-at
  context 'cache at requirement 'hash at bytes pkg.cache.write bytes) 'pin-bytes defp

 ### def requirement
 (context requirement -- bytes :
  "Obtain an exact pin, with a private copy independent of cache lifetime.")
 (|context requirement|
  context 'downloads at requirement 'hash at pkg.cache.read-at
  context requirement pair (pin-if-empty) with call) 'requirement def

 ### defp pin-if-empty
 (bytes context requirement -- bytes :
  "Reuse an already pinned artifact or materialize it exactly once.")
 (|bytes context requirement|
  bytes empty? context requirement pair (pin) with bytes () partial if) 'pin-if-empty defp
) 'pkg.obtain @defm
