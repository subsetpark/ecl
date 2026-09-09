# Introduction

ECL is a programming language that combines the behaviour of the concatenative
language family—stack-oriented value semantics, reverse Polish notation, and
manipulation of program quotations—with the pervasive/conforming operations and
idiom-recognition optimization of the array language family.

The `ecl` interpreter is written in Zig, and has a very simple execution model,
directly interpreting ECL source code as a series of operations on a stack
machine. While there is no compilation step, ECL has first-class module
and package systems built in for code organization, distribution, and encapsulation.

# Getting ECL

ECL is hosted at (https://github.com/subsetpark/ecl). It currently doesn't
provide prebuilt binaries. It's written in Zig; to install it clone the repo
and issue a command like

`zig build --release=fast --prefix ~/.local`

Which will compile the interpreter and copy it into `~/.local/bin`. This
directory is in most users' `PATH`.

To enter the ECL repl, run `ecl`:

```
⊕ ecl
ecl>
```

This will create an ECL session which behaves identically to the session
created from directly executing an ECL program. The REPL will display the
current contents of the stack before the prompt.

```
ecl> 10 range (+)
[0 1 2 3 4 5 6 7 8 9] (+)
ecl> fold1
45
ecl>
```

# Concepts

ECL is a dynamic, interpreted language. This means that values have types, but
variables don't; and that code is executed directly by the `ecl` interpreter,
rather than being compiled directly into machine code or into some lower-level
representation.

There are 6 core value types capable of being constructed directly from program
text: 

- `'int`: 1, 100, 1_000_000
- `'float`: 1.0, 1e10, inf
- `'char`: \a, \1, \u{1000}
- `'symbol`: 'a, 'hello-world
- `'list`: [1 2 3], (2 4 6), "hello world"
- `'dict`: {'hello "world"}

A couple things can be inferred by the above: 

- There is no separate `'boolean` type; the ints `0` and `1` are used for
  _false_ and _true_.
- There is no separate `'string` type; strings are lists of `'char`s. 
- On the other hand, there *is* a `'char` type separate from `'int`: this is
  because ECL strings are utf-8 native and thus strings are lists of
  codepoints---not just numbers.
- Lists can be constructed with either `[]` or `()`; their respective internal
  representations are identical. When displaying lists, ECL uses `[]`
  for lists of numbers and `()` for all other lists, but this is just a
    display convention.

All values in ECL are immutable. An expression like `[1] 1 +` will place two
values on the stack, then call an operator which consumes them both and
places the value `[2]` onto the stack; it won't mutate the `[1]`.

`'dict`s are the core associative data structure. They map _keys_ to _values_;
in ECL every value is hashable and thus can be the key of a `'dict`. 

`'list`s are the other core composite data structure. They are ordered
collections of values; like with `'dict`s, a list may contain any value.
`'list`s are not typed and may be heterogeneous (though the representation and
manipulation of a homogeneous list might be more efficient than that of a list
that mixes multiple element types). As we've seen, strings are a special type
of list; a list of chars is automatically displayed as a readable string:

```
"hello world"
ecl> 1 (pop 100) update
(\h 100 \l \l \o \space \w \o \r \l \d)
```

## Words, Symbols, and Quotations

The first type that's not trivially constructable via literals is the `'word`.
If the values we've covered are effectively values which evaluate to
themselves, then a word is effectively a value which, when evaluated (by being
placed on the _operand stack_), are treated as a binding to be looked up in the
current environment.

Thus the `'word` is the core primitive out of which ECL programs are composed.
This includes built-in words that are implemented directly in the ECL
interpreter:

```
ecl> 3 5 swap 1 +
5 4
```

As well as words which are introduced by ECL programs:

```
ecl> 10 'my-constant set
ecl> my-constant
10
```

A word which is not bound in the current environment results in an error:

```
ecl> hotdogs
{'kind 'undefined-word 
 'msg "undefined word `hotdogs`" 
 'word 'hotdogs 
 'trace ['hotdogs] 
 'data {'name 'hotdogs 'scope 'session 'source "<repl>" 'line 1 'col 1}}
```

This is why we needed to say `'my-constant` (note the `'`) when defining a new
word; simply invoking the word directly would have caused the interpreter to
try to look it up.

Pushing a word onto the stack causes the interpreter to execute that word.
Thus, whenever we want to manipulate or mention a sequence of words rather than
execute them directly, we _quote_ them by wrapping them in a list:

```
ecl> 4 (1 +)
4 (1 +)
```

We can then call that sequence simply by "unwrapping" it and putting its
elements onto the stack, in order:

```
4 (1 +)
ecl> call
5
```

Thus the equivalent in ECL to _defining a function_ is to bind a new word to a
quotation; and the equivalent to _calling a function_ is to push that quotation
onto the stack and then unwrap it. Because this is such a common operation,
the binding word `def` will create a binding which automatically unwraps the
quotation it binds when invoked:

```
ecl> (1 +) 'inc def
ecl> 4 inc
5
```

## Arrays

There is no standalone _array_ or _matrix_ type. As we've seen, homogeneous
lists of numbers aren't represented with a special type; nor are
multidimensional arrays—they're also just lists of lists:

```
ecl> 10 range [3 3] reshape
([0 1 2]
 [3 4 5]
 [6 7 8])
```

Nevertheless, the core operators in ECL _pervade_ into lists in predictable
ways:

```
ecl> inc
([1 2 3]
 [4 5 6]
 [7 8 9])
```

They also _conform_ given compatible operand shapes:

```
ecl> [1 2 3] *
([1 2 3]
 [8 10 12]
 [21 24 27])
```

This allows for greater efficiency in syntax and execution, and idiomatic ECL
style often involves modeling a program as a series of whole-array operations,
rather than iterating over values one-by-one.

## Units and Errors

An _execution unit_, or _unit_ for short, is the basic boundary for execution
and error propagation. At the most basic level, a unit is simply a new stack,
separate from the context from which it was called. This new stack evaluates
some program and then the resulting stack is handed back. The simplest way to
observe unit behaviour is through the REPL, where every line forms a unit: 

```
ecl> 4 5
4 5
ecl> 6 7 0 /
{'kind 'domain 'msg "kernel arithmetic is outside its domain" 'word '/ 'trace ['/] 'data {'source "<repl>" 'line 1 'col 7}}
ecl>
4 5
ecl>
```

Here we place `4 5` on the stack; we then place `6` on the stack, and in the
same invocation try dividing `7` by `0`---a domain error. Each input line to
the REPL constructs a new unit, so the failed computation of the second input
can be handled in isolation from the prior state. The error boundary
around the line entry preserves the elements `4 5`, while `6`---which was not
consumed by the division-by-zero---is rolled back. It's worth highlighting that
in the REPL, while the transaction error is displayed to the user, it's not
left on the stack.

In a running program, there's no natural analog to a "REPL line"; instead we
use words that construct units and execute them in isolation, and return the
value to the calling stack. The simplest way to construct a unit is with
`@attempt`:

```
ecl> [] (7 0 /) @attempt
{
  'err {
    'kind 'domain
    'msg "kernel arithmetic is outside its domain"
    'word '/
    'trace ['/]
    'data {'source "<repl>" 'line 1 'col 9}
  }
}
ecl> type
'dict
```

This is the simplest form of error-handling in ECL: `@attempt` evaluates its
quotation in an isolated stack and then returns a _result_ dictionary, which
contains either the final result of the computation, or the first error that
was raised.

We note two differences from the REPL case: first, the resulting error is left
on the stack (we consume it by evaluating `type`). Second, `@attempt` consumes
two operands. Before the quotation it expects a _seed list_. Because units
construct a new, isolated stack, the stack must be explicitly seeded with any
required values from the current stack.[^repl] In the slightly artificial
example above, the attempted program is entirely isolated from the surrounding
environment. A slightly more realistic example will seed the unit stack with
values from the environment and then attempt to execute the quotation on the
seeded stack:

```
7
ecl> wrap (0 /) @attempt
{
  'err {
    'kind 'domain
    'msg "kernel arithmetic is outside its domain"
    'word '/
    'trace ['/]
    'data {'source "<repl>" 'line 1 'col 9}
  }
}
```

[^repl]: The REPL is a slightly special case: because repl execution is
    strictly sequential, each execution unit can be deterministically seeded
    with the contents of the session stack.

All unit constructors are marked with a `@`.

## Modules

ECL's module system consists of two parts: _module images_ and _module
registrations_. The most common way to use a module is to create an image and
then immediately register it, so we'll introduce them as a single action.

Modules are ECL's core primitive for encapsulation, distribution, and
application structure. There's no special syntax for module construction;
module image bodies are quotations, and @defm (as its name suggests) is a unit
constructor that consumes a seed and a quotation:

```
ecl> [] ( 10 'scale setp
..        (scale *) 'scale-up def
..        (scale /) 'scale-down def ) 'scaling @defm
ecl> 5 scaling.scale-up
50
ecl> 5 scaling.scale-down
50 0.5
```

The word @defm performs two actions: 

- It constructs a module by evaluating its quotation. The resulting bindings
  are local to that module. Public bindings are then available from outside the
  module, whereas private ones are only accessible from within it.
- It registers the module under the name provided. At that point the module's
  public bindings are available globally, namespaced under the registration
  name.

## Concurrency

The execution unit is also the basic unit of concurrency. The unit constructor
`@spawn` executes its quotation and immediately hands back a `'task` value,
which can be evaluated with `task.await`:

```
ecl> [] (1 2 /) @spawn
<task:7>
ecl> task.await
{'ok [0.5]}
ecl>
```

## Combinators

ECL provides a robust inventory of so-called _combinators_---words which take
one or more quotation and apply them to the stack in predetermined patterns.
That is, combinators don't perform business logic themselves, but provide
access to _shapes_ of business logic that are likely to recur often.

This is both tremendously powerful and necessary. Powerful because once you
learn to recognise them, you'll see these shapes everywhere; necessary because
their alternative is arguably the most unpleasant part of programming in a
concatenative language: a lot of stack-shuffling words, like `dup`, `swap`,
`nip`, and friends. Here's a relatively benign example---taking the arithmetic
mean of a list of numbers:

```
[2 10 20]
ecl> dup sum swap len /
10.666666666666666
```

Two of the five words are dedicated to stack-shuffling: `dup` replicates the
top value on the stack, and after taking the `sum` of that value, `swap` flips
the sum with the other copy of the original list so that we can take its `len`.
At that point, the sum and the length are on the top of the stack in the right
order, so we can push `/` to divide. An arguably friendlier, combinatory
approach is this:

```
[2 10 20]
ecl> (sum) (len) bi /
10.666666666666666
```

`bi` has semantics equivalent to `dup f swap g`, but abstracts over the stack
operations and lets the programmer think more directly: "apply two quotations
to the same value", without having to reason about stack state.

## Locals

Here's another way to write the same program:

```
[2 10 20]
ecl> (|l| l sum l len /) call
10.666666666666666
```

In this case we have applied a quotation that begins with the form
`|x [y ...]|`--which is translated by the reader into:

```
ecl> (|l| l sum l len /)
(1 _ll 0 _gl sum 0 _gl len / 1 _dl)
```

The words `_ll`, `_gl`, and `_dl` form a small system for consuming elements on
the top of the stack and binding them to words inside of the current quotation.
As can be seen in the quoted program, bound locals can then be pushed to the
stack wherever they're needed, once again saving the programmer from having to
mentally model stack operations whenever a value needs to be either reused or
deferred until later in a quotation.
