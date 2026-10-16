{ ... }: {
  imports = [ ../../nix/modules/home/laptop.nix ];
  personal.environment = "wsl";
  home.sessionVariables = {
    AWS_PROFILE = "slate";
    AIRTABLE_WORKSPACE_ID = "wspK4I5ReGIK1iQtD";
  };
  programs.bash.shellAliases.powershell = "powershell.exe";
}
