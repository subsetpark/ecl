# Step 14 — typed flat-leaf kernels: post-state characterization

This report characterizes the completed Step 14 seam through the public
`Session.init`/`Session.runUnit` surface. Reproduce it with:

```sh
zig build bench-kernels -Doptimize=ReleaseSafe
zig build bench-kernels -Doptimize=ReleaseFast
```

It is not before/after migration proof. The old boxed flat route is absent, and
recreating it would introduce the second semantic loop the migration removes.
The generic-spine rows below are the retained structural path, not a hidden
flat fallback.

Allocation count, peak bytes, and polls are the durable counters. Milliseconds
are dated machine context only and must be re-measured before use. The scaling
rows cover every workstream-required size for both a flat leaf and a ragged
generic spine.

## Machine and toolchain

| | |
|---|---|
| host | Apple aarch64, macOS (Darwin 25.5.0) |
| zig | 0.16.0 |
| build modes | ReleaseSafe and ReleaseFast |
| date | 2026-08-19 |

The fixed workloads use one million elements for pervasion, copy, gather,
index-vector, and random cases; one hundred thousand for `grade`/`group`; five
thousand for `distinct`; and fifty thousand for generic-spine comparison rows.

## ReleaseSafe

```text
class              case                        allocations     peak bytes      polls           ms
scaling            flat x scalar                        20          20008          2        0.106  n=1
scaling            ragged x scalar                      25         170904          4        0.061  n=1
scaling            flat x scalar                        20          20504          2        0.031  n=32
scaling            ragged x scalar                      87         176512          4        0.047  n=32
scaling            flat x scalar                        20          36376          2        0.027  n=1024
scaling            ragged x scalar                    2071         359040          4        0.279  n=1024
scaling            flat x scalar                        20        1068552          2        0.098  n=65535
scaling            ragged x scalar                  131093       12210504          7       15.135  n=65535
scaling            flat x scalar                        20        1068568          3        0.103  n=65536
scaling            ragged x scalar                  131095       12210656          9       15.694  n=65536
scaling            flat x scalar                        20        1067584          4        0.109  n=65537
scaling            ragged x scalar                  131097       14307960          9       14.968  n=65537
scaling            flat x scalar                        20       16796208         33        1.116  n=1048576
scaling            ragged x scalar                 2097175      193090016         84      242.791  n=1048576
flat pervasion     leaf x scalar                        20       16018992         32        1.095
flat pervasion     leaf x leaf                          21       16018992         33        1.098
flat pervasion     unary                                22       16018992         33        1.121
flat pervasion     boxed spine floor                100023        9849184          7       11.449
mixed pervasion    i64 x f64 leaf                       20       24019040         32        1.602
mixed pervasion    i64 leaf x float scalar              20       16018992         32        1.259
recognized idiom   each                                 29       16051848         33        1.073
recognized idiom   zip-with                             30       16051864         34        1.148
recognized idiom   fold                                 26        8052944         32        2.488
recognized idiom   scan                                 29       16051840         33        2.986
copy and gather    reverse                              22       16018976         33        1.349
copy and gather    cat                                  21       24018976         63        2.842
copy and gather    take cyclic                          20        8026976         32        1.209
copy and gather    gather                               21       16018976         33        1.363
copy and gather    boxed spine floor                    23        6916184          5        2.551
index vectors      where mask                           20       12001384         33        5.497
index vectors      range                                21        8018864         33        1.070
order              grade                                22        2400528         62        3.667
order              group                               340       11220992        366       10.840
order              distinct                             22          60088         18        0.463
text               split                              7497         386499       7471        1.281
text               join                                 27         280195          3        0.308
random             rand-ints                            28        8018984         36        1.762
```

## ReleaseFast

```text
class              case                        allocations     peak bytes      polls           ms
scaling            flat x scalar                        20          20008          2        0.070  n=1
scaling            ragged x scalar                      25         170904          4        0.059  n=1
scaling            flat x scalar                        20          20504          2        0.024  n=32
scaling            ragged x scalar                      87         176512          4        0.033  n=32
scaling            flat x scalar                        20          36376          2        0.023  n=1024
scaling            ragged x scalar                    2071         359040          4        0.252  n=1024
scaling            flat x scalar                        20        1068552          2        0.080  n=65535
scaling            ragged x scalar                  131093       12210504          7       14.183  n=65535
scaling            flat x scalar                        20        1068568          3        0.088  n=65536
scaling            ragged x scalar                  131095       12210656          9       13.736  n=65536
scaling            flat x scalar                        20        1067584          4        0.085  n=65537
scaling            ragged x scalar                  131097       14307960          9       14.049  n=65537
scaling            flat x scalar                        20       16796208         33        0.836  n=1048576
scaling            ragged x scalar                 2097175      193090016         84      226.459  n=1048576
flat pervasion     leaf x scalar                        20       16018992         32        0.836
flat pervasion     leaf x leaf                          21       16018992         33        0.825
flat pervasion     unary                                22       16018992         33        0.875
flat pervasion     boxed spine floor                100023        9849184          7       10.706
mixed pervasion    i64 x f64 leaf                       20       24019040         32        1.270
mixed pervasion    i64 leaf x float scalar              20       16018992         32        0.903
recognized idiom   each                                 29       16051848         33        0.829
recognized idiom   zip-with                             30       16051864         34        0.830
recognized idiom   fold                                 26        8052944         32        2.301
recognized idiom   scan                                 29       16051840         33        3.016
copy and gather    reverse                              22       16018976         33        0.642
copy and gather    cat                                  21       24018976         63        1.705
copy and gather    take cyclic                          20        8026976         32        0.961
copy and gather    gather                               21       16018976         33        0.878
copy and gather    boxed spine floor                    23        6916184          5        2.353
index vectors      where mask                           20       12001384         33        4.094
index vectors      range                                21        8018864         33        0.732
order              grade                                22        2400528         62        3.499
order              group                               340       11220992        366       10.236
order              distinct                             22          60088         18        0.635
text               split                              7497         386499       7471        1.201
text               join                                 27         280195          3        0.216
random             rand-ints                            28        8018984         36        1.330
```

## What the counters establish

- Flat allocation count is constant from one through 1,048,576 elements (20
  allocations for the representative operation), while ragged storage grows
  with the number of structural cells by design.
- Flat polls follow kernel-quantum boundaries: 2 below 65,536, 3 at 65,536, 4
  at 65,537, and 33 at 1,048,576. They do not follow element count.
- Direct pervasion, guarded `each`/`zip-with`, sequential `fold`/`scan`, copies,
  gathers, index producers, order/group/distinct, join, and random output all
  publish without an allocation count proportional to their flat input.
- `split` allocates one owned result per produced piece; its count follows
  output structure, not a boxed intermediate. The join result stays constant
  allocation and uses a single exact-width output.
- Typed `distinct` is visible in the post-state counters: 22 allocations for
  the fixed 5,000-element workload rather than one matcher allocation per
  candidate comparison.

These observations supplement, but do not replace, the blocking parity,
bounded-work, memory-limit, OOM, worker, and sanitizer gates.
