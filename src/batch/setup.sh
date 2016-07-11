#!/usr/bin/zsh

main () {

    ensure curl https://sh.rustup.rs -sSf | sh -s -- --default-toolchain nightly -y

    ensure source ~/.profile

    cargo install cargo-clone

    toolchain_name=$(ls ~/.multirust/toolchains | grep nightly | head -n 1)

    assert_nz "$toolchain_name"

    ensure cargo build --release

    ensure mkdir -p bin

    ensure mkdir -p output

    ensure cp ./target/release/emit-ast ./bin/rustc

    ensure ln -s "$HOME/.multirust/toolchains/$toolchain_name/lib" lib

    ensure rustup toolchain link emit-uast .

    ensure cargo run --bin download --release
}

say() {
    echo "setup: $1"
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

need_ok() {
    if [ $? != 0 ]; then err "$1"; fi
}

assert_nz() {
    if [ -z "$1" ]; then err "assert_nz $2"; fi
}

# Run a command that should never fail. If the command fails execution
# will immediately terminate with an error showing the failing
# command.
ensure() {
    "$@"
    need_ok "command failed: $*"
}

# This is just for indicating that commands' results are being
# intentionally ignored. Usually, because it's being executed
# as part of error handling.
ignore() {
    run "$@"
}

# Runs a command and prints it to stderr if it fails.
run() {
    "$@"
    local _retval=$?
    if [ $_retval != 0 ]; then
        say_err "command failed: $*"
    fi
    return $_retval
}

run main
