# The nix-darwin entry point. Everything that decides *what* to install lives
# in multiverse.nix; this file only says where it goes.
{ config, lib, ... }:

{
  imports = [ ./multiverse.nix ];

  config = lib.mkIf config.multiverse.enable {
    environment.systemPackages = config.multiverse.packages;
  };
}
