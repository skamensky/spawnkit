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
    # Claude Code and Codex release several times a day; this flake packages them
    # within hours and is bumped on its own. It keeps its own nixpkgs on purpose:
    # following ours would miss its binary cache and compile Codex on every update.
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = inputs: import ./nix/outputs.nix inputs;
}
