### module pkg.obtain
# Every selected download is pinned privately before reuse.
(
 ### defp optional
 (result -- bytes :
  "Treat unavailable optimization inputs as misses while preserving cancellation.")
 (dup result.ok? (`ok at first)
  (`err at dup `kind at `io match? (pop []) (raise) if) if) `optional defp

 ### defp installed-read
 (context hash -- bytes : "Read an archive the previous installation kept.")
 (|context hash|
  context `project at ".ecl/archives" fs.child-dir
  dup hash pkg.cache.read-at swap port.close) `installed-read defp

 ### defp installed
 (context hash -- bytes : "An absent or damaged previous installation is only a miss.")
 (pair (installed-read) cat @attempt optional) `installed defp

 ### defp network
 (context requirement -- bytes : "Offline operation never starts a network request.")
 (|context requirement|
  context `offline at not
  `io error.new "offline package artifact is unavailable" error.with-message assert
  requirement pkg.fetch.requirement) `network defp

 ### defp external
 (context requirement -- bytes :
  "Try the installed archives and the cache before the pinned network source.")
 (|context requirement|
  context requirement `hash at installed
  context requirement pair (cached-or-network) cat apply) `external defp

 ### defp cached-or-network
 (bytes context requirement -- bytes :
  "Fill one missing artifact from the optional cache or source.")
 (|bytes context requirement|
  bytes empty?
  context requirement pair (cache-or-network) cat bytes () cons if) `cached-or-network defp

 ### defp cache-or-network
 (context requirement -- bytes : "Require exact bytes even when a shared cache is present.")
 (|context requirement|
  context `cache at requirement `hash at pkg.cache.read
  context requirement pair (network-if-empty) cat apply) `cache-or-network defp

 ### defp network-if-empty
 (bytes context requirement -- bytes : "Fetch only an artifact unavailable from local inputs.")
 (|bytes context requirement|
  bytes empty? context requirement pair (network) cat bytes () cons if) `network-if-empty defp

 ### defp pin
 (context requirement -- bytes :
  "Retain verified bytes privately before permitting cache collection.")
 (|context requirement|
  context requirement external context requirement pin-bytes) `pin defp

 ### defp pin-bytes
 (bytes context requirement -- bytes : "Publish private bytes before the disposable cache copy.")
 (|bytes context requirement|
  context `downloads at requirement `hash at bytes pkg.cache.write-at
  context `cache at requirement `hash at bytes pkg.cache.write bytes) `pin-bytes defp

 ### def requirement
 (context requirement -- bytes :
  "Obtain an exact pin, with a private copy independent of cache lifetime.")
 (|context requirement|
  context `downloads at requirement `hash at pkg.cache.read-at
  context requirement pair (pin-if-empty) cat apply) `requirement def

 ### defp pin-if-empty
 (bytes context requirement -- bytes :
  "Reuse an already pinned artifact or materialize it exactly once.")
 (|bytes context requirement|
  bytes empty? context requirement pair (pin) cat bytes () cons if) `pin-if-empty defp
) `pkg.obtain @defm
