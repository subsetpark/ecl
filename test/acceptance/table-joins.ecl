# DoD-30: stable equijoins with explicit missingness, over a CSV order table
# and a JSON customer table.
'table use

"test/acceptance/orders.csv" slurp csv.parse from-header-rows 'orders set
"test/acceptance/customers.json" slurp json.parse from-records 'customers set
orders pp
customers pp

# Both tables carry a `region` column, so a single-key join on `customer`
# alone collides on a non-key name. That is 'domain, resolved with rename.
(orders customers [["customer" "customer"]] inner-join) @attempt result.ok? pp
orders customers {"region" "home"} rename 'renamed set

# A duplicate right key expands many-to-many in left-major, right-minor order:
# order 1 pairs with gold then silver, then order 3 does the same.
orders renamed [["customer" "customer"]] inner-join pp

# A composite key joins on every pair at once, and `region` is then a key on
# both sides so nothing collides.
orders customers [["customer" "customer"] ["region" "region"]] inner-join pp

# An unmatched left row contributes nothing to an inner join.
orders customers [["customer" "customer"] ["region" "region"]] inner-join height pp
orders height pp

# A left join emits one row per unmatched left row, completed only from the
# caller's fill — the value is never invented.
orders customers [["customer" "customer"] ["region" "region"]]
{"tier" 'null} left-join-with pp
orders customers [["customer" "customer"] ["region" "region"]]
{"tier" "unknown"} left-join-with "tier" column pp

# The fill must name exactly the appended right columns: no fewer, no more.
(orders customers [["customer" "customer"] ["region" "region"]] {} left-join-with)
@attempt 'err at 'kind at pp
(orders customers [["customer" "customer"] ["region" "region"]] {"tier" 'null "extra" 1}
 left-join-with)
@attempt
'err
at
'kind
at
pp

# A JSON null is ordinary data wherever it travels.
customers "tier" column pp
customers "tier" column 2 at type pp
orders customers [["customer" "customer"] ["region" "region"]]
{"tier" 'null} left-join-with "tier" column 3 at pp
