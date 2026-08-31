### module stdlib.test.pkg-docs
[]
(
 'stdlib.test.support ('raises-word 'documented) import

 ### test exports
 (-- : "Require documentation for the complete public package vocabulary.")
 (('pkg.version.validate 'pkg.version.less? 'pkg.version.max
   'pkg.name.valid? 'pkg.name.hash? 'pkg.name.url? 'pkg.name.owns?
   'pkg.name.collides? 'pkg.data.assert-inert-entry 'pkg.data.read-one
   'pkg.data.sorted-entries 'pkg.manifest.validate-requirement
   'pkg.manifest.validate 'pkg.manifest.read 'pkg.manifest.write
   'pkg.lock.validate 'pkg.lock.read 'pkg.lock.write 'pkg.lock.vendor
   'pkg.lock.tree 'pkg.lock.why 'pkg.mvs.resolve 'pkg.sync.cache-root
   'pkg.sync.store-key 'pkg.sync.store-path 'pkg.sync.store-keys
   'pkg.sync.store-root 'pkg.sync.requirement 'pkg.sync.install-immutable
   'pkg.sync.run 'pkg.sync.run-offline 'pkg.sync.verify 'pkg.cli.init
   'pkg.cli.add 'pkg.cli.sync 'pkg.cli.sync-offline 'pkg.cli.tree
   'pkg.cli.why 'pkg.cli.verify 'pkg.cli.vendor 'pkg.cli.gc)
  documented)
 'exports test

 ### test privacy
 (-- : "Keep private package implementation helpers unreachable.")
 (("1.0.0" pkg.version.version-cmp)
  'undefined-word
  'pkg.version.version-cmp
  raises-word
  ("foo" pkg.name.related?) 'undefined-word 'pkg.name.related? raises-word)
 'privacy test
) 'stdlib.test.pkg-docs @defm
