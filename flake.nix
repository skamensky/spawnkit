{
  description = "Shmuel's shared Home Manager and optional NixOS infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      ...
    }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forSystems = lib.genAttrs systems;
      registry = builtins.fromJSON (builtins.readFile ./hosts/registry.json);
      profiles = builtins.attrNames registry;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      modulesFor =
        profile:
        [
          ./users/shmuel.nix
          ./hosts/default.nix
        ]
        ++ lib.optional (profile != "default") (./hosts + "/${profile}/default.nix");
      mkHome =
        system: profile: isNixOS:
        home-manager.lib.homeManagerConfiguration {
          pkgs = pkgsFor system;
          extraSpecialArgs = {
            inherit inputs isNixOS;
            hostProfile = profile;
          };
          modules = modulesFor profile;
        };
      homeName =
        system: profile: isNixOS:
        "shmuel@${profile}-${system}${lib.optionalString isNixOS "-nixos"}";
      selectProfile =
        hostname: environment:
        lib.findFirst (
          profile:
          builtins.elem (lib.toLower hostname) registry.${profile}.hostnames
          && builtins.elem environment registry.${profile}.environments
        ) "default" profiles;
    in
    {
      lib = {
        inherit
          systems
          profiles
          registry
          selectProfile
          mkHome
          modulesFor
          ;
      };

      homeConfigurations = lib.listToAttrs (
        lib.concatMap (
          system:
          lib.concatMap (
            profile:
            map
              (isNixOS: {
                name = homeName system profile isNixOS;
                value = mkHome system profile isNixOS;
              })
              [
                false
                true
              ]
          ) profiles
        ) systems
      );

      homeManagerModules.default = import ./modules/home;
      nixosModules = {
        default = { config, pkgs, ... }: {
          imports = [ home-manager.nixosModules.home-manager ];
          nixpkgs.config.allowUnfree = lib.mkDefault true;
          # mise downloads ordinary Linux binaries outside the Nix store.
          programs.nix-ld = {
            enable = true;
            libraries = with pkgs; [
              stdenv.cc.cc.lib
              zlib
              openssl
              libffi
              sqlite
              bzip2
              xz
              readline
              ncurses
              libxcrypt
            ];
          };
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = {
              inherit inputs;
              isNixOS = true;
              hostProfile = selectProfile config.networking.hostName "nixos";
            };
            users.shmuel.imports = modulesFor (selectProfile config.networking.hostName "nixos");
          };
        };
        ssh = import ./modules/nixos/ssh.nix;
        docker = import ./modules/nixos/docker.nix;
      };

      packages = forSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          home-config = pkgs.writeShellApplication {
            name = "home-config";
            runtimeInputs = [
              pkgs.python3
              pkgs.nix
              pkgs.git
            ];
            text = ''
              exec python3 ${./scripts/home-config.py} "$@"
            '';
          };
          default = self.packages.${system}.home-config;
        }
      );

      apps = forSystems (system: {
        home-config = {
          type = "app";
          program = "${self.packages.${system}.home-config}/bin/home-config";
          meta.description = "Build, check or activate the detected Home Manager profile";
        };
        default = self.apps.${system}.home-config;
      });

      formatter = forSystems (system: (pkgsFor system).nixfmt);

      checks = forSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        (lib.genAttrs profiles (
          profile: self.homeConfigurations.${homeName system profile false}.activationPackage
        ))
        // {
          bootstrap-tests =
            pkgs.runCommand "nix-config-bootstrap-tests"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  pkgs.git
                ];
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                cp -r ${./scripts} scripts
                cp -r ${./tests} tests
                chmod -R u+w scripts tests
                python3 -m unittest discover -s tests -v
                touch "$out"
              '';
          nixos-module =
            let
              evaluated = lib.nixosSystem {
                inherit system;
                modules = [
                  self.nixosModules.default
                  self.nixosModules.ssh
                  self.nixosModules.docker
                  {
                    boot.isContainer = true;
                    networking.hostName = "unrecognized-test-host";
                    system.stateVersion = "26.05";
                    nixpkgs.config.allowUnfree = true;
                    users.users.shmuel = {
                      isNormalUser = true;
                      home = "/home/shmuel";
                    };
                  }
                ];
              };
            in
            assert evaluated.config.home-manager.users.shmuel.personal.profile == "default";
            assert evaluated.config.services.openssh.enable;
            assert evaluated.config.virtualisation.docker.enable;
            assert evaluated.config.programs.nix-ld.enable;
            assert evaluated.config.home-manager.users.shmuel.home.activationPackage.drvPath != "";
            pkgs.runCommand "nixos-module-evaluation" { } "touch $out";
        }
      );
    };
}
