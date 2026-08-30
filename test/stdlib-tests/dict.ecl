### module stdlib.test.dict
(
 'stdlib.test.support
 ('equal 'raises-containing 'raises-word 'documented)
 import

 ### test observations
 (-- : "Observe dictionary entries in insertion order and by whole-value key.")
 ({'a 1 'b 2} dict.keys ['a 'b] equal
  {'a 1 'b 2} dict.size 2 equal
  {'a 1 'b 2} dict.vals [1 2] equal
  {'a 1 'b 2} dict.pairs (('a 1) ('b 2)) equal
  {'a 1} 'a dict.has? 1 equal
  {'a 1} 'b dict.has? 0 equal
  {'a 1 'b 2} ['b 'a] dict.keys-exactly? 1 equal
  {'a 1} ['a 'b] dict.keys-exactly? 0 equal
  {"ab" 9} "ab" dict.has? 1 equal
  {[1 2] 9} [1 2] dict.has? 1 equal
  {missing 9} (missing) first dict.has? 1 equal
  {{'a 1} 9} {'a 1} dict.has? 1 equal
  {1 9} 1.0 dict.has? 1 equal
  {"ab" 9} "a" dict.has? 0 equal
  ([] 'a dict.has?) 'type 'dict.has? raises-word)
 'observations test

 ### test gathering
 (-- : "Gather requested whole-value keys in caller order with duplicates.")
 ({'a 1 'b 2 'c 3} ['c 'a 'c] dict.at [3 1 3] equal
  {[1 2] 9 'a 1} [[1 2] 'a] dict.at [9 1] equal
  {'a 1} [] dict.at () equal
  {[1 2] 9} [1 2] at 9 equal
  ({'a 1} ['a 'missing] dict.at)
  'domain
  "could not find the dict key"
  raises-containing
  ({'a 1} 'a dict.at) 'type 'dict.at raises-word
  ([] [] dict.at) 'type 'dict.at raises-word)
 'gathering test

 ### test updates
 (-- : "Transform requested values without reordering dictionary keys.")
 ({'a 1 'b 2 'c 3} ['b 'a] (10 *) dict.update
  {'a 10 'b 20 'c 3} equal
  {[1 2] 9 'a 1} [[1 2] 'a] (1 +) dict.update
  {[1 2] 10 'a 2} equal
  {'a 1} ['a 'a] (1 +) dict.update {'a 3} equal
  {'a 1} [] (missing) dict.update {'a 1} equal
  ({'a 1} ['a 'b] (10 *) dict.update) 'domain 'dict.update raises-word
  ({'a 1} 'a (10 *) dict.update) 'type 'dict.update raises-word
  ({'a 1} ['a] (dup) dict.update) 'contract 'dict.update raises-word
  {'a 2} 'a 9 (10 *) dict.update-or {'a 20} equal
  {'a 2} 'b 9 (missing) dict.update-or {'a 2 'b 9} equal)
 'updates test

 ### test construction
 (-- : "Construct dictionaries from pairs and repeated values.")
 ([['a 1] ['b 2]] dict.from-pairs dup dict.pairs dict.from-pairs match? 1 equal
  ['a 'b 'c] 0 dict.from-keys {'a 0 'b 0 'c 0} equal
  [] dict.from-pairs {} equal
  [] 0 dict.from-keys {} equal
  ([['a 1] ['b]] dict.from-pairs)
  'shape
  "two-element pairs"
  raises-containing
  ([['a 1] ['a 2]] dict.from-pairs) 'domain 'dict.from-flat raises-word)
 'construction test

 ### test mapping
 (-- : "Map dictionary values while retaining their original keys.")
 ({'a 1 'b 2 'c 3} (nip 10 *) dict.map {'a 10 'b 20 'c 30} equal
  {} (missing) dict.map {} equal
  {'a 1 'b 2} (pair) dict.map {'a ('a 1) 'b ('b 2)} equal
  {'a 1 'b 2} (str) dict.map-values {'a "1" 'b "2"} equal)
 'mapping test

 ### test selection
 (-- : "Filter and select keys while preserving dictionary order.")
 ({'a 1 'b 2 'c 3} (nip 2 >) dict.filter {'c 3} equal
  {'a 1 'b 2 'c 3} (nip 2 >) dict.reject {'a 1 'b 2} equal
  {'a 1 'b 2 'c 3} ['c 'missing 'a] dict.take {'a 1 'c 3} equal
  {'a 1 'b 2 'c 3} ['b 'missing] dict.drop {'a 1 'c 3} equal
  {'a 1 'b 2 'c 3} ['c 'a] dict.split
  {'b 2} equal
  {'a 1 'c 3} equal)
 'selection test

 ### test merging
 (-- : "Merge dictionaries in stable order and resolve collisions explicitly.")
 ({'a 1 'b 2} {'b 20 'c 30} dict.merge {'a 1 'b 20 'c 30} equal
  {'a 1 'b 2} {'b 20 'c 30 'a 10}
  (|key left right| key pop left right +)
  dict.merge-with
  {'a 11 'b 22 'c 30} equal
  {} {'a 1} (missing) dict.merge-with {'a 1} equal
  ({'a 1} {'a 2} (pop pop pop) dict.merge-with)
  'contract
  'dict.merge-with
  raises-word)
 'merging test

 ### test documentation
 (-- : "Expose documentation for every dict module export.")
 (['dict.keys 'dict.size 'dict.vals 'dict.pairs 'dict.has? 'dict.at
   'dict.merge 'dict.from-flat 'dict.from-lists 'dict.from-pairs
   'dict.from-keys 'dict.keys-exactly? 'dict.update 'dict.update-or
   'dict.map 'dict.map-values 'dict.filter 'dict.reject 'dict.take
   'dict.drop 'dict.split 'dict.merge-with]
  documented)
 'documentation test
) 'stdlib.test.dict @defm
