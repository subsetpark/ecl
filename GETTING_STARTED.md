# Introduction

ECL is a programming language that combines the behaviour of the concatenative
language family—stack-oriented value semantics, reverse Polish notation, and
manipulation of program quotations—with the pervasive/conforming operations and
idiom-recognition optimization of the array language family.

The `ecl` interpreter is written in Zig, and has a very simple execution model,
directly interpreting ECL source code as a series of operations on a stack
machine. Despite the very simple structure of its interpreter, ECL has first-class module
and package systems built in for code organization, distribution, and encapsulation, and optimized typed kernels for array operations.

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

- `` `int ``: 1, 100, 1_000_000
- `` `float ``: 1.0, 1e10, inf
- `` `char ``: \a, \1, \u{1000}
- `` `symbol ``: 'a, 'hello-world
- `` `list ``: [1 2 3], (2 4 6), "hello world"
- `` `dict ``: {'hello "world"}

A couple things can be inferred from the above: 

- There is no separate `` `boolean `` type; the ints `0` and `1` are used for
  _false_ and _true_.
- There is no separate `` `string `` type; strings are lists of `` `char ``s. 
- On the other hand, there *is* a `` `char `` type separate from `` `int ``: this is
  because ECL strings are utf-8 native and thus strings are lists of
  codepoints---not just numbers.
- Lists can be constructed with either `[]` or `()`; their respective internal
  representations are identical. When displaying lists, ECL uses `[]`
  for lists of numbers and `()` for all other lists, but this is just a
    display convention.

All values in ECL are immutable. An expression like `[1] 1 +` will place two
values on the stack, then call an operator which consumes them both and
places the value `[2]` onto the stack; it won't mutate the `[1]`.

`` `dict ``s are the core associative data structure. They map _keys_ to _values_;
in ECL every value is hashable and thus can be the key of a `` `dict ``. 

`` `list ``s are the other core composite data structure. They are ordered
collections of values; like with `` `dict ``s, a list may contain any value.
`` `list ``s are not typed and may be heterogeneous (though the representation and
manipulation of a homogeneous list is more efficient than that of a list
that mixes multiple element types). As we've seen, strings are a special type
of list; a list of chars is automatically displayed as a readable string:

```
"hello world"
ecl> 1 (pop 100) update
(\h 100 \l \l \o \space \w \o \r \l \d)
```

## Symbols and Quotations

A `symbol` is an atomic value that acts as a unique identifier. All the core
words in ECL are invoked by pushing their symbols, and new programs are
constructed from lists of symbols. In the sample below, we push the symbol
`swap` onto the stack, which resolves its binding and invokes the word that
swaps the top two elements. Later we push the symbol `+` to perform addition
via the same process.

```
ecl> 3 5 swap 1 +
5 4
```

Because symbols are automatically resolved and executed when they're pushed
onto the stack, we have to *quote* a symbol with `` ` `` if we want the symbol
itself to remain on the stack.

```
ecl> `mockingbird
mockingbird
ecl> type
symbol
```

`type` indicates that the type of `mockingbird` is indeed a symbol. The value
that it leaves on the stack, `symbol`, is itself a symbol.

We use quoted symbols to provide the identifiers for binding variables:

```
ecl> 10 `my-constant set
ecl> my-constant
10
```

A word which is not bound in the current environment results in an error:

```
ecl> hotdogs
{kind undefined-word 
 msg "undefined word `hotdogs`" 
 word hotdogs 
 trace (`hotdogs) 
 data {name hotdogs 
       scope session 
       source "<repl>" 
       line 1 
       col 1}}
```

This is why we needed to say `` `my-constant `` (note the `'`) when defining a new
word; simply invoking the word directly would have caused the interpreter to
try to look it up.

As mentioned above, programs in ECL are themselves represented by lists of
symbols and literals. Pushing a list of symbols---known as a
*quotation*---places it on the stack like any other inert value:

```
ecl> 4 (1 +)
4 (1 +)
```

We can then apply that sequence simply by "unwrapping" it, which will put its
elements onto the stack (evaluating them), in order:

```
4 (1 +)
ecl> apply
5
```

Thus the equivalent in ECL to _defining a function_ is to bind a new word to a
quotation; and the equivalent to _calling a function_ is to push that quotation
onto the stack and then unwrap it. Because this is such a common operation,
the binding word `def` will create a binding which automatically unwraps the
quotation it binds when invoked:

```
ecl> (1 +) `inc def
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

A _unit_ is the basic boundary for execution and error propagation. At the most
basic level, a unit acts like a transaction, protecting the state of the stack
in case an operation inside of it raises an error. The simplest way to observe
unit behaviour is through the REPL, where every line forms a unit: 

```
ecl> 4 5
4 5
ecl> 6 7 0 div
{kind domain msg "kernel arithmetic is outside its domain" word div trace [div] data {source "<repl>" line 1 col 7}}
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
ecl> (7 0 div) @attempt
{
  `err {
    `kind `domain
    `msg "kernel arithmetic is outside its domain"
    `word `div
    `trace [div]
    `data {source "<repl>" line 1 col 6}
  }
}
ecl> type
`dict
```

This is the simplest form of error-handling in ECL: `@attempt` evaluates its
quotation in an isolated unit and then returns a _result_ dictionary, which
contains either the final result of the computation, or the first error that
was raised.

We note two differences from the REPL case: first, the resulting error is left
on the stack (we consume it by evaluating `type`). Second, the unit is isolated
from the stack below it, so any values it needs from the current stack must be
built into its quotation.[^repl] In the slightly artificial example above, the
attempted program is entirely isolated from the surrounding environment. A
slightly more realistic example pushes `7` to the left side of its quotation
with `cons`, and then attempts that quotation:

```
7
ecl> (0 div) cons @attempt
{
  `err {
    `kind `domain
    `msg "kernel arithmetic is outside its domain"
    `word `div
    `trace [div]
    `data {source "<repl>" line 1 col 4}
  }
}
```

[^repl]: The REPL is a slightly special case: because repl execution is
    strictly sequential, each execution unit can deterministically start on
    the contents of the session stack.

All unit constructors are marked with a `@`.

## Modules

ECL's modules are immutable code images that contain an enclosed set of
bindings. `<module body> <name> @defm` evaluates the body in the context of a
fresh image and then registers it globally under that name. Any bindings in
that module are then available namespaced under the name.

Modules are ECL's core primitive for encapsulation, distribution, and
application structure. There's no special syntax for module construction;
module image bodies are quotations, and @defm (as its name suggests) is a unit
constructor. Here we construct a module with one private constant and two
public words:

```
ecl> ( 10 `scale set
..        (scale *) `scale-up def
..        (scale /) `scale-down def ) `scaling @defm
ecl> 5 scaling.scale-up
50
ecl> 5 scaling.scale-down
50 0.5
ecl> scaling.scale
{kind undefined-word msg "undefined word `scaling.scale`" word scaling.scale trace (`scaling.scale) data {name scaling.scale scope qualified source "<repl>" line 1 col 1}}
```

The word @defm performs two actions: 

- It constructs a module by evaluating its quotation. The resulting bindings
  are local to that module. Public bindings are then available from outside the
  module, whereas private ones are only accessible from within it.
- It registers the module under the name provided. At that point the module's
  public bindings are available globally, namespaced under the registration
  name.

## Concurrency

The *task* is the concurrency primitive. The unit constructor `@spawn` executes
its quotation and immediately hands back a `` `task `` value, which can be
evaluated with `task.await`:

```
ecl> (1 2 /) @spawn
<task:7>
ecl> task.await
{ok [0.5]}
ecl>
```

### Message-Passing

Inter-task communication is accomplished via message-passing. Calling
`task.address` on any task handle will return its *address*, and calling
`task.send` on an address will push a message to the *mailbox* at that address. 

Conversely, calling `task.receive` inside of a task will pop a message from the
mailbox. 

Here's a trivial example:

```
ecl> (task.receive wrap "Got {} in mailbox." str.format io.print) @spawn
<task:12>
ecl> task.address 100 task.send
ecl> Got 100 in mailbox.

ecl>
```

Thus we have the scaffolding for communication between long-lived processes.

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
ecl> (|l| l sum l len /) apply
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

### Locals Slots

There is a shorthand for binding stack values to names when the actual names
are less important. The words `.x`, `.y`, `.z` bind the up-to-three top values
without having to be explicitly introduced:

```
ecl> [2 10 20] (.x sum .x len /) apply
10.666666666666666
```

# Dealing With the Stack

Here is a "stack-native" way to calculate the intersection of two arrays:

```ecl
(x y -- i)
(over has? where at) `inter def
```

We can step through it:

1. `over` copies `x` to the top of the stack. Its shape is `(x y -- x y x)`.
2. `has?` returns a mask over `y`, where `1` corresponds to every value that's
   also in `x`. It consumes `y x`: the `y` that we started with and the `x`
   that was copied in step 1.
3. `where` converts that big mask into a list of indices.
4. `at` uses the list of indices to index into the original `x`.

The entire program is a single function-composion chain; every word is applied
to the stack left by the word before it. Steps 2—4 are an efficient and
idiomatic—in the idiom of array programming—way to say "every element of `x`
that's in `y`."

But while the program lacks any elaborate application patterns, it's hard to
say that its straight-line *application structure* translates to a straight
*dataflow* line. Step one consists of the same stack-shuffling as we
encountered earlier: the manipulation of the values of the operand stack, not
through computation of values, but by swapping their order, duplicating them,
or removing them, in order to get them into the "right shape" that's expected
by the later elements of the program.

This is, for many, an unintuitive, fiddly, and clumsy thing to have to think
about. The words `has? where at` require both that the stack be shaped a
certain way before they run, and that the stack be shaped a certain way *as*
they run; the programmer must then reason backwards from those requirements to
the set of operations that go from the unmanipulated program arguments to the
required shape. In this case, the actual acrobatics required are modest—a
single shuffling word—but the type of reasoning required to arrive at them
might reasonably be considered awkward, error-prone, and rather beside the
point of the program itself.

There is thus a tension inherent in any concatenative stack language, like ECL:
the basic syntax and semantics of the language mean that function composition
and pointfree application are essentially the *natural* style; at the same
time, the raw material that enables those surface qualities can itself be
unpleasant to deal with directly.

ECL offers two supplementary approaches to compensate for this unpleasantness,
which we have just reviewed: combinators and locals. Neither one is a zero-cost
abstraction: manipulating values on the stack directly, so that they're in the
right shape, is the most direct and efficient way to write a program. But they
will very often result in a program which is easier to read, easier to think
through, and easier to modify. 

```
(x y -- i)
((pop id) (in? where) bi at) `inter def
```

Here we see another application of `bi`. In fact, `bi` applies two quotations
to the same view of the stack (not just the top value, as in the
arithmetic-mean example), and leaves both of their results in order on the top
of the stack. Those two results are then consumed by `at`.

The resulting program, while wordier than the direct solution, has an arguably
simpler overall shape: the two initial arguments are passed through two
separate functions, and the results are then combined into a single value.

Note! In the first quotation, we *still* perform some shuffling: it's passed 
`x y`, and we want to return `x` alone; so we `pop` `y` and then apply `id` to
`x` in order to "select" it. Nevertheless, we can hopefully argue that the
state management is easier to reason about in this case. There are a couple
credible reasons that this might be so: for one, removing a value is arguably
simpler than copying a value over its neighbor, and it results in a smaller
after-shape rather than a bigger one. But as importantly: we have minimized the
span of time and distance over which we must keep that state in mind, and
encapsulated it entirely within the leftmost inner quotation. We only have to
think about a concrete sequence of values and its shape for the duration of the
application of the left branch of the `bi`; after that, we can think of the
value `x` as being "returned" or "passed through" the computation.

```
(x y -- i)
(.x .x .y in? where at) `inter def
```

If the direct approach and the combinator approach form a spectrum between
efficiency and elegance, then locals arguably land somewhere in the middle. The
programmer is still asked to reason independently about stack shape—the logical
shape of "take a mask on `x` with respect to `y` and apply it to `x`", `f(x,y)
|> x` has to be inverted spatially, such that the mask-taking is bounded on
either side by `x` and `where`. On the other hand, having arrived at the stack
shape we need, we can *declare* it by simply placing the tokens representing
the arguments in their proper position, rather than *reasoning* through the
primitive moves required to go from one shape to another.

Variables in stack languages have often gotten a bit of a bad rap. It's
partially because the combinatory idiom to which concatenative languages
aspire was expressly designed to eliminate the need for them. It's also
because, when they are lexically scoped, they break the concatenative nature of
the language. A program in which `x` is bound can't be replaced, abstracted, or
moved without changing its meaning depending on the boundness of `x` in its new
lexical context.

While this latter point is technically true of locals in ECL, its blast radius
is significantly reduced, as local variables are not lexically scoped: some
quotation `(|x| ... ( ... ))` does not bind `x` in its nested quotation.

## Two Details: soft floors and `inter-len`

The set-intersection example occurred to me during the exercise of writing out
a program to calculate the Jaccard similarity of two arrays---`|x∩y| ÷ |x∪y|`.
We can write a program:

```ecl
### def inter
([pop id] [in? where] bi at) `inter def

### def union
(cat distinct) `union def

### def jaccard
([inter] [union] bi [len] both /) `jaccard def
```

First I want to elaborate on the behaviour of `bi`. The Factor word `bi` is
unary: it grabs an element from the top of the stack, and passes it as an
agument to two different quotations. It would thus be unsuitable for
application in `inter`, which needs two values. In Factor we'd reach for `2bi`,
which, as its name implies, consumes two values, not one.

ECL doesn't have separate-arity versions of its important combinators. Instead,
the combinators execute with a so-called *soft floor*, which dynamically
measures the lowest consumed element of the stack by any of their applications,
and use that to decide how many elements should be consumed after the
combinator is finished. This allows us to apply quotations of arbitrary arity
with the same word.

This example also demonstrates one of the knock-on effects of this choice:
because `bi` doesn't have a fixed arity, we need to infer which values are
"returned" by each application. In the case of the left application in `inter`,
which wants to "select" `x` from `x` and `y`, simply popping `y` off the stack
isn't enough. We need to "touch" the intended value with `id`, which would
otherwise be a no-op. 

The Jaccard example is also a good one to demonstrate ECL's array semantics. In
this case we're not actually interested in the intersection or sum; we're only
interested in the numbers of their elements. We can thus write a new version of
the program:

```ecl
### def inter-len
(in? sum) `inter-len def

### def union-len
((pop len) (len) (inter-len) tri - +) `union-len def

### def jaccard
([inter-len] [union-len] bi /) `jaccard def
```

I note in passing that we can define the size of a union in terms of the size
of the intersection. I want to draw attention to `inter-len`, which has dropped
to just two words: `in? sum`. The conforming semantics of `in?` mean that "mark
the elements of `x` that are in `y`" is a single vectorized operation,
resulting in a bitmask; we can then sum the 1s in the mask. Thus we avoid not
only iterating over each element of `x`, but also constructing the intersection
array if all we need is its cardinality.

# How to Manage State

Every value in an ECL program is immutable. The ECL equivalent to mutating some
value is to pop it from the stack and push an updated version to the stack in
its place.

Thus, the unit of state in ECL is the unit of concurrency: the *task*, each one
of which has its own stack.

The `agent` module provides utility words, built on top of `task.receive`
and `task.send`, for defining stateful tasks that can communicate via
message-passing. A trivial example: 

```ecl
ecl> (
..    (0 agent.start) `init def
..    ((1 +) agent.send) `inc def
..    ((dup) agent.call) `get def
.. ) `counter @defm
ecl> counter.init `c set
ecl> c counter.inc
ecl> c counter.inc
ecl> c counter.get
2
```

We define a module `counter` which exposes a few words for starting and
communicating with a stateful counter task.

- `init` calls `agent.start` with an initial state, which will push the
  resulting address on the stack;
- `inc` expects an address on the stack and applies `agent.send` with a quotation
  to be applied to the current state;
- `get` expects an address on the stack and applies `agent.call` with a
  quotation. While `agent.send` simply applies the quotation inside the task,
  `agent.call` applies the quotation and then sends back the top value on the
  task stack.

At that point, creating a persistent stateful object is just a matter of
initiating the counter and then assigning the resulting address to a name.

We can then interact with the counter by applying `counter` words to its address. `inc` mutates the state in the task stack; `get` returns a value to the caller.
