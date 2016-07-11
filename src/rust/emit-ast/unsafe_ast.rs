// Alex Ozdemir <aozdemir@hmc.edu>
// Library for producing an AST which summarizes the bits of a crate related to `unsafe`

use rustc::hir;
use rustc::hir::{intravisit,Unsafety};
use rustc::hir::def::Def;
use rustc::session::Session;
use rustc::ty;
use syntax::{abi,ast};

use syntax::codemap::{CodeMap,ExpnInfo,ExpnFormat,Span};

use std::mem;

const SNIPPET_LENGTH: usize = 40;

// ===================================== //
// The Unsafe AST itself                 //
// ===================================== //


#[derive(Clone, PartialEq, Eq, Debug, RustcEncodable, RustcDecodable)]
pub struct Crate {
    name: String,
    ty: String,
    functions: Vec<FnDecl>,
}

#[derive(Clone, PartialEq, Eq, Debug, RustcEncodable, RustcDecodable)]
pub struct FnDecl {
    name: String,
    unsaf: bool,
    span: String,
    macro_origin: MacroOrigin,
    block: Box<Block>,
}

#[derive(Clone, PartialEq, Eq, Debug, RustcEncodable, RustcDecodable)]
pub struct Block {
    size: u64,
    unsaf: bool,
    contents: Vec<Indexed<UASTNode>>,
}

#[derive(Clone, PartialEq, Eq, Debug, RustcEncodable, RustcDecodable)]
pub struct Indexed<T> {
    index: u64,
    span: String,
    snippet: String,
    macro_origin: MacroOrigin,
    item: T,
}

#[derive(Clone, PartialEq, Eq, Debug, RustcEncodable, RustcDecodable)]
pub enum UASTNode {
    Deref,
    MutStatic,
    InlineASM,
    Call(Unsafe,FFI),
    Closure(Box<Block>),
    InnerBlock(Box<Block>),
}

#[derive(Clone, PartialEq, Eq, Debug, RustcEncodable, RustcDecodable)]
pub struct FFI {
    is_ffi: bool,
}

#[derive(Clone, PartialEq, Eq, Debug, RustcEncodable, RustcDecodable)]
pub enum MacroOrigin {
    NotMacro, LocalMacro, ExternalMacro, DeriveMacro
}

#[derive(Clone, PartialEq, Eq, Debug, RustcEncodable, RustcDecodable)]
pub struct Unsafe {
    unsaf: bool,
}

// ===================================== //
// Implementations for parts of the UAST //
// ===================================== //

impl<T> Indexed<T> {
    /// Create a new indexed item with
    ///     `index` - its statement number in the enclosing block
    ///     `span` - span of the item
    ///     `codemap` - used to interpret the span
    ///     `snippet` - whether or not to include a code snippet
    ///     `macro_origin` - whether this item originated in a macro
    pub fn new(index: u64,
               item: T,
               span: Span,
               codemap: &CodeMap,
               macro_origin: MacroOrigin) -> Indexed<T> {
        let span_string = codemap.span_to_string(span);
        let mut snippet = codemap.span_to_snippet(span).unwrap_or_else(|_| String::new());
        if snippet.len() > SNIPPET_LENGTH {
            snippet = snippet.chars().take(SNIPPET_LENGTH - 1).collect();
            snippet.push('#');
        }
        Indexed {
            index: index,
            span: span_string,
            snippet: snippet,
            macro_origin: macro_origin,
            item: item,
        }
    }
}

impl Block {
    pub fn new(unsafety: Unsafety, size: u64, contents: Vec<Indexed<UASTNode>>) -> Block {
        Block { unsaf: is_unsafe(unsafety), size: size, contents: contents }
    }
}

impl FnDecl {
    pub fn new(block: Box<Block>,
               unsafety: Unsafety,
               name: String,
               span: String,
               macro_origin: MacroOrigin) -> Self {
        FnDecl { unsaf: is_unsafe(unsafety),
                 block: block,
                 name: name,
                 span: span,
                 macro_origin: macro_origin,
        }
    }
}

impl FFI {
    pub fn new(h: abi::Abi) -> FFI {
        FFI { is_ffi: match h {
            abi::Abi::C | abi::Abi::System => true,
            _ => false,
        } }
    }
    fn from_fn_ty(ty: ty::Ty) -> FFI {
        match ty.sty {
            ty::TyFnDef(_, _, ref f) |
            ty::TyFnPtr(ref f) => FFI::new(f.abi),
            _ => FFI { is_ffi: false },
        }
    }
}

impl Unsafe {
    pub fn new(h: Unsafety) -> Unsafe {
        Unsafe { unsaf: is_unsafe(h) }
    }
    fn from_fn_ty(ty: ty::Ty) -> Unsafe {
        match ty.sty {
            ty::TyFnDef(_, _, ref f) |
            ty::TyFnPtr(ref f) => Unsafe::new(f.unsafety),
            _ => Unsafe { unsaf: false },
        }
    }
}

fn is_unsafe(h: Unsafety) -> bool {
    match h {
        Unsafety::Normal => false,
        Unsafety::Unsafe => true,
    }
}

// ========================================= //
// The Visitor which produces the Unsafe AST //
// ========================================= //

pub struct UnsafeASTEmitter<'a, 'tcx: 'a,'ast> {
    tcx: ty::TyCtxt<'a, 'tcx, 'tcx>,
    index: u64,
    session: &'ast Session,
    contents: Vec<Indexed<UASTNode>>,
    stack: Vec<(u64, Vec<Indexed<UASTNode>>)>,
    crate_name: String,
    crate_type: String,
    functions: Vec<FnDecl>,
}

impl<'a,'tcx:'a,'ast> UnsafeASTEmitter<'a,'tcx,'ast> {
    pub fn new(tcx: ty::TyCtxt<'a,'tcx,'tcx>,
               session: &'ast Session,
               crate_name: String,
               crate_type: String) -> UnsafeASTEmitter<'a,'tcx,'ast> {
        UnsafeASTEmitter {
            tcx: tcx,
            session: session,
            index: 0,
            contents: vec![],
            stack: vec![],
            crate_name: crate_name,
            crate_type: crate_type,
            functions: vec![],
        }
    }

    /// Produces the crate so far.
    pub fn into_uast(self) -> Crate {
        Crate { name: self.crate_name, ty: self.crate_type, functions: self.functions }
    }

    /// Create a new indexed item with
    ///     `index` - its statement number in the enclosing block
    ///     `span` - span of the item
    /// and store it in the list of registered unsafe points.
    pub fn register_point(&mut self, item: UASTNode, span: Span) {
        let macro_origin = self.get_macro_origin(span);
        self.contents.push(
            Indexed::new(self.index, item, span, self.session.codemap(), macro_origin)
        )
    }

    /// Register the AST for a completed function/method with
    ///     `boxed_block` - its block
    ///     `unsafety` - whether the fn is safe
    ///     `name` - the name of the fn
    ///     `span`
    pub fn register_function(&mut self,
                             boxed_block: Box<Block>,
                             unsafety: hir::Unsafety,
                             name: String,
                             span: Span) {
        let macro_origin = self.get_macro_origin(span);
        let span_string = self.session.codemap().span_to_string(span);
        self.functions.push(FnDecl::new(boxed_block, unsafety, name, span_string, macro_origin));
    }

    /// Returns true if this `expn_info` was expanded by any macro.
    /// This function taken from `clippy`
    fn in_macro(&self, span: Span) -> bool {
        self.session.codemap().with_expn_info(span.expn_id, |info| info.is_some())
    }

    /// Returns true if the macro that expanded the crate was outside of the current crate or was a
    /// compiler plugin.
    /// This function taken from `clippy`
    fn in_external_macro(&self, span: Span) -> bool {
        /// Invokes `in_macro` with the expansion info of the given span slightly heavy, try to use
        /// this after other checks have already happened.
        fn in_macro_ext(codemap: &CodeMap, opt_info: Option<&ExpnInfo>) -> bool {
            // no ExpnInfo = no macro
            opt_info.map_or(false, |info| {
                if let ExpnFormat::MacroAttribute(..) = info.callee.format {
                    // these are all plugins
                    return true;
                }
                // no span for the callee = external macro
                info.callee.span.map_or(true, |span| {
                    // no snippet = external macro or compiler-builtin expansion
                    codemap.span_to_snippet(span).ok()
                        .map_or(true, |code| !code.starts_with("macro_rules"))
                })
            })
        }
        let codemap = self.session.codemap();
        codemap.with_expn_info(span.expn_id, |info| in_macro_ext(codemap, info))
    }

    /// Determines whether a span originates within a macro, and if so, what type (Local, External,
    /// Generated by Derive)
    fn get_macro_origin(&self, span: Span) -> MacroOrigin {
        if self.in_macro(span) {
            if self.in_external_macro(span) { 
                let span_string = self.session.codemap()
                    .span_to_snippet(span).unwrap_or_else(|_| String::new());
                // This is somewhat hacky, but when the compiler expands derive attributes it
                // leaves the trait name as the snippet.
                if span_string == "Clone" ||
                   span_string == "Hash" ||
                   span_string == "RustcEncodable" ||
                   span_string == "RustcDecodable" ||
                   span_string == "PartialEq" ||
                   span_string == "Eq" ||
                   span_string == "PartialOrd" ||
                   span_string == "Ord" ||
                   span_string == "Debug" ||
                   span_string == "Default" ||
                   span_string == "Send" ||
                   span_string == "Sync" ||
                   span_string == "Copy" ||
                   span_string == "Encodable" ||
                   span_string == "Decodable"
                { MacroOrigin::DeriveMacro }
                else { MacroOrigin::ExternalMacro }
            }
            else { MacroOrigin::LocalMacro }
        } else { MacroOrigin::NotMacro }
    }
}

impl<'a, 'tcx: 'a, 'ast> UnsafeASTEmitter<'a, 'tcx, 'ast> {
    fn visit_block_post<'v>(&mut self, b: &'v hir::Block) {
        use ::rustc::hir::BlockCheckMode::*;
        use ::rustc::hir::UnsafeSource::UserProvided;
        if b.expr.is_some() { self.index += 1 }
        let unsafety = match *b {
            hir::Block{rules: DefaultBlock, ..} => Unsafety::Normal,
            hir::Block{rules: UnsafeBlock(UserProvided), ..} |
            hir::Block{rules: PushUnsafeBlock(UserProvided), ..} |
            hir::Block{rules: PopUnsafeBlock(UserProvided), ..} => Unsafety::Unsafe,
            _ => Unsafety::Normal,
        };
        let (index, mut contents) = self.stack.pop().unwrap();
        mem::swap(&mut contents, &mut self.contents);
        let block = UASTNode::InnerBlock(
            Box::new(Block::new(unsafety, self.index, contents))
        );
        self.index = index;
        self.register_point(block, b.span);
    }
    fn visit_fn_post<'v>(&mut self,
                         fk: intravisit::FnKind<'v>,
                         _: &'v hir::FnDecl,
                         _: &'v hir::Block,
                         span: Span,
                         id: ast::NodeId) {
        use ::rustc::hir::intravisit::FnKind::{ItemFn,Method,Closure};
        let Indexed{ item, .. } = self.contents.pop().unwrap();
        if let UASTNode::InnerBlock(boxed_block) = item {
            let (index, contents) = self.stack.pop().unwrap();
            self.index = index;
            self.contents = contents;
            match fk {
                ItemFn(_, _, unsafety, _, _, _, _) |
                Method(_, &hir::MethodSig { unsafety, .. }, _, _) => {
                    let name = self.tcx.node_path_str(id);
                    self.register_function(boxed_block, unsafety, name, span);
                }
                Closure(_) => {
                    let closure = UASTNode::Closure(boxed_block);
                    self.register_point(closure, span);
                }
            };
        } else {
            panic!("Found something other than a block under a fn: {:?}", item);
        }
    }
}

impl<'a, 'tcx: 'a, 'ast, 'v> intravisit::Visitor<'v> for UnsafeASTEmitter<'a, 'tcx, 'ast> {

    fn visit_block(&mut self, b: &'v hir::Block) {
        self.stack.push( (self.index, mem::replace(&mut self.contents, vec![])) );
        self.index = 0;
        intravisit::walk_block(self, b);
        self.visit_block_post(b);
    }
    fn visit_stmt(&mut self, s: &'v hir::Stmt) {
        intravisit::walk_stmt(self, s);
        self.index += 1;
    }
    fn visit_expr(&mut self, expr: &'v hir::Expr) {
        match expr.node {
            hir::Expr_::ExprCall(ref fn_expr, _) => {
                let fn_ty = self.tcx.expr_ty_adjusted(fn_expr);
                let fn_safety = Unsafe::from_fn_ty(fn_ty);
                let fn_ffi = FFI::from_fn_ty(fn_ty);
                let unsafe_call = UASTNode::Call(fn_safety,fn_ffi);
                self.register_point(unsafe_call, expr.span);
            },
            hir::Expr_::ExprMethodCall(_, _, _) => {
                let method_call = ty::MethodCall::expr(expr.id);
                let fn_ty = self.tcx.tables.borrow().method_map[&method_call].ty;
                let fn_safety = Unsafe::from_fn_ty(fn_ty);
                let fn_ffi = FFI::from_fn_ty(fn_ty);
                let unsafe_call = UASTNode::Call(fn_safety,fn_ffi);
                self.register_point(unsafe_call, expr.span);
            },
            hir::Expr_::ExprUnary(hir::UnOp::UnDeref, ref sub_expr) => {
                let tys = self.tcx.node_id_to_type(sub_expr.id);
                if let ty::TyRawPtr(_) = tys.sty {
                    self.register_point(UASTNode::Deref, expr.span);
                }
            },
            hir::ExprInlineAsm(..) => {
                self.register_point(UASTNode::InlineASM, expr.span);
            },
            hir::ExprPath(..) => {
                if let Def::Static(_, true) = self.tcx.expect_def(expr.id) {
                    self.register_point(UASTNode::MutStatic, expr.span);
                }
            },
            _ => { /* No other unsafe operations */ },
        }
        intravisit::walk_expr(self, expr);
    }
    fn visit_fn(&mut self,
                fk: intravisit::FnKind<'v>,
                fd: &'v hir::FnDecl,
                b: &'v hir::Block,
                s: Span,
                id: ast::NodeId) {
        self.stack.push( (self.index, mem::replace(&mut self.contents, vec![])) );
        self.index = 0;
        self.visit_block(b);
        self.visit_fn_post(fk, fd, b, s, id);
    }
}

