{
  description = "Spawnkit: Shmuel's reproducible development machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Public project flake; Spawnkit consumes only its package output.
    google-automation = {
      url = "github:skamensky/google-automation";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: import ./nix/outputs.nix inputs;
}
