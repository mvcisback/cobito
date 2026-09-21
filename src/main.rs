mod config;
mod diag;
mod highlight;
mod lock;
mod markdown;
mod markup;
mod math;
mod model;
mod noweb;
mod prose;
mod resolve;
mod rewrite;
mod section;
mod site;
mod tangle;
mod transclude;
mod weave;

use std::collections::BTreeMap;
use std::path::Path;
use std::process::ExitCode;

const USAGE: &str = "\
cob — web-first literate programming (early scaffold)

USAGE:
    cob weave <file.cob>...        weave to _site/ (single page; M2 adds splitting)
    cob lock <file.cob>...         mint frozen ids for every label into cob.lock (§7.1)
    cob rename-label <id> <name>  give an auto section id a human sec: name (§7.1)
    cob labels <file.cob>          list the file's label → id map from cob.lock
    cob id <file.cob> <label>      print the frozen id for one label
    cob language <file.cob> <chunk> print the highlighting language for a chunk (§5.5)
    cob dump-ir <file.cob>...       print the parsed IR events (--from-markup <f>: parse a .markup)
    cob dump-model <file.cob>...   fold the IR into the document model, print it
    cob tangle <file.cob>...       tangle every root chunk

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
        Some(("weave", args)) if !args.is_empty() => weave_cmd(args),
        Some(("lock", files)) if !files.is_empty() => lock_cmd(files),
        Some(("rename-label", rest)) if rest.len() == 2 => rename_label_cmd(&rest[0], &rest[1]),
        Some(("labels", files)) if files.len() == 1 => labels_cmd(&files[0]),
        Some(("id", rest)) if rest.len() == 2 => id_cmd(&rest[0], &rest[1]),
        Some(("language", rest)) if rest.len() == 2 => language_cmd(&rest[0], &rest[1]),
        Some(("tangle", args)) if !args.is_empty() => tangle_cmd(args),
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
    if files.is_empty() {
        eprintln!("cob: weave needs at least one .cob file");
        return ExitCode::from(2);
    }

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
    match weave::write_site(
        &doc,
        Path::new(&out),
        Path::new(".cob-cache"),
        Path::new("cob.lock"),
        meta,
        &lang_cfg,
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
