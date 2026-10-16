{ ... }: {
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Shmuel Kamensky";
        email = "shmuelkamensky@gmail.com";
      };
      init.defaultBranch = "main";
      pull.ff = "only";
    };
  };
  programs.gh = {
    enable = true;
    settings.git_protocol = "ssh";
  };
}
