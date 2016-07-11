#!/bin/sh

main() {
    # Set up the list of crates
    filename=crate-list.txt
    cargos=12
    procs_per_cargo=3
    if [ ! -z "$1" ]; then filename=$1; fi

    source ~/.profile

    need_cmd cargo

    if [ ! -e sources ]; then
        mkdir -p sources/.cargo
        echo "[build]
jobs = $procs_per_cargo" > sources/.cargo/config
    fi

    cat $filename | xargs -n 1 --max-procs="$cargos" sh analyze-crate.sh
}


say() {
    echo "rustup: $1"
}

say_err() {
    say "$1" >&2
}

err() {
    say "$1" >&2
    exit 1
}

need_cmd() {
    if ! command -v "$1" > /dev/null 2>&1
    then err "need '$1' (command not found)"
    fi
}

main "$@"
