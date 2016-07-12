# Alex Ozdemir <aozdemir@hmc.edu>
#
# This file holds the analysis I did in preparing this post:
# https://alex-ozdemir.github.io/rust/unsafe/unsafe-in-rust-syntactic-patterns/
#
# # The Structure of the Unsafe AST
#
# The best place to start learing the structure is by looking at the Rust
# struct itself (if you're familiar with Rust). It may be found in
# src/emit-ast/unsafe_ast.rs, at the top of the file.
#
# As for what that looks like once rustc_seriliaze encodes it as JSON, an
# example might be the best explanation:
#
# ```json
# {
#   "name": "hi",
#   "ty": "CrateTypeExecutable",
#   "functions": [
#     {
#       "name": "main",
#       "unsaf": false, "span": "...",
#       "macro_origin": "NotMacro",
#       "block": {
#         "size": 3,
#         "unsaf": false,
#         "unsafe_points": [
#           {
#             "index": 2, "span": "...", "snippet": "...",
#             "macro_origin": "NotMacro",
#             "item": {
#               "variant": "Call",
#               "fields": [ { "unsaf": false }, { "is_ffi": false } ]
#             }
#           },
#           {
#             "index": 2, "span": "...", "snippet": "...",
#             "macro_origin": "NotMacro",
#             "item": {
#               "variant": "Block",
#               "fields": [
#                 {
#                   "size": 1,
#                   "unsaf": true,
#                   "unsafe_points": [
#                     {
#                       "index": 0, "span": "...", "snippet": "...",
#                       "macro_origin": "NotMacro",
#                       "item": "Deref"
#                     }
#                   ]
#                 }
#               ]
#             }
#           }
#         ]
#       }
#     }
#   ]
# }
# ```

###########
# Utility #
###########

#takes an array
def sum: reduce .[] as $item (0; . + $item);

#takes an array
def mean: (sum) / (length);


#########################################################
# Test operations: see if some part of the tree is an X #
#                                                       #
#  these should never crash or actually change the data #
#########################################################

# Checks if some json value is a block (not an indexed block)
def is_block: type == "object" and has("contents");

def is_unsafe_block: is_block and .unsaf;

def is_safe_block: is_block and (.unsaf | not);

def is_closure: type == "object" and has("variant") and .variant == "Closure";

def is_indexed: has("item");

def is_indexed_deref: is_indexed and (.item == "Deref");

def is_indexed_call: is_indexed and (.item | type == "object") and (.item.variant == "Call");

def is_indexed_unsafe_call: is_indexed_call and .item.fields[0].unsaf;

def is_indexed_ffi_call: is_indexed_unsafe_call and .item.fields[1].is_ffi;

def is_indexed_unsafe_rust_call: is_indexed_unsafe_call and (.item.fields[1].is_ffi | not);

def is_indexed_inline_asm: is_indexed and (.item == "InlineASM");

def is_indexed_mut_static: is_indexed and (.item == "MutStatic");

def is_indexed_block: is_indexed and (.item | type == "object") and (.item.variant == "InnerBlock");

def is_indexed_unsafe_block: is_indexed_block and .item.fields[0].unsaf;

def is_indexed_closure: is_indexed and (.item | type == "object") and (.item.variant == "Closure");

def is_indexed_container: is_indexed_block or is_indexed_closure;

def is_indexed_use: is_indexed and (is_indexed_deref or is_indexed_call or is_indexed_inline_asm or is_indexed_mut_static);

def is_indexed_unsafe_use: is_indexed and (is_indexed_deref or is_indexed_unsafe_call or is_indexed_inline_asm or is_indexed_mut_static);

###########################################################################
# Origin test operations: see if some part of the tree has macro_origin X #
###########################################################################

def is_origin_not_macro: .macro_origin == "NotMacro";

def is_origin_local_macro: .macro_origin == "LocalMacro";

def is_origin_external_macro: .macro_origin == "ExternalMacro";

def is_origin_derive_macro: .macro_origin == "DeriveMacro";

############################################################
# Block operations: Takes in a block, gives yout something #
############################################################

def get_child_blocks: .contents[] | select(is_indexed_block) | .item.fields[0];

def get_indexed_child_containers: .contents[] | select(is_indexed_closure or is_indexed_block);

def get_child_containers: .contents[] | select(is_indexed_closure or is_indexed_block) | .item.fields[0];

def get_safe_child_blocks: get_child_blocks | select(is_safe_block);

def get_shallow_uses: .contents | .[] | select(is_indexed_use);

# Get all uses in this block.
def get_all_uses: recurse(get_child_containers; is_block) | get_shallow_uses;

# Get all uses that would 'use' this block if they were unsafe.
def get_own_uses: recurse(get_child_containers; is_safe_block) | get_shallow_uses;

# Takes a block, gets the accumulation of it and it's children's sizes
def block_net_size: [recurse(get_child_containers; is_block) | .size] | (. | sum);

def block_net_size_2: def r: ([get_child_containers | r] | sum) as $sum | ([get_indexed_child_containers | .index] | unique | length) as $stmnts_w_blocks | .size + $sum - $stmnts_w_blocks; r;

# Given a block, produces a list of statement / final expression indices that require unsafe.
def used_indices: [.contents[] | .index as $idx | if is_indexed_unsafe_use then $idx else if is_indexed_container and (is_indexed_unsafe_block | not) and ((.item.fields[0] | get_own_uses | length) > 0) then $idx else false end end | select(. != false)] | unique;

# What fraction of the statements/final expressions in a block require unsafe
def block_requirement: if .size > 0 then (used_indices | length) / .size else 0.0 end;

############################################################
# Versatile Getters: Get all X in any subtree              #
############################################################

# Gets all the blocks in any subtree of the AST (very versatile)
def blocks: .. | select(is_block) ;

# Get all the root blocks of all closures
def closure_blocks: .. | select(is_closure) | .fields[0];

#############################################################################
# Analysis Functions: Used directly (or near directly) in the data analysis #
#############################################################################

# Takes in a UAST
def closure_blocks_with_unsafe_uses: {name, "closures": [ .functions[] | closure_blocks | select([get_own_uses] | map(is_indexed_unsafe_use) | any)]};

# Takes in a UAST
def closure_blocks_with_all_unsafe_uses: {name, "closures": [ .functions[] | closure_blocks | select([get_all_uses] | map(is_indexed_unsafe_use) | any)]};

# Takes in a UAST
def unsafe_blocks: {name, "blocks": [.functions | blocks | get_child_blocks | select(is_unsafe_block)]};

# Takes in a UAST
def all_unsafe_uses_in_unsafe_declarations: [.functions[] | select(.unsaf) | .block] as $ufnblocks | unsafe_blocks | {name, "uses": [(.blocks + $ufnblocks) | .[] | get_own_uses | select(is_indexed_unsafe_use)]};

# Takes in a UAST
def all_unsafe_uses: {name, "uses": [.functions[].block | get_all_uses | select(is_indexed_unsafe_use)]};

# Takes in a UAST
def unsafe_blocks_with_functions: {name, "blocks": [ .functions[] | . as $fn | blocks | select(is_unsafe_block) | {"parent": $fn.block, "child": .} ]};

# Takes in an object {parent: BLOCK, child: BLOCK}
def block_relative_size: (.child | block_net_size_2) as $csize | (.parent | block_net_size_2) as $psize | if $psize > 0 then $csize / $psize else 1.0 end;

# Takes in a UAST
def unsafe_blocks_rel_sizes: unsafe_blocks_with_functions | {name, "rel_sizes": ([.blocks[] | block_relative_size] )};

# Takes in a UAST
def unsafe_blocks_requirement: {name, "used": ([.functions[] | blocks | select(is_unsafe_block) | block_requirement ] )};

