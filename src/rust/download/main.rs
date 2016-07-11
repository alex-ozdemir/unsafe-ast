extern crate glob;
extern crate rustc_serialize;

use std::collections::HashMap;
use std::io::prelude::*;
use std::io::BufReader;
use std::fs::{self, File};
use std::process::Command;

// Taken from Houn Wilson's https://github.com/huonw/crates.io-graph
#[derive(RustcDecodable)]
#[allow(dead_code)]
struct CrateInfo {
    name: String,
    vers: String,
    deps: Vec<DepInfo>,
    cksum: String,
    features: HashMap<String, Vec<String>>,
    yanked: bool,
}

#[derive(RustcDecodable)]
#[allow(dead_code)]
struct DepInfo {
    name: String,
    req: String,
    features: Vec<String>,
    optional: bool,
    default_features: bool,
    target: Option<String>,
    kind: Option<String>
}

// shallowly download the index, if necessary
fn fetch_index() {
    if fs::metadata("crates.io-index").is_ok() {
        return
    }

    Command::new("git")
        .arg("clone")
        .arg("--depth").arg("1")
        .arg("https://github.com/rust-lang/crates.io-index")
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
}

fn write_crates(f: &mut File) {
    fetch_index();

    let mut opts = glob::MatchOptions::new();
    opts.require_literal_leading_dot = true;

    let index_paths1 = glob::glob_with("crates.io-index/*/*/*", &opts).unwrap();

    let index_paths2 = glob::glob_with("crates.io-index/[12]/*", &opts).unwrap();

    for path in index_paths1.chain(index_paths2) {
        let path = path.unwrap();

        let file = File::open(&path).unwrap();
        let last_line = BufReader::new(file).lines().last().unwrap().unwrap();
        let crate_info: CrateInfo = rustc_serialize::json::decode(&*last_line).unwrap();

        writeln!(f, "{}", crate_info.name).expect("Write failed");
    }
}

fn main() {
    let mut f = File::create("crate-list.txt").expect("File creation failed");
    write_crates(&mut f);
}
