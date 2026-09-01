# Tests `readLock`, the Nix half of `mvs lock`, by evaluating this file strictly:
#
#   nix eval --json -f tests/lock.nix --apply 'f: f { }'
#
# The lock files are built here rather than committed as fixtures, and their
# commits come out of the index itself, so nothing in this test has to be
# rewritten when the index grows.
{
  system ? builtins.currentSystem,
}:
let
  mv = import ../multiverse.nix { inherit system; };

  # A version old enough to be settled: whichever revision last shipped ripgrep
  # 13.0.0 is fixed forever, unlike anything resolved off a channel tip. The
  # same pin tests/module.nix uses, so the revision behind it is materialised
  # once for both.
  pinnedVersion = "13.0.0";

  # A revision label is `YYYY-MM-DD-<12 hex>`, and `at` takes a commit prefix,
  # so the label's second half is exactly the `rev` a pin carries.
  label = mv.revOf "ripgrep" pinnedVersion;
  rev = builtins.substring 11 12 label;

  # A lock file as `mvs lock` writes one.
  lockFile =
    pins:
    builtins.toFile "multiverse.lock" (
      builtins.toJSON {
        version = 1;
        inherit pins;
      }
    );

  pin = {
    inherit rev label;
    version = pinnedVersion;
    date = builtins.substring 0 10 label;
  };

  good = mv.readLock (lockFile {
    ripgrep = pin;
  });

  # Forcing one attribute of a lock is what resolves that pin, so tryEval sees
  # the throw for a bad one.
  attempt = lock: attr: (builtins.tryEval (lock.${attr}.outPath or lock.${attr})).success;

  # A pin naming something no revision has. Resolving it must say so rather than
  # failing with Nix's own "attribute missing".
  missing = mv.readLock (lockFile {
    definitely-not-a-package = pin;
  });

  # A pin naming a nested attribute. nix/nested-sets.nix puts `jetbrains` in the
  # index, so an attribute name can be a path, and resolving one has to walk it
  # rather than ask nixpkgs for an attribute whose name contains a dot.
  # `jetbrains.jdk` is free and lives in the revision the pins above already
  # materialise, so testing it costs no second fetch.
  nested = mv.readLock (lockFile {
    "jetbrains.jdk" = pin;
  });

  # A path whose set exists and whose child does not. This is the case that
  # would silently read as "missing attribute" if the walk stopped checking
  # after the first step.
  nestedMissing = mv.readLock (lockFile {
    "jetbrains.definitely-not-an-ide" = pin;
  });

  # A lock from a future format version. Rejected whole, before any pin is
  # looked at, since a reader that guesses at an unknown format is worse than
  # one that stops.
  future = builtins.tryEval (
    mv.readLock (
      builtins.toFile "multiverse.lock" (
        builtins.toJSON {
          version = 99;
          pins = { };
        }
      )
    )
  );
in

# A lock resolves to exactly its pins, keyed by attribute.
assert builtins.attrNames good == [ "ripgrep" ];

# And each one to the derivation that pin names — the version is read back off
# the package rather than off the lock file, so this checks that the commit in
# the pin is what decided the answer.
assert good.ripgrep.version == pinnedVersion;

# `rev` is the whole of a pin's meaning: the same commit under a lock whose
# other fields are wrong still resolves to the same derivation.
assert
  (mv.readLock (lockFile {
    ripgrep = pin // {
      version = "0.0.0";
      date = "1970-01-01";
    };
  })).ripgrep.outPath == good.ripgrep.outPath;

# An attribute the revision does not have is an error, not a null.
assert !(attempt missing "definitely-not-a-package");

# A dotted name resolves to the package at that path, not to a missing
# attribute — and reports the version the tree carries, so the walk really did
# reach a derivation.
assert nested."jetbrains.jdk" ? version;
assert builtins.match "jetbrains-jdk-.*" nested."jetbrains.jdk".name != null;

# A missing child of a set that does exist is an error too.
assert !(attempt nestedMissing "jetbrains.definitely-not-an-ide");

# An unreadable format version is refused.
assert !future.success;

# An empty lock is a lock, not a failure: `mvs lock rm` leaves one behind.
assert mv.readLock (lockFile { }) == { };

{
  inherit label rev;
  pins = builtins.attrNames good;
  version = good.ripgrep.version;
  nestedVersion = nested."jetbrains.jdk".version;
}
