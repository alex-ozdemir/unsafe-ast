all_data=json.out

# There is a bunch of analysis done in the form:
#
#       cat fileA | jq <PROGRAM> -c > fileB
#
# This function does all of that, so long as fileB doesn't exist.
#
# If you pass "clean" to it, as the first argument, then instead it deletes all
# the produced files
#
run_jq_programs_if_needed() {
    # Unfortunately, this doesn't cover all the uses of the library
    jq_lib="./unsafe"

    # Files to produce by doing analysis
    # Important to declare them in dependency-first order.
    # Explanation of the files is below, by the programs that compute them
    declare -a files=(
    unsafe_block_sizes.txt
    unsafe_block_rel_sizes.json
    unsafe_block_requirement.json
    unsafe_block_rel_size_by_crate.txt
    unsafe_block_requirement_by_crate.txt
    unsafe_block_rel_size.txt
    unsafe_block_requirement.txt
    unsafe_uses_by_crate.json
    unsafe_uses.json
    unsafe_contexts.json
    closures.json
    closure_with_unsafe_uses_counts.txt
    inner_blocks.json
    inner_blocks_flat.json
    fns.json
    unsafe_block_counts.txt
    unsafe_fn_counts.txt
    unsafe_context_counts.txt
    )

    if [ "$1" == 'clean' ]; then
        rm ${files[@]}
        return
    fi

    declare -A files_to_programs=(
    # Computes the net size (sum of sizes over self and children) of all unsafe
    # blocks, and dumps them as a set of numbers
    [unsafe_block_sizes.txt]='. | unsafe_blocks | .blocks[] | block_net_size'

    # Conputes the relative size (self size / parent function size) of all
    # unsafe blocks in a crate, lists them, and stores this list with the crate
    # name.
    # { name, "rel_sizes": [0.5, ... ] }
    [unsafe_block_rel_sizes.json]='unsafe_blocks_rel_sizes'

    # Conputes the block requirement (percent of statements / final expression
    # in a block which require unsafe) for each block in all crates, and dumps
    # them as a set of numbers
    [unsafe_block_requirement.json]='unsafe_blocks_requirement'

    # Computes the average relative size of unsafe blocks for each crate, and
    # lists them (one number for each crate)
    [unsafe_block_rel_size_by_crate.txt]='.rel_sizes | select(length > 0) | mean'

    # Computes the average unsafe block requirement for each crate's unsafe
    # blocks, and lists them (one number for each crate)
    [unsafe_block_requirement_by_crate.txt]='.used | select(length > 0) | mean'

    # Lists all the relative sizes of all blocks in any crate, in one list
    [unsafe_block_rel_size.txt]='.rel_sizes[]'

    # Lists all the unsafe block requirements of all blocks in any crate, in
    # one list
    [unsafe_block_requirement.txt]='.used[]'

    # Makes a list of all indexed unsafe uses found in each crate, and stores
    # them by crate:
    # { name, uses: [{index, span, snippet, macro_origin, item: ... }, ...]}
    [unsafe_uses_by_crate.json]='all_unsafe_uses'
    # A list of all indexed unsafe uses (not stored by crate, just one list)
    [unsafe_uses.json]='.uses[]'

    # A list of all unsafe contexts in a crate, stored by crate. They are
    # blocks (not indexed blocks), so they include unsafe blocks and root
    # blocks of unsafe functions.
    # {name,contexts: [{size, unsaf, contexts}]}
    [unsafe_contexts.json]='{name, "contexts": ([.functions[] | select(.unsaf) | .block] + [.functions[] | blocks | select(is_unsafe_block)])}'

    # Lists all the closures which have their own unsafe uses, for each crate.
    # {name, closures: [{//closure_root_blocks//, ...}]
    [closures.json]='closures_blocks_with_unsafe_uses'

    # Lists the number of closures with unsafe uses in each crate (one number
    # per crate)
    [closure_with_unsafe_uses_counts.txt]='.closures | length'

    # For each crate, lists a summary of each inner (non-function-root) block
    # {name, blocks: [{size, unsaf, macro_origin}, ...]}
    [inner_blocks.json]='{name, "blocks": [.functions | blocks | .contents[] | select(is_indexed_block) | .macro_origin as $mo | .item.fields[0] | {size, unsaf, "macro_origin": $mo }]}'

    # Flattens out the above file, so they're no longer binned by crate. Each
    # line is:
    # {size, unsaf, macro_origin}
    [inner_blocks_flat.json]='.blocks[]'

    # For each crate, lists a summary of that crates functions:
    # {name, functions: [{unsaf, name}, ...]}
    [fns.json]='{name, "functions": [.functions[] | {unsaf, name}]}'

    # Takes in inner_blocks.json and counts the number of unsafe blocks in each
    # crate, then lists those counts (one count per crate)
    [unsafe_block_counts.txt]='[.blocks[] | select(.unsaf)] | length'

    # Takes in fns.json and counts the number of unsafe functions in each
    # crate, then lists those counts (one count per crate)
    [unsafe_fn_counts.txt]='[.functions[] | select(.unsaf)] | length'

    # Computes the total number of unsafe contexts for each crate. Lists them.
    [unsafe_context_counts.txt]='.contexts | length'
    )

    # Import the jq library into each of the above programs.
    for file in ${files[@]}; do
        files_to_programs[$file]="include \"${jq_lib}\"; ${files_to_programs[$file]}"
    done

    declare -A files_to_sources=(
    [unsafe_block_sizes.txt]=$all_data
    [unsafe_block_rel_sizes.json]=$all_data
    [unsafe_block_requirement.json]=$all_data
    [unsafe_block_rel_size_by_crate.txt]=unsafe_block_rel_sizes.json
    [unsafe_block_requirement_by_crate.txt]=unsafe_block_requirement.json
    [unsafe_block_rel_size.txt]=unsafe_block_rel_sizes.json
    [unsafe_block_requirement.txt]=unsafe_block_requirement.json
    [unsafe_uses_by_crate.json]=$all_data
    [unsafe_uses.json]=unsafe_uses_by_crate.json
    [unsafe_contexts.json]=$all_data
    [closures.json]=$all_data
    [closure_with_unsafe_uses_counts.txt]=closures.json
    [inner_blocks.json]=$all_data
    [inner_blocks_flat.json]=inner_blocks.json
    [fns.json]=$all_data
    [unsafe_block_counts.txt]=inner_blocks.json
    [unsafe_fn_counts.txt]=fns.json
    [unsafe_context_counts.txt]=unsafe_contexts.json
    )

    # Generate all the files from jq commands.
    for file in "${files[@]}"; do
        pgm="${files_to_programs[$file]}"
        src="${files_to_sources[$file]}"
        echo "Process \`$src\` to make \`$file\`?"
        if [ ! -f "${file}" ]; then
            echo "  - Running ..."
            echo "    PGM: $pgm"
            pv "${src}" | jq "${pgm}" -c > "${file}"
        else
            echo "  - Already done"
        fi
    done
}

if [ "$1" == 'clean' ]; then
    run_jq_programs_if_needed 'clean'
    exit 0
fi

# Run all the above analysis
run_jq_programs_if_needed

# Output counts of all the safe and unsafe functions and blocks, as a .md table.
safe_functions=$(cat fns.json | jq '.functions[] | select(.unsaf|not)' -c | wc -l)
total_functions=$(cat fns.json | jq '.functions[]' -c | wc -l)
unsafe_functions=$(expr $total_functions - $safe_functions)
unsafe_function_p=$(bc -l <<< "$unsafe_functions/$total_functions * 100")

safe_blocks=$(cat inner_blocks.json | jq '.blocks[] | select(.unsaf|not)' -c | wc -l)
total_blocks=$(cat inner_blocks.json | jq '.blocks[]' -c | wc -l)
unsafe_blocks=$(expr $total_blocks - $safe_blocks)
unsafe_block_p=$(bc -l <<< "$unsafe_blocks/$total_blocks  * 100")

echo '| Container Type |  Total |    Safe | Unsafe | % Unsafe |'
echo '|:-------------- |  ----- |    ---- | ------ | -------- |'
echo "| Function       | $total_functions | $safe_functions | $unsafe_functions | $unsafe_function_p |"
echo "| Block          | $total_blocks | $safe_blocks | $unsafe_blocks | $unsafe_block_p |"

# Counting the number of unsafe contexts (blocks + functions) and how many use
# only FFI or use some FFI.
unsafe_contexts=$(cat unsafe_contexts.json | jq 'include "./unsafe";.contexts[] | [get_own_uses | is_indexed_ffi_call] | all' | wc -l)
unsafe_contexts_only_ffi=$(cat unsafe_contexts.json | jq 'include "./unsafe";.contexts[] | [get_own_uses | is_indexed_ffi_call] | all | select(.)' | wc -l)
unsafe_contexts_some_ffi=$(cat unsafe_contexts.json | jq 'include "./unsafe";.contexts[] | [get_own_uses | is_indexed_ffi_call] | any | select(.)' | wc -l)
echo "There are $unsafe_contexts unsafe_contexts, $unsafe_contexts_only_ffi contains only FFI, $unsafe_contexts_some_ffi contain some FFI"

# Makes a markdown table by splitting a dataset on two axes. IE, given a set of people with
# information about the industry they work in and their salary, one could use this function
# to make a table which shows how many people have salary `S` for industry `I`, for each
# `S` and `I`.
#
# You use it by providing a list of labels and jq filters for each axis. THe jq filters should leave
# only the items that should be included under that label.
#
# Usage: file {HeadersA!} {FiltersA!} {HeadersB!} {FiltersB!} [CornerLabel]
#        where `A` is the row axis and `B` is the column axis, and {Items!}
#        means a list of Items as a single command line argument, ! delimitted.
# Example:
#
# MDTable
#           tmp.json ( say it contains  {"a":5}\n{"b":5}\n{"a":1,"b":4}  )
#           'Has a            ! No a                   ! All'
#           'select(has("a")) ! select(has("a") | not) ! .  '
#           'Has b            !                   No b ! All'
#           'select(has("b")) ! select(has("b") | not) ! .  '
#           %Omitted, intentionally%
MDTable () {
    file=$1
    IFS='!';
    read -ra headers_a <<< "$2"
    read -ra filters_a <<< "$3"
    read -ra headers_b <<< "$4"
    read -ra filters_b <<< "$5"
    echo -n '|' $6 '|'
    for j in ${headers_b[@]}; do
        echo -n ${j} '|'
    done
    echo
    echo -n '|---|'
    for j in ${headers_b[@]}; do
        echo -n '---|'
    done
    echo
    for i in ${!headers_a[@]}; do
        echo -n '|' ${headers_a[$i]} '|'
        for j in ${!headers_b[@]}; do
            fa=${filters_a[$i]}
            fb=${filters_b[$j]}
            N=$(cat $file | jq ${fa} -c | jq ${fb} -c | wc -l)
            echo -n ${N} '|'
        done
        echo
    done
}

# Makes a MD table of unsafe uses, counted by what type of macro they came from
# (if any) and what type of use they are.
if [ ! -f uses_type_cross_origin.txt ]; then
    MDTable unsafe_uses.json ' `derive` macro ! External macro ! Local macro ! Not a macro ! All sources ' 'include "./unsafe"; select(is_origin_derive_macro)!include "./unsafe"; select(is_origin_external_macro)!include "./unsafe"; select(is_origin_local_macro)!include "./unsafe"; select(is_origin_not_macro)!.' 'Deref ptr ! Call unsafe Rust function ! Call FFI ! Use `static mut` ! Use inline ASM ! All uses' 'include "./unsafe"; select(is_indexed_deref)!include "./unsafe"; select(is_indexed_unsafe_rust_call)!include "./unsafe"; select(is_indexed_ffi_call)!include "./unsafe"; select(is_indexed_mut_static)!include "./unsafe"; select(is_indexed_inline_asm)!.' Source > uses_type_cross_origin.txt
fi


# Makes a MD table of blocks, counted by what type of macro they came from (if
# any) and whether they are unsafe
if [ ! -f block_safety_cross_origin.txt ]; then
    MDTable inner_blocks_flat.json ' `derive` macro ! External macro ! Local macro ! Not a macro ! All sources ' 'include "./unsafe"; select(is_origin_derive_macro)!include "./unsafe"; select(is_origin_external_macro)!include "./unsafe"; select(is_origin_local_macro)!include "./unsafe"; select(is_origin_not_macro)!.' ' Unsafe ! Safe ! All' 'select(.unsaf) ! select(.unsaf | not) ! .' Source > block_safety_cross_origin.txt
fi
