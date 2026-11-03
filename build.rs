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
    }

    let code = format!("{externs}\nfn generated() -> Vec<Grammar> {{ vec![{entries}] }}\n");
    fs::write(&generated, code).expect("write generated grammars");
}
