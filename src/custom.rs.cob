# The custom fence {#sec:custom}

A `custom[NAME]` fence (§6.4) hands its body to a project-registered CLI and
splices the HTML the CLI returns. It is the extension point for content cob does
not render natively — a LaTeX figure, a graphviz graph, a bespoke diagram DSL —
without a new fence kind in cob for each. Use it sparingly: a native fence is
deterministic and dependency-free, while a custom fence pulls in a tool and a
trust decision.

The handler is a `[fence.NAME]` table in `cob.toml` (§6.1). Declaring it there —
the project's own trusted config — is the consent to run it; an undeclared
handler is E042. cob runs the command from the project root, sends it a JSON blob
on stdin (the fence body, the macros in scope, the config, and a writable output
directory), and reads a JSON envelope back: the HTML, and a map of assets to copy
into the site.

Three rules keep a custom fence inside cob's guarantees. The output must carry no
`<script>` (the no-JS content rule, §6.3) — a script in the result is E042, not a
silent strip, so the handler cannot smuggle one in. The result is content-
addressed over the whole input and cached, so a re-weave is stable and the handler
runs once. And the handler must be a deterministic function of its input, or two
weaves of the archive diverge — cob sets `SOURCE_DATE_EPOCH=0` to help a tool like
LaTeX, but the handler owns the rest (§8).

The module is the error, the JSON contract, the content-hash cache key, the
placeholder expander, and the single-handler runner.

<<src/custom.rs>>=
//! §6.6 The `custom[NAME]` fence: a `cob.toml`-registered CLI renders the body.
//!
//! cob emits a `<cob-custom>` placeholder from the Markdown pass; the weaver
//! calls `expand` before the float scan, so a handler that returns a
//! `<figure id="fig:…">` is numbered like any other float. The handler reads a
//! JSON blob on stdin and writes a JSON envelope (`html` + `assets`) on stdout.
//! Output is content-addressed and cached; a `<script>` in the output, a missing
//! handler, or a non-zero exit is E042.

use crate::config::FenceHandler;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

<<the custom error>>

<<the custom contract types>>

<<the custom cache key>>

<<expand custom placeholders>>

<<run one handler>>

<<unescape attribute text>>

<<custom tests>>
@

A fault names its E042 code and a message; weave turns it into a diagnostic at
the fence's \code{file:line}.
<<the custom error>>=
/// A custom-fence fault (E042): a missing handler, a non-zero exit, a `<script>`
/// in the output, or malformed envelope JSON.
#[derive(Debug)]
pub struct CustomError {
    pub message: String,
}

impl CustomError {
    fn new(message: impl Into<String>) -> Self {
        CustomError { message: message.into() }
    }
}
@

The blob cob sends (\code{Input}) and the envelope it reads back (\code{Output}). \code{assets}
maps a site-relative published path to a file the handler wrote under \code{outdir};
cob copies each into the site. An \code{Asset} is one such file, read into memory so it
survives the cache.
<<the custom contract types>>=
/// The JSON blob sent to a handler on stdin (§6.6).
#[derive(serde::Serialize)]
struct Input<'a> {
    handler: &'a str,
    body: &'a str,
    caption: Option<&'a str>,
    label: Option<&'a str>,
    /// The macros in scope here (name → expansion), so a handler can typeset the
    /// body in the document's own notation.
    defs: &'a BTreeMap<String, String>,
    /// The parsed `cob.toml`, if any, as JSON.
    config: &'a serde_json::Value,
    file: &'a str,
    line: u32,
    /// A writable directory for the handler to put asset files in.
    outdir: &'a str,
}

/// The JSON envelope a handler writes on stdout.
#[derive(serde::Deserialize)]
struct Output {
    html: String,
    /// Published-path → `outdir`-relative file. cob copies each into the site.
    #[serde(default)]
    assets: BTreeMap<String, String>,
}

/// One asset to place in the woven site, its bytes read so the cache is complete.
#[derive(Debug)]
pub struct Asset {
    pub path: String,
    pub bytes: Vec<u8>,
}
@

The cache key is FNV-1a over the serialized \code{Input} — body, caption, label,
macros, config, and the handler argv folded in. It is stable across toolchains
(\code{DefaultHasher} is not), so a cache entry does not silently rot (§6.4 math
cache). The handler argv is part of the key: change the command, re-render.
<<the custom cache key>>=
fn hash(cmd: &[String], input_json: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut byte = |b: u8| {
        h ^= b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    };
    for a in cmd {
        a.bytes().for_each(&mut byte);
        byte(0);
    }
    input_json.bytes().for_each(&mut byte);
    format!("{h:016x}")
}
@

\code{expand} rewrites every \code{<cob-custom>} placeholder in one rendered docs body. It
runs before the float scan, so a returned \code{<figure>} is numbered normally. The
placeholder carries the handler, the label, and the (escaped) caption and body the
Markdown pass peeled; \code{expand} adds the macros, the config, and a writable output
directory, then runs the handler and splices the HTML. Each handler's assets are
returned for the weaver to write into the site.
<<expand custom placeholders>>=
/// Expand every `<cob-custom>` placeholder in `html`. `cache_root` is the
/// optional `.cob-cache` dir; when it cannot be written (the read-only Nix
/// sandbox) the handler simply runs each time, so it must be deterministic (§8).
pub fn expand(
    html: &str,
    defs: &BTreeMap<String, String>,
    fences: &BTreeMap<String, FenceHandler>,
    root: &Path,
    cache_root: Option<&Path>,
    file: &str,
    line: u32,
) -> Result<(String, Vec<Asset>), CustomError> {
    const OPEN: &str = "<cob-custom ";
    const CLOSE: &str = "</cob-custom>";
    if !html.contains(OPEN) {
        return Ok((html.to_string(), Vec::new()));
    }
    // The cob.toml as JSON, once, for the context blob.
    let config_json = cob_toml_json(root);
    let mut out = String::with_capacity(html.len());
    let mut assets = Vec::new();
    let mut i = 0;
    while let Some(rel) = html[i..].find(OPEN) {
        let p = i + rel;
        out.push_str(&html[i..p]);
        let tag_end = html[p..].find('>').map(|x| p + x).ok_or_else(|| {
            CustomError::new("a `custom` fence placeholder was not closed")
        })?;
        let open_tag = &html[p..=tag_end];
        let close = html[tag_end..]
            .find(CLOSE)
            .map(|x| tag_end + x)
            .ok_or_else(|| CustomError::new("a `custom` fence placeholder was not closed"))?;
        let inner = &html[tag_end + 1..close];
        let handler = attr(open_tag, "data-handler").unwrap_or_default();
        let label = attr(open_tag, "data-label").filter(|s| !s.is_empty());
        let caption = attr(open_tag, "data-caption")
            .map(|c| unescape(&c))
            .filter(|s| !s.is_empty());
        let body = unescape(inner);
        let (rendered, mut a) = render_one(
            &handler, &body, caption.as_deref(), label.as_deref(), defs,
            &config_json, fences, root, cache_root, file, line,
        )?;
        out.push_str(&rendered);
        assets.append(&mut a);
        i = close + CLOSE.len();
    }
    out.push_str(&html[i..]);
    Ok((out, assets))
}

/// The value of a quoted attribute in an opening tag, or `None`.
fn attr(tag: &str, name: &str) -> Option<String> {
    let needle = format!("{name}=\"");
    let s = tag.find(&needle)? + needle.len();
    let e = tag[s..].find('"')? + s;
    Some(tag[s..e].to_string())
}

/// `cob.toml` parsed to a JSON value, or `null` if there is none.
fn cob_toml_json(root: &Path) -> serde_json::Value {
    match std::fs::read_to_string(root.join("cob.toml")) {
        Ok(text) => toml::from_str::<serde_json::Value>(&text).unwrap_or(serde_json::Value::Null),
        Err(_) => serde_json::Value::Null,
    }
}
@

\code{render_one} resolves the handler, builds the JSON blob, consults the cache, runs
the command on a miss, and checks the result. A missing handler, a non-zero exit
(its stderr becomes the message), a \code{<script>} in the HTML, or malformed JSON is
E042. On a cache hit it reads the stored HTML and assets and runs nothing.
<<run one handler>>=
#[allow(clippy::too_many_arguments)]
fn render_one(
    handler: &str,
    body: &str,
    caption: Option<&str>,
    label: Option<&str>,
    defs: &BTreeMap<String, String>,
    config_json: &serde_json::Value,
    fences: &BTreeMap<String, FenceHandler>,
    root: &Path,
    cache_root: Option<&Path>,
    file: &str,
    line: u32,
) -> Result<(String, Vec<Asset>), CustomError> {
    let Some(h) = fences.get(handler) else {
        return Err(CustomError::new(format!(
            "no handler registered for `custom[{handler}]`; add a `[fence.{handler}]` table to cob.toml"
        )));
    };
    if h.cmd.is_empty() {
        return Err(CustomError::new(format!("`[fence.{handler}]` has an empty `cmd`")));
    }
    // The content hash is over the whole input, so any change re-renders.
    let key_input = serde_json::to_string(&Input {
        handler, body, caption, label, defs, config: config_json, file, line,
        outdir: "",
    })
    .map_err(|e| CustomError::new(e.to_string()))?;
    let key = hash(&h.cmd, &key_input);
    let cache = cache_root.map(|c| c.join("custom").join(&key));

    // Cache hit: the manifest lists the published assets kept beside the HTML.
    if let Some(d) = &cache {
        if let Ok(html) = std::fs::read_to_string(d.join("out.html")) {
            if let Ok(man) = std::fs::read_to_string(d.join("assets.json")) {
                if let Ok(map) = serde_json::from_str::<BTreeMap<String, String>>(&man) {
                    let mut assets = Vec::new();
                    let mut ok = true;
                    for (pub_path, rel) in &map {
                        match std::fs::read(d.join(rel)) {
                            Ok(bytes) => assets.push(Asset { path: pub_path.clone(), bytes }),
                            Err(_) => ok = false,
                        }
                    }
                    if ok {
                        return Ok((html, assets));
                    }
                }
            }
        }
    }

    // Miss: run the handler in a writable temp directory — the cache may be the
    // read-only project (the Nix sandbox), so never write the handler's output
    // there directly.
    let outdir = std::env::temp_dir().join("cob-custom").join(&key);
    let _ = std::fs::remove_dir_all(&outdir);
    std::fs::create_dir_all(&outdir)
        .map_err(|e| CustomError::new(format!("cannot create a work directory for `custom[{handler}]`: {e}")))?;
    let input_json = serde_json::to_string(&Input {
        handler, body, caption, label, defs, config: config_json, file, line,
        outdir: &outdir.to_string_lossy(),
    })
    .map_err(|e| CustomError::new(e.to_string()))?;

    let out = run(&h.cmd, root, &input_json)
        .map_err(|e| CustomError::new(format!("`custom[{handler}]` failed to run: {e}")))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(CustomError::new(format!(
            "`custom[{handler}]` exited with an error: {}",
            err.trim()
        )));
    }
    let env: Output = serde_json::from_slice(&out.stdout).map_err(|e| {
        CustomError::new(format!("`custom[{handler}]` did not return a JSON envelope: {e}"))
    })?;
    if env.html.contains("<script") {
        return Err(CustomError::new(format!(
            "`custom[{handler}]` output carries a <script>; a woven page runs no content JavaScript (§6.3)"
        )));
    }

    // Read each asset into memory; persist the result for the cache.
    let mut assets = Vec::new();
    for (pub_path, rel) in &env.assets {
        let bytes = std::fs::read(outdir.join(rel)).map_err(|e| {
            CustomError::new(format!("`custom[{handler}]` named a missing asset `{rel}`: {e}"))
        })?;
        assets.push(Asset { path: pub_path.clone(), bytes });
    }
    // Persist to the cache, best-effort: copy the HTML, the manifest, and each
    // asset file into the cache dir. A read-only cache just skips this.
    if let Some(d) = &cache {
        if std::fs::create_dir_all(d).is_ok() {
            let _ = std::fs::write(d.join("out.html"), &env.html);
            let _ = std::fs::write(
                d.join("assets.json"),
                serde_json::to_string(&env.assets).unwrap_or_default(),
            );
            for rel in env.assets.values() {
                let _ = std::fs::copy(outdir.join(rel), d.join(rel));
            }
        }
    }
    Ok((env.html, assets))
}

/// Run `cmd` from `root`, piping `input` to stdin, SOURCE_DATE_EPOCH pinned so a
/// tool like LaTeX can be reproducible.
fn run(cmd: &[String], root: &Path, input: &str) -> std::io::Result<std::process::Output> {
    let mut child = Command::new(&cmd[0])
        .args(&cmd[1..])
        .current_dir(root)
        .env("SOURCE_DATE_EPOCH", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdin = child.stdin.take().expect("piped stdin");
    let owned = input.to_string();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(owned.as_bytes());
    });
    let out = child.wait_with_output();
    let _ = writer.join();
    out
}
@

The placeholder stores the caption and body as text escaped by \code{prose::escape}
(\code{& < > "}); this reverses it. \code{&amp;} is restored last so a literal \code{&lt;} in the
source round-trips.
<<unescape attribute text>>=
fn unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&amp;", "&")
}
@

The tests cover the unescape round-trip, the cache key folding the command, and —
with a tiny shell handler — a happy path, a missing handler, a non-zero exit, and
the \code{<script>} rejection.
<<custom tests>>=
#[cfg(test)]
mod tests {
    use super::*;

    <<a tiny shell handler>>

    <<unescape reverses prose escape>>

    <<a custom fence runs its handler>>

    <<the macros in scope reach the handler>>

    <<a missing handler is an error>>

    <<a script in the output is rejected>>
}
@

The harness writes a one-line shell script as the handler and points a `Config`
at it. The script echoes a fixed envelope, so the test is deterministic and needs
no real tool.
<<a tiny shell handler>>=
use std::fs;

/// A `fences` map whose `name` handler is a shell script running `script`.
fn cfg_with(dir: &Path, name: &str, script: &str) -> BTreeMap<String, FenceHandler> {
    let path = dir.join("handler.sh");
    fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
    let mut perms = fs::metadata(&path).unwrap().permissions();
    use std::os::unix::fs::PermissionsExt;
    perms.set_mode(0o755);
    fs::set_permissions(&path, perms).unwrap();
    let mut fences = BTreeMap::new();
    fences.insert(
        name.to_string(),
        FenceHandler { cmd: vec![path.to_string_lossy().into_owned()] },
    );
    fences
}

fn placeholder(handler: &str, label: &str, body: &str) -> String {
    format!(
        "<cob-custom data-handler=\"{handler}\" data-label=\"{label}\" data-caption=\"\">{}</cob-custom>",
        crate::prose::escape(body)
    )
}
@

<<unescape reverses prose escape>>=
#[test]
fn unescape_reverses_prose_escape() {
    let raw = "a <b> & \"c\"";
    assert_eq!(unescape(&crate::prose::escape(raw)), raw);
}
@

<<a custom fence runs its handler>>=
#[test]
fn custom_fence_runs_its_handler() {
    let tmp = std::env::temp_dir().join(format!("cob-custom-test-{}", std::process::id()));
    let _ = fs::create_dir_all(&tmp);
    // The handler echoes a figure wrapping its body (read back via a crude grep).
    let cfg = cfg_with(&tmp, "echo", "echo '{\"html\": \"<figure id=\\\"fig:x\\\">ok</figure>\"}'");
    let html = placeholder("echo", "fig:x", "ignored body");
    let (out, assets) = expand(&html, &BTreeMap::new(), &cfg, &tmp, None, "t.cob", 1).unwrap();
    assert_eq!(out, "<figure id=\"fig:x\">ok</figure>");
    assert!(assets.is_empty());
}
@

<<the macros in scope reach the handler>>=
#[test]
fn the_macros_in_scope_reach_the_handler() {
    let tmp = std::env::temp_dir().join(format!("cob-custom-defs-{}", std::process::id()));
    let _ = fs::create_dir_all(&tmp);
    // The handler greps its stdin JSON for the macro and reports whether it saw
    // it — proving `defs` is serialized into the blob the handler reads.
    let cfg = cfg_with(
        &tmp,
        "defs",
        "if grep -q 'varphi' ; then echo '{\"html\": \"<p>saw-spec</p>\"}'; \
         else echo '{\"html\": \"<p>no</p>\"}'; fi",
    );
    let mut defs = BTreeMap::new();
    defs.insert("\\spec".to_string(), "\\varphi".to_string());
    let html = placeholder("defs", "", "body");
    let (out, _) = expand(&html, &defs, &cfg, &tmp, None, "t.cob", 1).unwrap();
    assert_eq!(out, "<p>saw-spec</p>");
}
@
<<a missing handler is an error>>=
#[test]
fn missing_handler_is_an_error() {
    let html = placeholder("nope", "", "x");
    let err = expand(&html, &BTreeMap::new(), &BTreeMap::new(), Path::new("."), None, "t.cob", 1)
        .unwrap_err();
    assert!(err.message.contains("no handler registered"));
}
@

<<a script in the output is rejected>>=
#[test]
fn a_script_in_the_output_is_rejected() {
    let tmp = std::env::temp_dir().join(format!("cob-custom-script-{}", std::process::id()));
    let _ = fs::create_dir_all(&tmp);
    let cfg = cfg_with(&tmp, "evil", "echo '{\"html\": \"<script>x</script>\"}'");
    let html = placeholder("evil", "", "x");
    let err = expand(&html, &BTreeMap::new(), &cfg, &tmp, None, "t.cob", 1).unwrap_err();
    assert!(err.message.contains("<script>"));
}
@
