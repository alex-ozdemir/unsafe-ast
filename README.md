# Unsafe AST

A project to
   1. Syntactically analyze how `unsafe` is used in Rust.
   2. Make that analysis easy to do.

Where "easy to do" means you don't actaully have to compile any crates or even
write any Rust.

Currently, you can get analyzing using just the command line tool [`jq`][jq]

## Quickstart

### Step 1: Clone Repo & Install

Clone this repository and install `jq`. There are a few ways to install `jq`,
including your package manager (`pacman -S jq` for me) and the [website][jq].

Getting `pv` (pipe view) might also be helpful, so you can know how fast your
analysis is going. It should be installable using your package manager. I was
able to run (`pacman -S pv`).

### Step 2: Unzip the data.

Go into the data and analysis folder:

```bash
$ cd data-analysis
```

Unzip either `2016-07-11.zip` or `2016-07-11.tar.gz`, whichever is easier for
you. Doing this might look like

```bash
$ tar -xvzf 2016-07-11.tar.gz
```

### Step 3: Analyze

The file `json.out` should now exist, and should be huge (over 400 MB).
Nevertheless, we can do some cool analysis on it. It have info about once crate
on each line, as a JSON object. That JSON object includes a list of functions,
and functions are just a tree of blocks, closures, and uses (raw pointer
derefs, fn_calls, interactions with mutable statics). Rather than explaining
the structure in detail, lets look at an example. The Rust program:

```rust
fn main() {
    let x: isize = 5;
    let p: *const isize = &x;
    isize::min_value() + unsafe { *p };
}
```

has UnsafeAST

```json
{
  "name": "hi",
  "ty": "CrateTypeExecutable",
  "functions": [
    {
      "name": "main",
      "unsaf": false, "span": "...",
      "macro_origin": "NotMacro",
      "block": {
        "size": 3,
        "unsaf": false,
        "contents": [
          {
            "index": 2, "span": "...", "snippet": "...",
            "macro_origin": "NotMacro",
            "item": {
              "variant": "Call",
              "fields": [ { "unsaf": false }, { "is_ffi": false } ]
            }
          },
          {
            "index": 2, "span": "...", "snippet": "...",
            "macro_origin": "NotMacro",
            "item": {
              "variant": "Block",
              "fields": [
                {
                  "size": 1,
                  "unsaf": true,
                  "contents": [
                    {
                      "index": 0, "span": "...", "snippet": "...",
                      "macro_origin": "NotMacro",
                      "item": "Deref"
                    }
                  ]
                }
              ]
            }
          }
        ]
      }
    }
  ]
}
```

(some strings have been omitted). For a full specification of the AST, check
out the source file `src/rust/emit-ast/unsafe_ast.rs`, which starts off with
the specification for the data structure.

At any rate, we can get started doing some analysis. If we wanted a list of all
the crates with unsafe functions we could run:

```bash
$ pv json.out | jq 'select(.functions | map(select(.unsaf)) | length > 0) | .name' -c \
crates_with_unsafe_fns.txt
```

and we could turn the above list into a count by running

```bash
$ wc -l crates_with_unsafe_fns.txt
```

We can also do more sophisticated analysis using some of the helpers defined in
`unsafe.jq`. To use these helpers, we just have to include `include "unsafe";`
at the beginning of our jq program. As an example, lets look at the unsafe
operations performed in the `abort_on_panic` crate:

```bash
$ pv json.out | jq 'include "unsafe"; select(.name == "abort_on_panic") | .functions[].block | get_all_uses | select(is_indexed_unsafe_use)' > unsafe_uses.json
```

Let's break that command down into steps:
   1. `pv json.out | jq'`: We input the data into `jq`  using `pv` (`cat` could
      be used instead of `pv`, but then we wouldn't get information about how
      fast the analysis was running).
   2. `include "unsafe";`: We include the helper functions.
   3. `select(.name == "abort_on_panic") |`: we select only the crate we're
      interested in.
   4. `.functions[].block |`: We get the array of functions for the crate, split
      the array into separate objects/lines/inputs, and select read the .block
      field for each object.
   5. `get_all_uses |`: We get all the uses for each of these blocks (which are
      the root blocks of all the functions in the crate).
   6. `select(is_indexed_unsafe_use)`: We keep only the (indexed) uses which
      are unsafe.

The only output is:
```json
{
  "index": 0,
  "span": "src/lib.rs:57:22: 57:29",
  "snippet": "abort()",
  "macro_origin": "NotMacro",
  "item": {
    "variant": "Call",
    "fields": [
      {
        "unsaf": true
      },
      {
        "is_ffi": true
      }
    ]
  }
}
```

and if we go the repository for this crate, and check out the the span
indicated ([here][abort-on-panic-line]), then we see the unsafe function call
which is being refered to.

### Step 4: Do Awesome Things

And this is where the guided trail ends. If you've got troubles, questions, or
awesome ideas, I'm here - feel free to email me (my email address is on
github).

I'm also going to keep a list of cool stuff that comes out of this work, let me
know if you'd like me to put your thing on it:

## Analyses

This is a list of analysis work that has been done so far on Unsafe ASTs:

   * [Unsafe in Rust: Syntactic Patterns][alex-ozdemir-1]

[alex-ozdemir-1]: https://alex-ozdemir.github.io/rust/unsafe/unsafe-in-rust-syntactic-patterns/
[jq]: https://stedolan.github.io/jq/
[abort-on-panic-line]: https://github.com/emk/abort_on_panic-rs/blob/master/src/lib.rs#L57
