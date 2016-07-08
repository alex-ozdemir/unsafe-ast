#!/bin/sh

main () {
    crate_name="$1"
    output_file="../../output/$crate_name.out"
    assert_nz "$crate_name"
    cd sources
    if [[ ! -a "$crate_name" ]]; then
        eval cargo clone $crate_name > /dev/null
    fi
    if [[ -a $crate_name ]]; then
        cd "$crate_name"
        rustup run emit-uast cargo build --verbose > "$output_file" 2>&1
        # Remove the final binaryies. We don't use `clean` to avoid rebuilding deps.
        rustup run emit-uast cargo clean --verbose >> "$output_file" 2>&1
        cd ..
    fi
    cd ..
}

assert_nz() {
    if [ -z "$1" ]; then err "assert_nz $2"; fi
}

main "$@"
