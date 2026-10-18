@
# cobito — a web-first literate programming system

This document is cobito's own specification, told as a literate program. cobito
is a literate programming system (the command is `cob`): an author writes a
human-readable document first,
then shows how each part of the code comes together. This document holds itself to
that standard.

The specification does not live in one file any more. Each rule lives in the
module that implements it. A module opens with the prose that specifies its job,
then shows the code that meets it. This top-level document holds the parts that
cross every module — the goals, the vocabulary, the architecture — and points to
the module that owns each detail.

## Goals {#sec:teiT}

cob has six goals.

1. Web-first. The primary woven artifact is a multi-page website, not a PDF. Print
   is not a v1 concern.
2. noweb-compatible. A \code{.cob} file uses noweb's chunk syntax, so noweb's
   \code{notangle} can read it unchanged. cob is language-agnostic because the format is.
3. Static generator only. cob is the weaver and the tangler. It ships no server.
   Margin commenting is a separate tool with its own spec, \code{ANNOTATIONS.md}; cob's
   sole obligation to it is annotation-ready HTML (\code{rewrite.rs}).
4. JSON is the contract. Every HTML page is a pure function of a JSON document. No
   exceptions (\code{site.rs}).
5. Review loop. An AI agent reads annotations and proposes revisions to the \code{.cob}
   source (see "The review loop" below).
6. Self-hosting. cob is written in itself: each \code{.cob} file tangles to its part of
   the Rust crate (see "Self-hosting" below).

## Non-goals {#sec:68J6}

- PDF or print output. A \code{--tex} backend may come later.
- Pretty-printing or code reformatting. cob never reflows, re-indents, or rewrites
  the bytes a reader sees. Code chunks render exactly as written — noweb's
  position, and cob keeps it. Syntax highlighting only colors those unchanged
  bytes (\code{highlight.rs}), so this line still stands.
- cweb's \code{@d} macros. noweb has no equivalent, because \code{#define} is C-specific.
  Named chunks cover the need.
- A WYSIWYG authoring UI.
- A comment or annotation server. That is a separate tool (\code{ANNOTATIONS.md}).
- Multi-user real-time collaboration. Comments are asynchronous.

## Vocabulary {#sec:lxbi}

```table
\caption{The words this document uses.}
| Term | Meaning |
|---|---|
| project | A directory with a \code{cob.toml}. It holds one or more documents. |
| document | An ordered list of \code{.cob} files woven into one site with unified numbering. It has an id, used in URLs. |
| chunk | noweb's unit: a docs chunk (prose) or a code chunk (named, tangleable). |
| section | cob's unit of anchoring and rendering. One chunk makes one section. |
| page | An output HTML file. It holds a contiguous run of sections. |
| root | A code chunk that tangles to a file on disk. |
| node | An addressable heading and the content under it, up to the next heading at the same or a shallower level. The heading nesting is the node tree. |
| transclusion | Showing one node a second time in another place, as a scoped copy with a backlink, not a link. |
```

A document may span several \code{.cob} files, because \code{markup} accepts several and
emits a file marker between them. The numbering, the labels, and the chunk
resolution are all document-wide.

## Architecture {#sec:8GfD}

cob reads and tangles a \code{.cob} file with its own Rust code. It runs no external
tool. The native reader (\code{src/markup.rs}) folds a \code{.cob} file into noweb's
line-oriented IR — the same events noweb's \code{markup} makes — and cob owns
everything downstream. cob never used \code{noweave}: it makes prose-to-HTML itself,
and the IR hands it the chunk structure as data, not as generated markup it must
read back. noweb stays only as a test oracle: a frozen set of \code{markup} outputs
proves the native reader right (§4.1, §15).

```verbatim
  PHASE 1 — static generator (no Python, no server)

  *.cob ──> cob reader ──> IR ──────┐
                                    │
   ┌────────────────────────────────┴───────────────────────────┐
   │ Rust                                                        │
   │  1. parse IR       → chunk list                             │
   │  2. resolve        → chunk graph, defs/uses, continuations  │
   │  3. prose pipeline → math out, HTML parse, refs, ids        │
   │  4. number         → figures, tables, equations, chunks     │
   │  5. split          → pages, nav tree, prev/next             │
   │  6. serialize      → site.json                              │
   │  7. render         → minijinja + templates/                 │
   └────────────────────────────────┬───────────────────────────┘
                                    │
                              _site/{*.html,*.json,static/}

  *.cob ──> cob tangle -R'src/main.rs' ──> src/main.rs


  ANNOTATION LAYER — separate tool, separate spec (ANNOTATIONS.md)

  _site/*.html ──(overlay / embed)──> margin comments on woven pages
        │  HTML carries provenance attributes (rewrite.rs)
        ▼
  annotations (W3C JSON) ──> cob review ──> unified diff against *.cob
```

## Where each part lives {#sec:Fv9U}

Each module carries the specification for its own job. This is the reading order.

```table
\caption{Each concern and the module that owns it.}
| Concern | Module |
|---|---|
| The native reader: a \code{.cob} file to the IR event stream | \code{src/markup.rs.cob} |
| The IR event type and its parser; verified noweb behavior; the oracle | \code{src/noweb.rs.cob} |
| The document model: chunk continuation, roots, line counting | \code{src/model.rs.cob} |
| The project manifest, the prose dialect, config keys | \code{src/config.rs.cob} |
| The prose pipeline: reassembly, math substitution, ordering | \code{src/prose.rs.cob} |
| The Markdown dialect and fenced-float directives | \code{src/markdown.rs.cob} |
| The \code{algorithm} fence: a native pseudocode renderer | \code{src/pseudocode.rs.cob} |
| The \code{custom} fence: a registered CLI renders the body | \code{src/custom.rs.cob} |
| Math rendering: KaTeX at weave time, the cache | \code{src/math.rs.cob} |
| Labels, numbering, cross-references, the resolver | \code{src/resolve.rs.cob} |
| Stable ids and the lock file | \code{src/lock.rs.cob} |
| Source-side section anchors: auto ids, \code{rename-label} | \code{src/section.rs.cob} |
| Prose rewriting, the HTML parser, the annotation contract | \code{src/rewrite.rs.cob} |
| The \code{site.json} contract and page boundaries | \code{src/site.rs.cob} |
| The weaver: rendering a code chunk | \code{src/weave.rs.cob} |
| Syntax highlighting | \code{src/highlight.rs.cob} |
| The node model and transclusion | \code{src/transclude.rs.cob} |
| Importing macros from another forest | \code{src/import.rs.cob} |
| Fetching a remote forest import | \code{src/fetch.rs.cob} |
| Citations and the bibliography | \code{src/cite.rs.cob} |
| Reverse backlinks across the forest | \code{src/backlinks.rs.cob} |
| Tangling | \code{src/tangle.rs.cob} |
| Long-form diagnostics | \code{src/diag.rs.cob} |
| The CLI | \code{src/main.rs.cob} |
| The build, told as a literate program | \code{flake.nix.cob} |
| The editor grammar for \code{.cob} files | \code{tree-sitter-cob/tree-sitter-cob.cob} |
```

## Grammars {#sec:adding-grammars}

cob is language-agnostic. Only syntax highlighting is language-bound (§5.5). So a
grammar is a **build input**, not a built-in. The shipped \code{cob} binary has an
empty grammar set, and it highlights nothing until you add a grammar. This keeps
cob small. It also lets you highlight any language that has a tree-sitter grammar,
with no change to cob.

You add a grammar in your own flake. You pin the grammar's tree-sitter repo as an
input, then pass it to \code{withGrammars} on the \code{cob} or \code{static} package:

```verbatim \lang{nix}
cobito.packages.${system}.cob.withGrammars [
  { id = "sql"; exts = [ "sql" ]; src = tree-sitter-sql; }
]
```

Each grammar is a record. \code{id} is the language name, \code{exts} are the file
extensions that select it, and \code{src} is the repo. The \code{symbol} field (the
\code{tree_sitter_<name>} C entry point) defaults from \code{id}, so a normal grammar needs
three fields. \code{build.rs} compiles each grammar in the set and makes its registry
entry (§5.5). The \code{README} gives the full steps.

cobito needs four grammars to weave its own documents: Rust, Nix, Bash, and CSS.
The flake keeps them in \code{cobGrammars} and builds the \code{cobDoc} output with them.
The checks use \code{cobDoc}, so they prove cob colors its own source. The shipped
\code{cob} does not carry these four. They are cobito's need, not a default for you.

## The review loop {#sec:av7Q}

\code{cob review} closes the loop from a reader's margin comment back to the source. It
runs in six steps.

1. It fetches the open annotations as W3C Web Annotation JSON from the configured
   backend. A backend is an adapter; the agent codes against the W3C shape only.
2. It maps each annotation to source. The annotation's exact-quote selector locates
   the text on the woven page. The enclosing section's provenance attributes locate
   the \code{.cob} region.
3. It asks for a unified diff against the \code{.cob} source — never against the woven
   HTML.
4. It validates the patch: the patch applies cleanly, \code{cob weave} still succeeds,
   and \code{cob tangle} output is unchanged unless a thread explicitly asked for a code
   change.
5. It presents a reviewable diff. Nothing auto-commits.
6. On acceptance, the addressed threads resolve with a pointer to the resulting
   revision.

Step 4 holds the important safety property: prose feedback must not silently alter
the program.

## Self-hosting {#sec:7p6J}

cob is written in itself. The path had three stages. First, cob was written
normally in Rust. Second, once weave and tangle were stable, each module was ported
into a \code{.cob} file that tangles into the existing tree; CI ran \code{cob tangle --check}
to assert the committed \code{.rs} matched what the literate source made. Third, the
flip: the \code{.cob} files became the only source of truth.

The flip is done. On \code{main} the whole Rust crate and the stylesheet are literate,
and no \code{.rs} or \code{.css} is committed — each one comes from a \code{.cob}. The one
authority is the set of \code{.cob} files. The flake build is two stages. A tangler must
exist before anything can be tangled, and cob's tangler is native now (§11) — there
is no noweb to seed with. So the build seeds from the \code{tangled} release branch,
which does commit the \code{.rs}/\code{.css}. Stage 0 builds \code{cob} from that seed. Stage 1
uses that \code{cob} to tangle every \code{.cob} again, then builds from the result. Both
trees compile to a working \code{cob}.

\code{checks.selfhost} proves the loop: the shipped \code{cob} must tangle every module to
the same bytes as the tree it was built from. cob is a fixed point of its own
tangler — the source it makes is the source it is made of. No second tangler runs.

The \code{tangled} branch is the one reseed point. A build on \code{main} pins it by tag,
and a release pushes a new snapshot and bumps the pin. noweb is gone from the build
and the run time; it stays only as a frozen test oracle (§4.1, §15).

The one file that stays committed is \code{flake.nix}, because Nix must read it before
any tangle can run. \code{flake.nix.cob} is cob's own build file told as a literate
program; it tangles byte-for-byte into the committed \code{flake.nix}. \code{checks.dogfood}
runs \code{cob tangle --check} so the literate source and this one bootstrap file never
drift, and it weaves the page to prove the Nix grammar colored it — self-hosting the
highlighter, which is why Nix is the second grammar.

## Nix {#sec:JPcq}

The build is flake-based, and it runs no noweb. cob reads and tangles \code{.cob}
natively (§4.1, §11), so the CLI wrapper only sets the KaTeX asset path for weave
(§6.3). The \code{main} flake seeds the build from the \code{tangled} branch, pinned as a
flake input. The \code{tangled} branch carries a build-only flake that compiles its
committed tree straight. Both share one builder, so there is one source of truth for
the parts that do not differ. A second package, \code{cob-static}, is a standalone
static binary with the KaTeX dist baked in (§6.3).

The flake carries the checks that guard cob's invariants: a build with the hermetic
cargo tests, a determinism check that weaves twice and byte-diffs, a reader check
that diffs the native reader against the frozen \code{markup} goldens, a tangle check
against the frozen \code{notangle} goldens, a modules check that weaves every module,
and the self-host and dogfood checks above. A flake sees only tracked files, so the
generated \code{.rs}/\code{.css} — ignored on \code{main} — come from the seed. The full build
lives in \code{flake.nix.cob}.

## Testing {#sec:LEQV}

Each layer has its own strategy.

```table
\caption{The test strategy for each layer.}
| Layer | Strategy |
|---|---|
| IR parser | Golden tests over pinned \code{markup} output; guards against noweb version drift. |
| Prose pipeline | Snapshot tests per stage, especially math-extraction edge cases. |
| Numbering and refs | Property test: every reference resolves; numbers are dense and monotonic. |
| Split | Property test: concatenating all pages' sections reproduces the section list. |
| Tangle | Against frozen \code{notangle} goldens; \code{--check} flags drift. |
| Determinism | Weave twice, diff. |
| Annotation contract | Assert every section carries its id and provenance and a margin slot. |
```

## Milestones {#sec:UnND}

Phase 1, the static generator, is complete: the flake and IR parser (M0), the prose
pipeline and math (M1), numbering and page splitting and templates (M2), tangle via
notangle (M3), and \code{site.json} with the manifest and diagnostics (M4).

Phase 2 is annotation integration, where the annotation layer itself is the
separate tool of \code{ANNOTATIONS.md}: the annotation-ready HTML contract (M5), \code{cob
review} (M6), and a reserved slot for the annotation-layer fallback (M7).

Phase 3 is done in its shipped slices: the Markdown dialect (M8), stable ids and
the lock file (M11), self-hosting and the flip (M13), syntax highlighting (M14),
the node model with same-document transclusion (M12, first slice), math macros
(M9 — the \code{macros} fence, forester \code{\def}/\code{\let}, a homeless \code{def:} node), and
citations (M10 — \code{\cite{key}} against a BibTeX bibliography, each cited work a node
with a frozen \code{[id]} marker, a node page, "Cited by" backlinks, and a References
list, \code{cite.rs}; cross-forest \code{\cite{key@alias}} resolves against a forest's
exported citations index). Phase 3 is complete.

## The forest (M16) {#sec:forest}

M16 makes cob a forest: one project's documents, and other forests, reachable by a
local namespace alias (§13). The slices, in order:

- **Lazy transclusion — done.** \code{\transclude} lowers to a \code{<cob-transclude>}
  element that fetches a node's own \code{n/} page into a shadow root, with a link
  fallback. The body is stored once; a copy is a reference, so a big forest does not
  multiply the bytes (§10).
- **Macro import — done.** An \code{imports} fence binds a source to an alias
  (\code{\import algebra as alg}); \code{\alg.RR} uses its macros. Each imported macro gets a
  content id (a merkle hash), so it is clash-free and shared across forests
  (\code{import.rs.cob}). A forest exports its macro table as \code{cob-exports.json}.
- **Cross-document \code{\ref}/\code{\transclude} — done.** \code{\ref{sec:x@alg}} and
  \code{\transclude{def:y@alg}} resolve against the import's \code{cob-exports.json}, which now
  carries a label index (\code{label} to id, kind, page, and anchor). A reference lands on
  the forest's deployed page, \code{<url>/<page>.html#<anchor>}, with the kind-qualified
  opaque id as its text; the \code{url} comes from the \code{[import.<alias>]} table
  (\code{config.rs.cob}). A cross-document \code{\transclude} is just a \code{<cob-transclude src>}
  at the other forest's node page (\code{<url>/n/<id>.html}), so the lazy element already
  handles it. An unknown alias or label is E015 for a \code{\ref}, W106 for a
  \code{\transclude}, the same as any local miss.
- **\code{cob fetch} + versioning — done.** A \code{git}-URL import is pinned to a commit
  and cached by a separate \code{cob fetch} step (\code{fetch.rs.cob}), so a weave reads only
  the cache and stays offline. A forest publishes releases as **semver git tags**,
  each tag's root carrying \code{cob-exports.json}; an import names a **semver
  requirement** (\code{version = "^1.2"}), or a raw \code{rev} as an escape hatch. \code{cob fetch}
  clones the ref with \code{gix}, picks the highest tag matching the requirement, reads
  that one file, caches it at \code{.cob-cache/imports/<sha>/}, and records the pin
  (\code{git}, \code{req}, \code{version}, \code{sha}) in the \code{fetch} section of \code{cob.lock}. \code{cob fetch}
  **honors the lock** (resolves only what is new or changed); \code{cob update [alias]}
  re-resolves to the newest matching release; a moved release tag is E037. The
  \code{cob.lock} and \code{cob-exports.json} schemas are **semver and enforced**: a newer
  major is E038. A weave resolves a \code{git} import through its pin; an unfetched one
  is E037. A local \code{path} import needs no fetch and wins when both are set.
- **Reverse backlinks — done (node-level).** A forest records its outgoing
  cross-forest edges in \code{cob-exports.json} (schema 1.2.0); \code{cob backlinks
  <site-dir>...} (\code{backlinks.rs.cob}) inverts them — joining on each forest's own
  \code{[forest] url} — and writes a \code{n/<id>.backlinks.html} fragment per targeted node.
  A node page fetches it lazily (the \code{<cob-backlinks>} element), so a forest shows
  "Referenced by" / "Cited by" / "Transcluded by" from other forests without
  re-weaving. Forest-level "imported by" is a cheap follow-up on the same inversion.

The deferred node-model slices — floats as nodes and per-node pages — are shipped;
the remaining transclusion notes are in \code{transclude.rs.cob}.

The native reader is the first slice of M15: cob reads its own \code{.cob} source with a
Rust reader (\code{markup.rs}), so no \code{markup} process runs at read time and cob can ship
as one binary. The reader is a formal PEG grammar that the \code{peg} crate builds into a
parser at compile time (\code{markup.rs.cob}). A native tangler (§11) replaced
\code{notangle} too, so cob runs no noweb tool at all. noweb stays only as a test
oracle: frozen \code{markup} and \code{notangle} goldens prove the native reader and
tangler right (§15). The \code{reader} and \code{tangle} flake checks diff cob against
those goldens.

## Open questions {#sec:QznE}

- One review patch per run, or per thread? Per-thread accepts granularly but
  conflicts when two threads touch the same prose. The lean is one patch per run
  with per-thread attribution in the diff.
- Should cob watch and rebuild for a local authoring loop? The feedback loop is poor
  without it.

Resolved questions are recorded where they were settled: the one prose dialect lives
in \code{config.rs.cob}, the two-pass rewriter in \code{rewrite.rs.cob}, and the choice to skip
\code{noweave} in this document's architecture section.

## Risks {#sec:4y6v}

- KaTeX via a JS engine adds build weight and weave latency. The cache mitigates it.
- Self-hosting could make a weaver bug a bootstrap risk. The mitigation is that
  stage 0 bootstraps from \code{notangle}, a stable external tool, not from \code{cob}, so no
  cob bug can break the bootstrap or poison a committed artifact — there is none.
- Re-anchoring quality is the annotation layer's concern, tracked in
  \code{ANNOTATIONS.md}, because the anchoring is done by its selector machinery rather
  than by heuristics cob invents.

## Error codes {#sec:oXEK}

cob reports one diagnostic format from every stage (\code{diag.rs.cob}). Each code is
stable, so a test or a suppression can name one error and no other. When a module
introduces a code, it claims the next free number in this registry.

```table
\caption{The error and warning codes.}
| Code | Meaning | Module |
|---|---|---|
| E001 | malformed IR line from \code{markup} | \code{noweb.rs} |
| E002 | retired (was \code{markup} process failure); cob reads natively | \code{noweb.rs} |
| E010 | use of an undefined chunk | \code{model.rs} |
| E014 | duplicate label | \code{resolve.rs} |
| E015 | unresolved reference | \code{resolve.rs} |
| E020 | math render failure | \code{math.rs} |
| E022 | unterminated math delimiter | \code{prose.rs} |
| E023 | KaTeX assets missing | \code{weave.rs} |
| E024 | writing the site failed | \code{weave.rs} |
| E025 | template render failure | \code{weave.rs} |
| E026 | rewriting prose HTML failed | \code{rewrite.rs} |
| E027 | retired (was \code{notangle} failure); cob tangles natively | \code{tangle.rs} |
| E028 | writing tangled output failed | \code{tangle.rs} |
| E029 | \code{cob.toml} unreadable or malformed | \code{config.rs} |
| E030 | malformed fence modifier | \code{markdown.rs} |
| E031 | label absent from \code{cob.lock} under \code{--locked} | \code{lock.rs}, \code{weave.rs} |
| E032 | \code{cob.lock} unreadable, malformed, or unwritable | \code{lock.rs} |
| E033 | a highlight key names an unknown language | \code{main.rs} |
| E034 | bare or unknown fence kind | \code{markdown.rs} |
| E035 | recursive chunk expansion (cycle) | \code{tangle.rs} |
| E036 | a macro import fails (unknown, cycle, or id clash) | \code{import.rs} |
| E037 | a remote import fetch fails, or a git import is not fetched | \code{fetch.rs} |
| E038 | a \code{cob.lock} or \code{cob-exports.json} has a newer major schema | \code{lock.rs}, \code{site.rs} |
| E039 | the bibliography file does not read or parse | \code{cite.rs} |
| E040 | a \code{\cite} names a key no bibliography has | \code{weave.rs} |
| E041 | \code{cob backlinks} could not write a fragment | \code{backlinks.rs} |
| E042 | a \code{custom} fence handler fails (unregistered, non-zero exit, script, bad envelope) | \code{custom.rs} |
| W102 | chunk defined but never used | \code{model.rs} |
| W103 | figure or table without a caption | \code{resolve.rs} |
| W104 | code chunk resolved to no known language | \code{weave.rs} |
| W105 | transclusion cycle | \code{transclude.rs} |
| W106 | transclusion of an unknown target | \code{transclude.rs} |
| W107 | a referenced local asset was not found | \code{weave.rs} |
```

## Conventions {#sec:zBDS}

- Dependencies are added reluctantly, one at a time, only when a task needs them.
  Never add one speculatively.
- No panics outside tests. Everything user-facing goes through the diagnostic format
  with a code.
- Every noweb-boundary discovery gets a fixture. A minimal \code{.cob} plus regenerated
  \code{.markup} pair and a test is how the verified-noweb prose stays true.
- noweb is gone from the run time. A native reader (\code{markup.rs}) replaced the
  \code{markup} process, and a native tangler (\code{tangle.rs}) replaced \code{notangle} (M15).
  noweb stays only as a test oracle — the frozen \code{markup} and \code{notangle} goldens.
  Remake the affected golden when a fixture changes.
- Determinism is a feature. No timestamps, and no HashMap iteration order in output —
  a \code{BTreeMap} or an explicit sort.
- When a decision conflicts with observed reality, verification wins: probe the real
  binary, record the finding, update the prose.

All \code{.cob} prose follows ASD-STE100 Simplified Technical English: short active
present-tense sentences, one idea each, approved plain verbs, and the reason before
the mechanism.
@
