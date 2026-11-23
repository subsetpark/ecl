## dict

### associate

#### Examples

```ecl
`args ["inspect" "alpha"] dict.associate
# => {args ["inspect" "alpha"]}
```

### zip

#### Examples

```ecl
[a b] [1 2] dict.zip
# => {a 1 b 2}
```

### map

#### Examples

```ecl
{a 1 b 2} (swap pop 10 *) dict.map
# => {a 10 b 20}
```

### merge

#### Examples

```ecl
{a 1 b 2} {b 20 c 30} dict.merge
# => {a 1 b 20 c 30}
```

### split

#### Examples

```ecl
{a 1 b 2} [b] dict.split pair
# => ({b 2} {a 1})
```
