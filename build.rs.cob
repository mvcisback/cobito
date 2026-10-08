# The grammar build script

This is cob's Cargo build script, told as a literate program. It makes cob a
**meta-language** for highlighting (§5.5): the grammars are not hardcoded, they are
compiled in from a manifest the build is given. Edit this `.cob` and re-tangle
(`cob tangle build.rs.cob --out .`), never the generated `build.rs`.

## Why a build script {#sec:build-why}

Highlighting is the one language-bound part of cob (CLAUDE goal #2). To let a user
bring any tree-sitter grammar without editing cob's source, the grammar set is a
**build input**, not a dependency list. Nix hands the build a manifest of grammars
(each pinned as a flake input); this script compiles each grammar's C and generates
the registry entries (§5.5) that `highlight.rs` includes. The grammar set is thus
chosen at build time, pinned and deterministic — no runtime loading, no `cob` edit.

## The manifest {#sec:build-manifest}

The env var `COB_GRAMMARS` names a manifest file, one grammar per line, tab-separated:
`id <TAB> exts(comma-separated) <TAB> root <TAB> symbol`. `root` is the grammar's
source tree (with `src/parser.c`, an optional `src/scanner.c`/`.cc`, and
`queries/highlights.scm`); `symbol` is its `tree_sitter_<name>` C entry point. No
manifest means the generated set is empty — the builtin grammars (if any) stand
alone. The format is line-based so the script needs no parser dependency.

## How the code implements this {#sec:build-impl}

The script reads the manifest, compiles each grammar's C with the `cc` crate, and
writes `grammars_generated.rs` into `OUT_DIR`: one FFI declaration per grammar and a
`generated()` function returning their registry entries, which `highlight.rs`
includes and merges into its registry.
<<build.rs>>=
use std::{env, fs, path::Path};

fn main() {
    println!("cargo:rerun-if-env-changed=COB_GRAMMARS");
    let out = env::var("OUT_DIR").expect("OUT_DIR is set by cargo");
    let generated = Path::new(&out).join("grammars_generated.rs");

    let Ok(manifest) = env::var("COB_GRAMMARS") else {
        // No manifest: no generated grammars; the builtins (if any) stand.
        fs::write(&generated, "fn generated() -> Vec<Grammar> { Vec::new() }\n")
            .expect("write empty generated grammars");
        return;
    };
    println!("cargo:rerun-if-changed={manifest}");
    let text = fs::read_to_string(&manifest).unwrap_or_default();

    let mut externs = String::new();
    let mut entries = String::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split('\t').collect();
        let [id, exts, root, symbol] = fields.as_slice() else {
            panic!("COB_GRAMMARS line needs 4 tab-separated fields: {line:?}");
        };
        <<compile one grammar's C>>
        <<emit the registry entry>>
    }

    let code = format!("{externs}\nfn generated() -> Vec<Grammar> {{ vec![{entries}] }}\n");
    fs::write(&generated, code).expect("write generated grammars");
}
@
Each grammar is a `parser.c` plus an optional external scanner (`scanner.c`, or
`scanner.cc` for a C++ one). cc compiles them into a static library cob links, so
the grammar's `tree_sitter_<name>` symbol resolves. Warnings are off — a generated
parser is not ours to lint.
<<compile one grammar's C>>=
println!("cargo:rerun-if-changed={root}");
let src = Path::new(root).join("src");
let mut build = cc::Build::new();
build.include(&src).warnings(false).file(src.join("parser.c"));
let scanner_c = src.join("scanner.c");
let scanner_cc = src.join("scanner.cc");
if scanner_c.exists() {
    build.file(scanner_c);
} else if scanner_cc.exists() {
    build.cpp(true).file(scanner_cc);
}
build.compile(&format!("cobgrammar_{id}"));
@
The registry entry mirrors a builtin (§5.5): an FFI declaration for the grammar's
entry point, then a `Grammar` whose `language` wraps that symbol with
`LanguageFn::from_raw`, and whose `highlights` is the query baked in with
`include_str!`. A grammar with no highlights query gets an empty one (plain text).
<<emit the registry entry>>=
externs.push_str(&format!("extern \"C\" {{ fn {symbol}() -> *const (); }}\n"));
let ext_lits: Vec<String> = exts
    .split(',')
    .filter(|e| !e.is_empty())
    .map(|e| format!("{e:?}"))
    .collect();
let highlights = Path::new(root).join("queries/highlights.scm");
let highlights = if highlights.exists() {
    format!("include_str!({:?})", highlights.display().to_string())
} else {
    "\"\"".to_string()
};
entries.push_str(&format!(
    "Grammar {{ id: {id:?}, exts: &[{}], \
     language: || unsafe {{ tree_sitter_language::LanguageFn::from_raw({symbol}) }}.into(), \
     highlights: {highlights} }},\n",
    ext_lits.join(", "),
));
@
