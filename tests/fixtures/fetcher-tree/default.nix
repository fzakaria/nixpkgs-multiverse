# A stand-in nixpkgs, small enough to import: just enough shape for
# importRevision to call it and for a test to recognise what came back.
# tests/mirrors.nix hands this to fetchRevision so a revision resolves through
# the fetcher without reaching GitHub.
{
  system,
  config ? { },
  overlays ? [ ],
}:
{
  servedByTheFetcher = true;
  inherit system;
}
