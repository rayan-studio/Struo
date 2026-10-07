{ Struo.Resolver -- requirements into a graph of packages on disk.

  The result is ordered: a package always appears after everything it depends
  on, which is exactly the order the compiler needs, because a unit's .ppu
  must exist before anything that uses it is compiled. A post-order traversal
  gives that ordering for free.

  One constraint here is Pascal's rather than Struo's, and it is worth being
  explicit about. Unit names are global: there is no way for two versions of
  `fjson` to be on one compiler's search path and have each dependent see the
  one it asked for. Cargo can link two major versions of a crate side by side;
  Struo cannot, and pretending otherwise would produce a build that silently
  compiles against the wrong code. So a name resolving to two different
  sources or versions is an error that names both claimants, and the fix is a
  decision only the author can make. }
unit Struo.Resolver;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Struo.Util.Strings, Struo.Types, Struo.SemVer, Struo.Manifest,
  Struo.Lockfile;

type
  TResolvedPackage = record
    Name: string;
    Version: TSemVer;
    { The directory holding this package's own source. }
    Root: string;
    { As Struo.Source.DescribeSource renders it. Empty for the root package. }
    Source: string;
    { The loaded manifest. Owned by the graph unless this is the root. }
    Manifest: TManifest;
    { The names this package depends on. }
    DependencyNames: TStrArray;
    { True for the package the command was run in. }
    IsRoot: Boolean;
    { False for the root, whose manifest belongs to the caller. }
    OwnsManifest: Boolean;
  end;

  TDependencyGraph = class
  private
    FPackages: array of TResolvedPackage;
  public
    destructor Destroy; override;

    function Count: Integer;

    { Dependencies first, the root package last. }
    function PackageAt(AIndex: Integer): TResolvedPackage;

    function Find(const AName: string; out APackage: TResolvedPackage): Boolean;
    function Contains(const AName: string): Boolean;

    { Everything but the root, in compile order. }
    function Dependencies: Integer;

    { The lockfile this graph implies. The caller owns it. }
    function ToLockfile: TLockfile;

    procedure Add(const APackage: TResolvedPackage);
  end;

{ Walks ARootManifest's dependencies, fetching each one's source, and returns
  the graph. ARootManifest stays the caller's to free; every manifest the
  resolver loads belongs to the graph.

  AIncludeDev adds the root's dev-dependencies. A dependency's own
  dev-dependencies are never included: they are for testing that package, not
  for building it. }
function ResolveGraph(ARootManifest: TManifest; AIncludeDev: Boolean): TDependencyGraph;

implementation

uses
  Struo.Util.Fs, Struo.Targets, Struo.Source, Struo.Cli.Output;

{ ---- TDependencyGraph ---------------------------------------------------- }

destructor TDependencyGraph.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FPackages) do
    if FPackages[I].OwnsManifest then
      FPackages[I].Manifest.Free;
  FPackages := nil;
  inherited Destroy;
end;

function TDependencyGraph.Count: Integer;
begin
  Result := Length(FPackages);
end;

function TDependencyGraph.Dependencies: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FPackages) do
    if not FPackages[I].IsRoot then
      Inc(Result);
end;

function TDependencyGraph.PackageAt(AIndex: Integer): TResolvedPackage;
begin
  if (AIndex < 0) or (AIndex > High(FPackages)) then
    raise EStruoError.CreateHintFmt('package index %d is out of range', [AIndex], '');
  Result := FPackages[AIndex];
end;

function TDependencyGraph.Find(const AName: string;
  out APackage: TResolvedPackage): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FPackages) do
    if SameText(FPackages[I].Name, AName) then
    begin
      APackage := FPackages[I];
      Exit(True);
    end;
  APackage := Default(TResolvedPackage);
  Result := False;
end;

function TDependencyGraph.Contains(const AName: string): Boolean;
var
  LPackage: TResolvedPackage;
begin
  Result := Find(AName, LPackage);
end;

procedure TDependencyGraph.Add(const APackage: TResolvedPackage);
begin
  SetLength(FPackages, Length(FPackages) + 1);
  FPackages[High(FPackages)] := APackage;
end;

function TDependencyGraph.ToLockfile: TLockfile;
var
  I: Integer;
begin
  Result := TLockfile.Create;
  try
    for I := 0 to High(FPackages) do
      Result.Add(MakeLockedPackage(FPackages[I].Name, FPackages[I].Version,
        FPackages[I].Source, FPackages[I].DependencyNames));
  except
    Result.Free;
    raise;
  end;
end;

{ ---- the resolver -------------------------------------------------------- }

type
  TResolver = class
  private
    FGraph: TDependencyGraph;
    { Names on the current traversal path, lowercased, for cycle detection. }
    FVisiting: TStrArray;
    { How the chain got here, for a cycle message a user can act on. }
    FChain: TStrArray;

    procedure VisitDependencies(AManifest: TManifest; AIncludeDev: Boolean);
    procedure VisitDependency(const ADependency: TDependency; AParent: TManifest);
    procedure CheckConsistent(const ADependency: TDependency;
      const AExpectedSource: string; const AExisting: TResolvedPackage);
  public
    function Resolve(ARootManifest: TManifest; AIncludeDev: Boolean): TDependencyGraph;
  end;

procedure TResolver.CheckConsistent(const ADependency: TDependency;
  const AExpectedSource: string; const AExisting: TResolvedPackage);
begin
  if AExisting.Source = AExpectedSource then
    Exit;

  { Pascal unit names are global, so there is no arrangement under which both
    claimants can be satisfied. Say what each one is and let the author
    choose. }
  raise EStruoError.CreateHintFmt(
    'package `%s` is required from two different sources', [ADependency.Name],
    Format('one resolution says `%s`, another says `%s`; Pascal unit names ' +
           'are global, so only one can be on the search path',
      [AExisting.Source, AExpectedSource]));
end;

procedure TResolver.VisitDependency(const ADependency: TDependency;
  AParent: TManifest);
var
  LRoot, LRevision, LSource, LKey: string;
  LManifest: TManifest;
  LExisting: TResolvedPackage;
  LPackage: TResolvedPackage;
  I: Integer;
begin
  LKey := LowerCase(ADependency.Name);

  { A cycle. Report the path that produced it; the names alone would leave
    the author guessing which edge to cut. }
  if StrArrayHas(FVisiting, LKey) then
  begin
    StrArrayAdd(FChain, ADependency.Name);
    raise EStruoError.CreateHintFmt('dependency cycle: %s',
      [JoinStr(FChain, ' -> ')],
      'a package cannot depend on something that depends on it');
  end;

  LRevision := '';
  case ADependency.Kind of
    dkPath:
      LRoot := ResolvePathSource(ADependency, AParent.Root);
    dkGit:
      LRoot := FetchGitSource(ADependency, LRevision);
  else
    { No registry yet. The message says exactly what to do instead. }
    FailRegistryNotAvailable(ADependency.Name);
    LRoot := '';
  end;

  LSource := DescribeSource(ADependency, LRevision);

  { Already resolved by another dependent: check the two agree, then stop. }
  if FGraph.Find(ADependency.Name, LExisting) then
  begin
    CheckConsistent(ADependency, LSource, LExisting);
    Exit;
  end;

  LManifest := TManifest.Load(JoinPath(LRoot, CManifestName));
  try
    { The manifest's own name is what counts. A dependency named `foo` whose
      path points at a package calling itself `bar` would put bar's units on
      the search path while the author wrote `uses foo`, and the compiler
      error would name neither of them. }
    if not SameText(LManifest.Name, ADependency.Name) then
      raise EStruoError.CreateHintFmt(
        'dependency `%s` resolves to a package that calls itself `%s`',
        [ADependency.Name, LManifest.Name],
        'rename the dependency to match the package it points at');

    { A registry requirement constrains the version; a path or git dependency
      is taken as given, since the author pointed at it directly. }
    if (ADependency.Kind = dkRegistry) and
       not VersionReqMatches(ADependency.Req, LManifest.Version) then
      raise EStruoError.CreateHintFmt(
        '`%s` is at version %s, which does not satisfy `%s`',
        [ADependency.Name, SemVerToStr(LManifest.Version),
         VersionReqToStr(ADependency.Req)], '');

    InferTargets(LManifest);

    StrArrayAdd(FVisiting, LKey);
    StrArrayAdd(FChain, ADependency.Name);
    try
      { Depth first, so this package is added after everything it needs. }
      VisitDependencies(LManifest, False);
    finally
      StrArrayRemoveAt(FVisiting, StrArrayIndexOf(FVisiting, LKey));
      StrArrayRemoveAt(FChain, High(FChain));
    end;

    LPackage := Default(TResolvedPackage);
    LPackage.Name := LManifest.Name;
    LPackage.Version := LManifest.Version;
    LPackage.Root := LRoot;
    LPackage.Source := LSource;
    LPackage.Manifest := LManifest;
    LPackage.OwnsManifest := True;
    LPackage.IsRoot := False;
    for I := 0 to High(LManifest.Dependencies) do
      if not LManifest.Dependencies[I].IsDev then
        StrArrayAdd(LPackage.DependencyNames, LManifest.Dependencies[I].Name);

    FGraph.Add(LPackage);
    TraceFmt('resolved %s v%s from %s',
      [LPackage.Name, SemVerToStr(LPackage.Version), LSource]);
  except
    LManifest.Free;
    raise;
  end;
end;

procedure TResolver.VisitDependencies(AManifest: TManifest; AIncludeDev: Boolean);
var
  I: Integer;
begin
  for I := 0 to High(AManifest.Dependencies) do
  begin
    if AManifest.Dependencies[I].IsDev and not AIncludeDev then
      Continue;
    { An optional dependency waits for the feature that enables it, which is
      not implemented yet; skipping it is the behaviour that cannot be wrong. }
    if AManifest.Dependencies[I].Optional then
    begin
      TraceFmt('skipping optional dependency `%s`',
        [AManifest.Dependencies[I].Name]);
      Continue;
    end;
    VisitDependency(AManifest.Dependencies[I], AManifest);
  end;
end;

function TResolver.Resolve(ARootManifest: TManifest;
  AIncludeDev: Boolean): TDependencyGraph;
var
  LPackage: TResolvedPackage;
  I: Integer;
begin
  FGraph := TDependencyGraph.Create;
  try
    StrArrayAdd(FChain, ARootManifest.Name);
    VisitDependencies(ARootManifest, AIncludeDev);

    { The root goes last, so the compile order reads straight through. }
    LPackage := Default(TResolvedPackage);
    LPackage.Name := ARootManifest.Name;
    LPackage.Version := ARootManifest.Version;
    LPackage.Root := ARootManifest.Root;
    LPackage.Source := '';
    LPackage.Manifest := ARootManifest;
    LPackage.OwnsManifest := False;
    LPackage.IsRoot := True;
    for I := 0 to High(ARootManifest.Dependencies) do
      if AIncludeDev or not ARootManifest.Dependencies[I].IsDev then
        StrArrayAdd(LPackage.DependencyNames, ARootManifest.Dependencies[I].Name);
    FGraph.Add(LPackage);

    Result := FGraph;
    FGraph := nil;
  finally
    FGraph.Free;
  end;
end;

function ResolveGraph(ARootManifest: TManifest; AIncludeDev: Boolean): TDependencyGraph;
var
  LResolver: TResolver;
begin
  LResolver := TResolver.Create;
  try
    Result := LResolver.Resolve(ARootManifest, AIncludeDev);
  finally
    LResolver.Free;
  end;
end;

end.
