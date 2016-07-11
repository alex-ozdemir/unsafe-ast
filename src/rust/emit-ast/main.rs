#![feature(box_syntax,box_patterns,rustc_private)]
// Alex Ozdemir <aozdemir@hmc.edu>
// Tool for counting unsafe invocations in an AST

extern crate getopts;
extern crate syntax;
#[macro_use] extern crate rustc;
extern crate rustc_driver;
extern crate rustc_serialize;
extern crate rustc_data_structures;

mod unsafe_ast;

use rustc_serialize::json;

use rustc::hir;
use rustc::ty;
use rustc::session::{config,Session};

use rustc_driver::{driver,CompilerCalls,RustcDefaultCalls,Compilation};
use rustc_driver::driver::CompileState;

use syntax::diagnostics;

use std::io::Write;
use std::mem;
use std::path::PathBuf;

macro_rules! errln(
    ($($arg:tt)*) => { {
        let r = writeln!(&mut ::std::io::stderr(), $($arg)*);
        r.expect("failed printing to stderr");
    } }
);

fn emit_unsafe_ast<'a,'tcx,'ast>(crate_name: String,
                                 crate_type: String,
                                 krate: &hir::Crate,
                                 session: &'ast Session,
                                 tcx: ty::TyCtxt<'a,'tcx,'tcx>) {
    // Hack to prevent dumping results from dependency builds.
    // Cargo calls these "build_script_build" for some reason.
    if crate_name != "build_script_build" {
        let mut v = unsafe_ast::UnsafeASTEmitter::new(tcx, session, crate_name, crate_type);
        krate.visit_all_items(&mut v);
        let uast = v.into_uast();
        errln!("{}", json::as_json(&uast));
    }
}

/// A complier calls structure which behaves like Rustc, less running a callback
/// post-analysis.
pub struct AnalyzeUnsafe<'a> {
    default: RustcDefaultCalls,
    do_analysis: bool,
    after_analysis_callback: Box<Fn(&mut CompileState) + 'a>,
}

impl<'a> AnalyzeUnsafe<'a> {
    pub fn new(after_analysis_callback: Box<Fn(&mut CompileState) + 'a>) -> AnalyzeUnsafe<'a> {
        AnalyzeUnsafe {
            default: RustcDefaultCalls,
            do_analysis: true,
            after_analysis_callback: after_analysis_callback,
        }
    }

    pub fn unsafe_ast_emitter() -> AnalyzeUnsafe<'a> {
        AnalyzeUnsafe::new(Box::new(move |state| {
            let krate = state.hir_crate.expect("HIR should exist");
            let tcx = state.tcx.expect("Type context should exist");
            let session = state.session;
            let crate_name = state.crate_name.unwrap_or("????");
            let crate_type = state.session.opts.crate_types.iter()
                .next().map(|t| format!("{:?}",t)).unwrap_or("????".to_string());
            emit_unsafe_ast(crate_name.to_string(), crate_type, krate, session, tcx);
        }))
    }
}

impl<'a,'callback: 'a> CompilerCalls<'a> for AnalyzeUnsafe<'callback> {
    fn early_callback(&mut self,
                      matches: &getopts::Matches,
                      sopts: &config::Options,
                      descriptions: &diagnostics::registry::Registry,
                      output: config::ErrorOutputType)
                      -> Compilation {
        self.default.early_callback(matches, sopts, descriptions, output)
    }

    fn no_input(&mut self,
                matches: &getopts::Matches,
                sopts: &config::Options,
                odir: &Option<PathBuf>,
                ofile: &Option<PathBuf>,
                descriptions: &diagnostics::registry::Registry)
                -> Option<(config::Input, Option<PathBuf>)> {
        self.default.no_input(matches, sopts, odir, ofile, descriptions)
    }

    fn late_callback(&mut self,
                     matches: &getopts::Matches,
                     sess: &Session,
                     input: &config::Input,
                     odir: &Option<PathBuf>,
                     ofile: &Option<PathBuf>)
                     -> Compilation {
        if let &Some(ref dir) = odir {
            if let Some(dir_name) = dir.file_name() {
                if dir_name == "deps" {
                    self.do_analysis = false;
                }
            }
        }
        self.default.late_callback(matches, sess, input, odir, ofile)
    }

    fn build_controller(
        &mut self,
        sess: &Session,
        matches: &getopts::Matches
    ) -> driver::CompileController<'a> {

        let mut control = self.default.build_controller(sess, matches);
        let callback = mem::replace(&mut self.after_analysis_callback, Box::new(|_| {}));
        let original_after_analysis_callback = control.after_analysis.callback;
        let do_analysis = self.do_analysis;
        control.after_analysis.callback = Box::new(move |state| {
            state.session.abort_if_errors();
            if do_analysis {
                (*callback)(state);
                original_after_analysis_callback(state);
            }
        });
        control
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut analyzer = AnalyzeUnsafe::unsafe_ast_emitter();
    rustc_driver::run_compiler(&args, &mut analyzer);
}
