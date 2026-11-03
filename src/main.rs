mod backlinks;
mod cite;
mod config;
mod custom;
mod diag;
mod fetch;
mod highlight;
mod import;
mod lock;
mod lsp;
mod markdown;
mod markup;
mod math;
mod model;
mod noweb;
mod prose;
mod pseudocode;
mod resolve;
mod rewrite;
mod section;
mod site;
mod tangle;
mod transclude;
mod untangle;
mod weave;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "\
cob — web-first literate programming (early scaffold)

USAGE:
    cob weave [file.cob]...        weave to _site/; with no files, the book named by
                                  the [[document]] files in cob.toml (§5.2)
    cob fetch                     pin new/changed git imports, cache their index (§13)
    cob update [alias]            re-resolve git imports to the newest matching release (§13)
    cob backlinks <site-dir>...   write reverse-backlink fragments across built forests (§16)
    cob lock [file.cob]...         mint frozen ids for every label into cob.lock (§7.1);
                                  with no files, the book named in cob.toml
    cob rename-label <id> <name>  give an auto section id a human sec: name (§7.1)
    cob labels <file.cob>          list the file's label → id map from cob.lock
    cob id <file.cob> <label>      print the frozen id for one label
    cob find <id-or-label>        find which file defines a label or id, from cob.lock (§7.1)
    cob language <file.cob> <chunk> print the highlighting language for a chunk (§5.5)
    cob where <file.cob> <root> <line> map a tangled-file line back to its .cob source (§11)
    cob tokens <file.cob>          print whole-file semantic tokens, one per line (§5.5, #2)
    cob lsp                       run the editor language server over stdio (§5.5, #2)
    cob dump-ir <file.cob>...       print the parsed IR events (--from-markup <f>: parse a .markup)
    cob dump-model <file.cob>...   fold the IR into the document model, print it
    cob tangle <file.cob>...       tangle every root chunk
    cob untangle <file.cob>        patch the .cob from edits made to its tangled files (§11)

    cob --explain <CODE>         print the long form of a diagnostic (e.g. E014)

OPTIONS:
    --out <dir>                   weave: output dir (default: _site)
                                  tangle: root dir for tangled files (default: .)
    --archive                     weave: also emit site.json + per-page JSON (§8)
    --locked                      weave: never mint ids; error if a label is not
                                  in cob.lock (CI / read-only sandbox; §7.1)
    --deny-warnings               weave: exit nonzero if any lint fires (CI)
    -R <name>                     tangle: write one chunk to stdout instead
    --check                       tangle: diff roots against disk, exit 1 on drift
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // `--explain <CODE>` is informational and stage-independent (§12): it may
    // sit after any subcommand (`cob weave --explain E014`) or stand alone.
    if let Some(pos) = args.iter().position(|a| a == "--explain") {
        return explain_cmd(args.get(pos + 1).map(String::as_str));
    }
    match args.split_first().map(|(cmd, rest)| (cmd.as_str(), rest)) {
        Some(("dump-ir", files)) if !files.is_empty() => dump_ir(files),
        Some(("dump-model", files)) if !files.is_empty() => dump_model(files),
        Some(("weave", args)) => weave_cmd(args),
        Some(("fetch", rest)) if rest.is_empty() => fetch_cmd(),
        Some(("update", rest)) if rest.len() <= 1 => update_cmd(rest.first().map(String::as_str)),
        Some(("backlinks", dirs)) if !dirs.is_empty() => backlinks_cmd(dirs),
        Some(("lock", files)) => lock_cmd(files),
        Some(("rename-label", rest)) if rest.len() == 2 => rename_label_cmd(&rest[0], &rest[1]),
        Some(("labels", files)) if files.len() == 1 => labels_cmd(&files[0]),
        Some(("id", rest)) if rest.len() == 2 => id_cmd(&rest[0], &rest[1]),
        Some(("find", rest)) if rest.len() == 1 => find_cmd(&rest[0]),
        Some(("language", rest)) if rest.len() == 2 => language_cmd(&rest[0], &rest[1]),
        Some(("where", rest)) if rest.len() == 3 => where_cmd(&rest[0], &rest[1], &rest[2]),
        Some(("tokens", files)) if files.len() == 1 => tokens_cmd(&files[0]),
        Some(("lsp", rest)) if rest.is_empty() => lsp_cmd(),
        Some(("tangle", args)) if !args.is_empty() => tangle_cmd(args),
        Some(("untangle", args)) if !args.is_empty() => untangle_cmd(args),
        Some(("--version" | "-V", _)) => {
            println!("cob {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        _ => {
            eprint!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn explain_cmd(code: Option<&str>) -> ExitCode {
    match code {
        Some(code) => match diag::explain(code) {
            Some(text) => {
                println!("{code}: {text}");
                ExitCode::SUCCESS
            }
            None => {
                eprintln!("cob: no explanation for `{code}`");
                ExitCode::FAILURE
            }
        },
        None => {
            eprintln!("cob: --explain needs an error code (e.g. E014)");
            ExitCode::from(2)
        }
    }
}

/// The document's source files: those named on the command line, else the
/// `files` of the `[[document]]` table in `cob.toml`. An error names both ways to
/// say it.
fn document_files(named: Vec<String>) -> Result<Vec<String>, String> {
    if !named.is_empty() {
        return Ok(named);
    }
    let none = "cob: no .cob files given. Name them on the command line, or list them \
                in the `files` of a [[document]] table in cob.toml"
        .to_string();
    match config::Config::load(Path::new(".")) {
        Ok(Some(cfg)) => match cfg.document() {
            Some(d) if !d.files.is_empty() => Ok(d.files.clone()),
            _ => Err(none),
        },
        Ok(None) => Err(none),
        Err(e) => Err(e.to_string()),
    }
}

fn weave_cmd(args: &[String]) -> ExitCode {
    let mut out = "_site".to_string();
    let mut archive = false;
    let mut deny_warnings = false;
    let mut locked = false;
    let mut files = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--out" => match it.next() {
                Some(dir) => out = dir.clone(),
                None => {
                    eprintln!("cob: --out needs a directory");
                    return ExitCode::from(2);
                }
            },
            "--archive" => archive = true,
            "--deny-warnings" => deny_warnings = true,
            "--locked" => locked = true,
            _ => files.push(a.clone()),
        }
    }
    let files = match document_files(files) {
        Ok(f) => f,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::from(2);
        }
    };

    let events = match markup::read(&files) {
        Ok(events) => events,
        Err(e) => {
            eprintln!("cob: {e}");
            return ExitCode::FAILURE;
        }
    };
    let doc = match model::build(&events) {
        Ok(doc) => doc,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let mut warnings = 0usize;
    for lint in doc.lints() {
        eprintln!("{lint}");
        warnings += 1;
    }
    let cfg = match config::Config::load(Path::new(".")) {
        Ok(c) => c.unwrap_or_default(),
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let doc_cfg = cfg.document().cloned().unwrap_or_default();
    // A declared file set is the document's own definition of its sources;
    // fall back to the CLI arguments when `cob.toml` names none.
    let source_files = if doc_cfg.files.is_empty() {
        files.clone()
    } else {
        doc_cfg.files.clone()
    };
    let meta = site::Meta {
        id: doc_cfg.id,
        title: doc_cfg.title,
        authors: doc_cfg.authors,
        source_files,
    };
    let mode = if locked {
        lock::LockMode::Locked
    } else {
        lock::LockMode::Mint
    };
    // The highlighting config (tiers 1+2, §5.5). An unknown name is a config error,
    // not a silent fallback — a typo'd language should be caught.
    let lang_cfg = match lang_config(&cfg.weave) {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::FAILURE;
        }
    };
    // §13 imports: main reads each import's cob-exports.json into a forest ref (its
    // index plus the deployed url) and hands them to the weave, so the weave
    // itself reads no files (and stays offline). A local `path` is read directly;
    // a `git` import resolves through its `cob.lock` pin to the fetch cache
    // (`cob fetch` put it there), and a `git` import with no pin is E037.
    let import_lock = match lock::LockFile::load(Path::new("cob.lock")) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let cache_root = Path::new(".cob-cache");
    let mut loaded: BTreeMap<String, site::ForestRef> = BTreeMap::new();
    for (name, imp) in &cfg.imports {
        let dir = match fetch::index_dir(name, imp, &import_lock, cache_root) {
            Ok(Some(dir)) => dir,
            Ok(None) => continue,
            Err(e) => {
                eprintln!("{e}");
                return ExitCode::FAILURE;
            }
        };
        if let Ok(json) = std::fs::read_to_string(dir.join("cob-exports.json")) {
            match site::read_exports(&json) {
                Ok(Some(index)) => {
                    let url = imp.url.clone().unwrap_or_default();
                    loaded.insert(name.clone(), site::ForestRef { url, index });
                }
                Ok(None) => {}
                Err(e) => {
                    eprintln!("{e}");
                    return ExitCode::FAILURE;
                }
            }
        }
    }
    // §14 citations: load the bibliography named in `[cite] bib`, if any. A parse
    // or read failure is E039; an absent `[cite]` means no bibliography (a `\cite`
    // then fails E040 in the weave).
    let bib = match &cfg.cite.bib {
        Some(path) => match cite::load(Path::new(path)) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("{e}");
                return ExitCode::FAILURE;
            }
        },
        None => cite::Bib::default(),
    };
    match weave::write_site(
        &doc,
        Path::new(&out),
        Path::new(".cob-cache"),
        Path::new("cob.lock"),
        meta,
        &lang_cfg,
        &loaded,
        &bib,
        &cfg.fences,
        cfg.forest.url.as_deref().unwrap_or_default(),
        archive,
        mode,
    ) {
        Ok(site) => {
            for lint in &site.lints {
                eprintln!("{lint}");
                warnings += 1;
            }
            println!(
                "wove {} sections ({} math) across {} page(s) to {out}/",
                doc.sections.len(),
                site.math_count,
                site.pages.len()
            );
            // `--deny-warnings` turns lints into a nonzero exit for CI (§12); the
            // site is still written, so the artifact is available to inspect.
            if deny_warnings && warnings > 0 {
                eprintln!("cob: {warnings} warning(s); failing due to --deny-warnings");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

fn fetch_cmd() -> ExitCode {
    run_fetch(fetch::Mode::Fetch)
}

fn update_cmd(alias: Option<&str>) -> ExitCode {
    run_fetch(fetch::Mode::Update(alias.map(str::to_string)))
}

fn run_fetch(mode: fetch::Mode) -> ExitCode {
    let cfg = match config::Config::load(Path::new(".")) {
        Ok(c) => c.unwrap_or_default(),
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let lock_path = Path::new("cob.lock");
    let mut lock = match lock::LockFile::load(lock_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    match fetch::run(&cfg, &mut lock, Path::new(".cob-cache"), &mode) {
        Ok(fetched) => {
            if let Err(e) = lock.save(lock_path) {
                eprintln!("{e}");
                return ExitCode::FAILURE;
            }
            if fetched.is_empty() {
                println!("cob: imports are up to date");
            }
            for f in &fetched {
                let short: String = f.sha.chars().take(12).collect();
                println!("pinned {} @ {short}", f.alias);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

fn backlinks_cmd(dirs: &[String]) -> ExitCode {
    let paths: Vec<PathBuf> = dirs.iter().map(PathBuf::from).collect();
    match backlinks::run(&paths) {
        Ok(n) => {
            println!("cob backlinks: wrote {n} fragment(s)");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// Read the `.cob` files + fold the IR into the model — the front half shared by
/// `weave` and `lock`. Diagnostics are printed here; the `Err` carries the process
/// exit code.
fn build_doc(files: &[String]) -> Result<model::DocModel, ExitCode> {
    let events = markup::read(files).map_err(|e| {
        eprintln!("cob: {e}");
        ExitCode::FAILURE
    })?;
    model::build(&events).map_err(|e| {
        eprintln!("{e}");
        ExitCode::FAILURE
    })
}

/// `cob lock`: mint a frozen id for every label into `cob.lock` without rendering
/// (§7.1). It also gives every unlabelled `h2`/`h3` heading an id, anchored into the
/// `.cob` source. Ids already present are left untouched; new ones are written back
/// so a later `--locked` weave finds them.
fn lock_cmd(files: &[String]) -> ExitCode {
    let files = match document_files(files.to_vec()) {
        Ok(f) => f,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::from(2);
        }
    };
    let files = files.as_slice();
    let doc = match build_doc(files) {
        Ok(doc) => doc,
        Err(code) => return code,
    };
    let path = Path::new("cob.lock");
    let mut lock = match lock::LockFile::load(path) {
        Ok(lock) => lock,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let before = lock.count();
    let mut minter = lock::Minter::from_entropy();
    // Mint floats and author-labelled sections against the source as it is.
    if let Err(e) = weave::mint_lock(&doc, &mut lock, &mut minter) {
        eprintln!("{e}");
        return ExitCode::FAILURE;
    }
    // §7.1: give every unlabelled h2/h3 heading a frozen id, anchored in its source.
    let mut edits: BTreeMap<String, Vec<(u32, String)>> = BTreeMap::new();
    for site in section::headings(&doc) {
        if site.anchored || site.level < 2 {
            continue;
        }
        let id = lock.mint_section(&site.file, &mut minter);
        edits.entry(site.file).or_default().push((site.line, id));
    }
    for (file, list) in &edits {
        if let Err(e) = section::apply_anchors(Path::new(file), list) {
            eprintln!("cob: error[E032]: could not anchor {file}: {e}");
            return ExitCode::FAILURE;
        }
    }
    if let Err(e) = lock.save(path) {
        eprintln!("{e}");
        return ExitCode::FAILURE;
    }
    println!(
        "cob.lock: {} label(s), {} newly minted",
        lock.count(),
        lock.count() - before
    );
    ExitCode::SUCCESS
}

/// `cob rename-label <id> <name>`: give an auto section id a human `sec:` name
/// (§7.1). The frozen id never changes, so every reference and permalink still
/// resolves; only the source anchor and the lock key change.
fn rename_label_cmd(id: &str, name: &str) -> ExitCode {
    // The name becomes a `sec:` label, so keep it to a safe label segment.
    if name.is_empty()
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        eprintln!("cob: error: `{name}` is not a valid name (letters, digits, - or _)");
        return ExitCode::FAILURE;
    }
    let path = Path::new("cob.lock");
    let mut lock = match lock::LockFile::load(path) {
        Ok(lock) => lock,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let (file, old_label) = match lock.find_section(id) {
        Some(pair) => pair,
        None => {
            eprintln!("cob: error: no section has id `{id}` in cob.lock (run `cob lock`)");
            return ExitCode::FAILURE;
        }
    };
    let new_label = format!("sec:{name}");
    if new_label == old_label {
        println!("{id}: already named {new_label}");
        return ExitCode::SUCCESS;
    }
    if lock.get(&file, &new_label).is_some() {
        eprintln!("cob: error: `{new_label}` already exists in {file}");
        return ExitCode::FAILURE;
    }
    let old_name = old_label.strip_prefix("sec:").unwrap_or(&old_label);
    match section::rename_anchor(Path::new(&file), old_name, name) {
        Ok(true) => {}
        Ok(false) => {
            eprintln!("cob: error: no `{old_label}` anchor found in {file}");
            return ExitCode::FAILURE;
        }
        Err(e) => {
            eprintln!("cob: error[E032]: {file}: {e}");
            return ExitCode::FAILURE;
        }
    }
    lock.rename(&file, &old_label, &new_label);
    if let Err(e) = lock.save(path) {
        eprintln!("{e}");
        return ExitCode::FAILURE;
    }
    println!("renamed {old_label} → {new_label} ({id}) in {file}");
    ExitCode::SUCCESS
}

/// `cob labels <file>`: print the file's `label → id (kind)` map from `cob.lock`,
/// in sorted order (the committed lock is the greppable source of truth; §7.1).
fn labels_cmd(file: &str) -> ExitCode {
    let lock = match lock::LockFile::load(Path::new("cob.lock")) {
        Ok(lock) => lock,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    for (label, entry) in lock.labels(file) {
        println!("{label}\t{}\t{}", entry.id, entry.kind.word());
    }
    ExitCode::SUCCESS
}

/// `cob id <file> <label>`: print the frozen id for one label, or exit nonzero if
/// the label is not in `cob.lock`.
fn id_cmd(file: &str, label: &str) -> ExitCode {
    let lock = match lock::LockFile::load(Path::new("cob.lock")) {
        Ok(lock) => lock,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    match lock.get(file, label) {
        Some(entry) => {
            println!("{}", entry.id);
            ExitCode::SUCCESS
        }
        None => {
            eprintln!("cob: no id for label `{label}` in {file} (run `cob lock`)");
            ExitCode::FAILURE
        }
    }
}

/// `cob find <id-or-label>`: given a frozen id or a label name, print the
/// `.cob` file and line that defines it (§7.1) — the reverse of `cob id`, which
/// needs the file already in hand. A citation has no defining line in any
/// `.cob` file, so it prints the key instead.
fn find_cmd(needle: &str) -> ExitCode {
    let lock = match lock::LockFile::load(Path::new("cob.lock")) {
        Ok(lock) => lock,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let (file, label, entry) = match lock.find_label(needle) {
        Some(found) => found,
        None => {
            eprintln!("cob: no label or id `{needle}` in cob.lock (run `cob lock`)");
            return ExitCode::FAILURE;
        }
    };
    if entry.kind == rewrite::Kind::Citation {
        println!("{label} is a citation ({}): see the bibliography, not a .cob file", entry.id);
        return ExitCode::SUCCESS;
    }
    let text = match std::fs::read_to_string(&file) {
        Ok(text) => text,
        Err(e) => {
            eprintln!("cob: {file}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let as_label = format!("label{{{label}}}");
    let as_heading = format!("{{#{label}}}");
    match text
        .lines()
        .enumerate()
        .find(|(_, line)| line.contains(&as_label) || line.contains(&as_heading))
    {
        Some((i, _)) => {
            println!("{file}:{} ({} {})", i + 1, entry.kind.word(), entry.id);
            ExitCode::SUCCESS
        }
        None => {
            // The lock and the source have drifted (a hand edit, a stale lock).
            // Still useful: the file is right, just not the line.
            println!("{file} ({} {}, line not found — try `cob lock`)", entry.kind.word(), entry.id);
            ExitCode::SUCCESS
        }
    }
}

/// Build the resolved highlighting config from `[weave]` (§5.5), validating every
/// language id. An unknown name — in `lang` or any `[weave.chunk-lang]` value — is
/// a config error (E033), not a silent fallback, so a typo is caught, not ignored.
fn lang_config(weave: &config::Weave) -> Result<highlight::LangConfig, String> {
    let parse = |name: &str, where_: &str| match highlight::Lang::from_id(name) {
        Some(l) => Ok(l),
        None => Err(format!(
            "error[E033]: cob.toml: {where_} = \"{name}\" is not a known language"
        )),
    };
    let default = match weave.lang.as_deref() {
        None => None,
        Some(name) => Some(parse(name, "[weave] lang")?),
    };
    let mut chunk_lang = std::collections::HashMap::new();
    for (chunk, name) in &weave.chunk_lang {
        let where_ = format!("[weave.chunk-lang] \"{chunk}\"");
        chunk_lang.insert(chunk.clone(), parse(name, &where_)?);
    }
    Ok(highlight::LangConfig { default, chunk_lang })
}

/// `cob language <file> <chunk>`: print the highlighting language cob resolves for
/// a chunk (§5.5) — the shared resolver the weaver and any editor plugin agree on.
/// Exits nonzero when the chunk resolves to no known language, so a build can gate
/// on it.
fn language_cmd(file: &str, chunk: &str) -> ExitCode {
    let files = [file.to_string()];
    let events = match markup::read(&files) {
        Ok(events) => events,
        Err(e) => {
            eprintln!("cob: {e}");
            return ExitCode::FAILURE;
        }
    };
    let doc = match model::build(&events) {
        Ok(doc) => doc,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let cfg = match config::Config::load(Path::new(".")) {
        Ok(c) => c.unwrap_or_default(),
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let lang_cfg = match lang_config(&cfg.weave) {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::FAILURE;
        }
    };
    match highlight::resolve(&doc, chunk, &lang_cfg) {
        Some(lang) => {
            println!("{}", lang.id());
            ExitCode::SUCCESS
        }
        None => {
            eprintln!("cob: chunk `{chunk}` resolves to no known language");
            ExitCode::FAILURE
        }
    }
}

/// `cob where <file.cob> <root> <line>`: map a 1-based line of the tangled `root`
/// back to the `.cob` source line that wrote it.
fn where_cmd(file: &str, root: &str, line: &str) -> ExitCode {
    let line: usize = match line.parse() {
        Ok(n) if n >= 1 => n,
        _ => {
            eprintln!("cob: <line> must be a positive integer, got `{line}`");
            return ExitCode::from(2);
        }
    };
    let doc = match build_doc(&[file.to_string()]) {
        Ok(doc) => doc,
        Err(code) => return code,
    };
    if !doc.chunks.contains_key(root) {
        eprintln!("cob: `{root}` is not a chunk in {file}");
        return ExitCode::FAILURE;
    }
    let (_, map) = match tangle::tangle_root_located(&doc, root) {
        Ok(pair) => pair,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    match map.get(line - 1) {
        Some(loc) => {
            println!("{}:{} (chunk {})", loc.file, loc.line, loc.chunk);
            ExitCode::SUCCESS
        }
        None => {
            eprintln!("cob: {root} tangles to {} line(s); {line} is past the end", map.len());
            ExitCode::FAILURE
        }
    }
}

/// `cob tokens <file.cob>`: print every semantic token of the document.
fn tokens_cmd(file: &str) -> ExitCode {
    let doc = match build_doc(&[file.to_string()]) {
        Ok(doc) => doc,
        Err(code) => return code,
    };
    let cfg = match config::Config::load(Path::new(".")) {
        Ok(c) => c.unwrap_or_default(),
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let lang_cfg = match lang_config(&cfg.weave) {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::FAILURE;
        }
    };
    let source = std::fs::read_to_string(file).unwrap_or_default();
    for t in lsp::tokens(&doc, &lang_cfg, &source) {
        println!("{}:{} {} {}", t.line, t.col, t.len, t.kind);
    }
    ExitCode::SUCCESS
}

/// `cob lsp`: run the semantic-tokens language server over stdin and stdout.
fn lsp_cmd() -> ExitCode {
    let cfg = match config::Config::load(Path::new(".")) {
        Ok(c) => c.unwrap_or_default(),
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let lang_cfg = match lang_config(&cfg.weave) {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::FAILURE;
        }
    };
    lsp::serve(lang_cfg)
}

fn tangle_cmd(args: &[String]) -> ExitCode {
    let mut out: Option<String> = None;
    let mut single: Option<String> = None;
    let mut check = false;
    let mut files = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--out" => match it.next() {
                Some(dir) => out = Some(dir.clone()),
                None => {
                    eprintln!("cob: --out needs a directory");
                    return ExitCode::from(2);
                }
            },
            "-R" => match it.next() {
                Some(name) => single = Some(name.clone()),
                None => {
                    eprintln!("cob: -R needs a chunk name");
                    return ExitCode::from(2);
                }
            },
            "--check" => check = true,
            _ => files.push(a.clone()),
        }
    }
    if files.is_empty() {
        eprintln!("cob: tangle needs at least one .cob file");
        return ExitCode::from(2);
    }

    let cfg = match config::Config::load(Path::new(".")) {
        Ok(c) => c.unwrap_or_default(),
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    // The native tangler does not emit `-L` line pragmas yet (§11 follow-up).
    // Warn if any are configured so the omission is visible, never silent.
    if !cfg.tangle_pragmas().is_empty() {
        eprintln!(
            "cob: warning: [[tangle.root]] line-pragma formats are set but the \
             native tangler does not emit them yet; tangling without pragmas"
        );
    }
    // Precedence: explicit `--out`, then `cob.toml`'s `[tangle] outdir`, then cwd.
    let out = out
        .or_else(|| cfg.tangle.outdir.clone())
        .unwrap_or_else(|| ".".to_string());

    // Every mode walks the model: it holds each chunk and its uses, and it
    // surfaces E010 (use of an undefined chunk) before tangle runs.
    let events = match markup::read(&files) {
        Ok(events) => events,
        Err(e) => {
            eprintln!("cob: {e}");
            return ExitCode::FAILURE;
        }
    };
    let doc = match model::build(&events) {
        Ok(doc) => doc,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };

    // `-R name` tangles one chunk (any name, not only a root) to stdout; the
    // caller redirects it. It never touches disk.
    if let Some(name) = single {
        let defined = doc.chunks.get(&name).is_some_and(|c| !c.defs.is_empty());
        if !defined {
            eprintln!("cob: no chunk named `{name}`");
            return ExitCode::from(2);
        }
        return match tangle::tangle_root(&doc, &name) {
            Ok(code) => {
                print!("{code}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("{e}");
                ExitCode::FAILURE
            }
        };
    }

    let roots = doc.roots();
    if roots.is_empty() {
        eprintln!("cob: no root chunks (path-shaped names) to tangle");
        return ExitCode::from(2);
    }
    let outdir = Path::new(&out);

    if check {
        return match tangle::check(&doc, &roots, outdir) {
            Ok(drift) if drift.is_empty() => {
                println!("tangle --check: {} root(s) in sync", roots.len());
                ExitCode::SUCCESS
            }
            Ok(drift) => {
                for (root, d) in &drift {
                    let why = match d {
                        tangle::Drift::Missing => "not on disk",
                        tangle::Drift::Differs => "differs from disk",
                    };
                    eprintln!("drift: {root} {why}");
                }
                ExitCode::FAILURE
            }
            Err(e) => {
                eprintln!("{e}");
                ExitCode::FAILURE
            }
        };
    }

    match tangle::tangle_to_dir(&doc, &roots, outdir) {
        Ok(report) => {
            for (root, wrote) in &report {
                let verb = match wrote {
                    tangle::Wrote::Created => "created",
                    tangle::Wrote::Updated => "updated",
                    tangle::Wrote::Unchanged => "unchanged",
                };
                println!("{verb} {root}");
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// `cob untangle <file.cob> [--out dir]`: print a patch on the `.cob` source from
/// edits made to its tangled files.
fn untangle_cmd(args: &[String]) -> ExitCode {
    let mut file = None;
    let mut outdir = PathBuf::from(".");
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--out" => match it.next() {
                Some(dir) => outdir = PathBuf::from(dir),
                None => {
                    eprintln!("cob: --out needs a directory");
                    return ExitCode::from(2);
                }
            },
            _ if file.is_none() => file = Some(a.clone()),
            _ => {}
        }
    }
    let Some(file) = file else {
        eprint!("{USAGE}");
        return ExitCode::from(2);
    };
    let doc = match build_doc(&[file]) {
        Ok(doc) => doc,
        Err(code) => return code,
    };
    match untangle::patch(&doc, &outdir) {
        Ok((patch, conflicts)) => {
            for c in &conflicts {
                if c.line == 0 {
                    eprintln!("cob: {}: {}", c.root, c.reason);
                } else {
                    eprintln!("cob: {} tangled line {}: {}", c.root, c.line, c.reason);
                }
            }
            print!("{patch}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

fn dump_model(files: &[String]) -> ExitCode {
    let events = match markup::read(files) {
        Ok(events) => events,
        Err(e) => {
            eprintln!("cob: {e}");
            return ExitCode::FAILURE;
        }
    };
    let doc = match model::build(&events) {
        Ok(doc) => doc,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    for lint in doc.lints() {
        eprintln!("{lint}");
    }
    println!("files: {:?}", doc.files);
    println!("roots: {:?}", doc.roots());
    for section in &doc.sections {
        println!(
            "{} {}:{} {:?}",
            section.id, section.file, section.line, section.kind
        );
    }
    for (name, info) in &doc.chunks {
        println!(
            "chunk {name:?} root={} defs={:?} uses={:?}",
            info.root, info.defs, info.uses
        );
    }
    ExitCode::SUCCESS
}

fn dump_ir(args: &[String]) -> ExitCode {
    // `--from-markup <file>` parses one frozen markup IR file; otherwise read
    // every `.cob` argument with the native reader.
    if let Some((flag, rest)) = args.split_first() {
        if flag == "--from-markup" {
            let [path] = rest else {
                eprintln!("cob: dump-ir --from-markup needs exactly one .markup file");
                return ExitCode::from(2);
            };
            let ir = match std::fs::read_to_string(path) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("cob: {path}: {e}");
                    return ExitCode::FAILURE;
                }
            };
            return print_events(noweb::parse(&ir).map_err(|e| e.to_string()));
        }
    }
    if args.is_empty() {
        eprintln!("cob: dump-ir needs at least one .cob file");
        return ExitCode::from(2);
    }
    print_events(markup::read(args).map_err(|e| e.to_string()))
}

fn print_events(events: Result<Vec<noweb::Event>, String>) -> ExitCode {
    match events {
        Ok(events) => {
            for event in &events {
                println!("{event:?}");
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("cob: {e}");
            ExitCode::FAILURE
        }
    }
}
