# Architecture

Struo is a Free Pascal program that builds itself. This document is the map of
the source tree and the rules that keep it navigable.

## Source layout

```
src/
├── struo.pas                     program entry point: argv -> exit code
├── cli/
│   ├── Struo.Cli.Output.pas      all terminal output; colour and verbosity
│   ├── Struo.Cli.Args.pas        argv -> flags, options, positionals
│   ├── Struo.Cli.Command.pas     the command interface + registry
│   └── Struo.Cli.Help.pas        usage text generation
├── core/
│   ├── Struo.Types.pas           shared types and the Struo exception root
│   ├── Struo.Paths.pas           STRUO_HOME, caches, target dirs
│   ├── Struo.SemVer.pas          versions and version requirements
│   ├── Struo.Manifest.pas        the Struo.toml model, load and validate
│   ├── Struo.Manifest.Editor.pas surgical manifest edits for add/remove
│   ├── Struo.Package.pas         a loaded package: manifest + targets
│   ├── Struo.Targets.pas         target inference from the layout
│   ├── Struo.Lockfile.pas        Struo.lock read and write
│   ├── Struo.Resolver.pas        requirements -> a resolved dependency graph
│   ├── Struo.Source.pas          fetching path and git dependencies
│   ├── Struo.Registry.pas        the index: search, versions, download
│   └── Struo.Compiler.pas        FPC discovery and invocation
├── commands/
│   ├── Struo.Cmd.New.pas         new, init
│   ├── Struo.Cmd.Build.pas       build, check
│   ├── Struo.Cmd.Run.pas         run
│   ├── Struo.Cmd.Test.pas        test
│   ├── Struo.Cmd.Clean.pas       clean
│   ├── Struo.Cmd.Deps.pas        add, remove, update, tree
│   ├── Struo.Cmd.Registry.pas    search, publish, login, logout
│   └── Struo.Cmd.Doctor.pas      doctor
├── toml/
│   ├── Struo.Toml.Value.pas      the value tree (ordered tables)
│   ├── Struo.Toml.Lexer.pas      text -> tokens
│   ├── Struo.Toml.Parser.pas     tokens -> value tree
│   └── Struo.Toml.Writer.pas     value tree -> text (generated files only)
└── util/
    ├── Struo.Util.Strings.pas    string helpers Free Pascal lacks
    ├── Struo.Util.Fs.pas         paths, recursive copy and delete
    └── Struo.Util.Proc.pas       run a child process, capture its output
```

Unit names mirror their path: `src/core/Struo.Manifest.pas` is unit
`Struo.Manifest`. Dotted unit names work in `{$mode objfpc}`, so the namespace
is real, not a prefix convention.

## Dependency direction

```
commands  ->  core  ->  toml
    |          |          |
    +----------+----------+---->  util
    |
    +---->  cli
```

Layers only depend downward. In particular:

- **`util` depends on nothing of ours.** Pure helpers, no Struo concepts.
- **`toml` knows nothing about manifests.** It is a general TOML subset parser;
  the manifest model interprets its output.
- **`core` never writes to the terminal.** It raises `EStruoError` with a
  message and, where useful, a hint. The CLI layer decides how to render it.
- **`commands` is the only layer that may call `cli`.** A command reads argv,
  asks `core` to do the work, and reports.

`Struo.Cli.Output` is the single exception to the layering rules: anything may
use it to emit `--verbose` trace lines, because tracing is cross-cutting.

## Error handling

`core` raises; it does not print and does not call `Halt`.

```pascal
raise EStruoError.CreateHint(
  Format('no package found in `%s`', [ADir]),
  'run `struo init` to create one'
);
```

`struo.pas` has the only `try..except` that reaches the user. It renders the
message as `error: <message>` and the hint as `hint: <hint>`, then exits `1`.
Command-line mistakes raise `EStruoUsageError`, which exits `2`.

## Output conventions

Struo copies Cargo's output shape because it reads well and Pascal developers
coming from Rust will recognise it: a twelve-column right-aligned green verb,
then the detail.

```
   Compiling hello v0.1.0 (C:\dev\hello)
    Finished `debug` profile [unoptimized + debuginfo] in 0.41s
     Running `target\debug\hello.exe`
```

Every line goes through `Struo.Cli.Output`, which owns the column width, the
ANSI codes, and the `--quiet`/`--color` decisions. Nothing else writes to
stdout or stderr directly.

## The build pipeline

`struo build` is the backbone; the other commands are variations on it.

1. **Discover.** Walk up from the working directory to the nearest
   `Struo.toml` (`Struo.Workspace`).
2. **Load.** Parse the manifest, validate it, infer targets from the layout
   (`Struo.Manifest`, `Struo.Targets`).
3. **Resolve.** Read `Struo.lock` if it is current; otherwise resolve
   requirements to concrete versions and write a new lockfile
   (`Struo.Resolver`, `Struo.Lockfile`).
4. **Fetch.** Make sure every resolved package is on disk, under
   `$STRUO_HOME/cache` for registry and git sources (`Struo.Source`).
5. **Compile.** Topologically order the graph, then compile each package into
   `target/<profile>/deps/<name>-<version>/`, accumulating `-Fu` paths as we
   go (`Struo.Compiler`).
6. **Link.** Compile this package's targets with the accumulated unit paths,
   emitting binaries into `target/<profile>/`.

Steps 3 through 5 are no-ops for a package with no dependencies, which is why
`struo new` + `struo build` works before the resolver exists.

## Testing

`tests/` holds one program per area, each exiting non-zero on failure:

```console
$ ./bootstrap/build.ps1 -Tests
```

Unit-level tests cover the TOML parser, SemVer comparison and requirement
matching, manifest validation, and the compiler argument builder — the four
places where a silent bug would be expensive.
