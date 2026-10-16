{
  config,
  pkgs,
  lib,
  ...
}:
{
  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
  };
  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/bin"
    "$HOME/.cargo/bin"
  ];
  programs.bash = {
    enable = true;
    enableCompletion = true;
    historyControl = [ "ignoreboth" ];
    historySize = 10000;
    historyFileSize = 20000;
    shellOptions = [
      "histappend"
      "checkwinsize"
    ];
    shellAliases = {
      ll = "ls -alF";
      la = "ls -A";
      l = "ls -CF";
      claude_dangerous = "claude --dangerously-skip-permissions";
      codex_dangerous = "codex --dangerously-bypass-approvals-and-sandbox";
      corteza_ssh_forward = "ssh -4 -fN -o ExitOnForwardFailure=yes -L 127.0.0.1:65432:localhost:54321 corteza";
      tmain = "$HOME/repos/SkylineCapital/supa-crm/start-tmux-session.sh";
    };
    initExtra = ''
      source ${../../config/completions/supabase.bash}
      source ${../../config/completions/shmutils.sh.bash}
      source ${../../config/completions/tmux.sh.bash}
    '';
  };
  programs.fzf = {
    enable = true;
    enableBashIntegration = true;
  };
  programs.tmux = {
    enable = true;
    mouse = true;
    keyMode = "vi";
    extraConfig = ''
      unbind -T copy-mode-vi MouseDragEnd1Pane
      unbind -T copy-mode MouseDragEnd1Pane
      bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "${
        if config.personal.environment == "wsl" then "clip.exe" else "${pkgs.wl-clipboard}/bin/wl-copy"
      }"
      bind-key j display-popup -E "tmux list-windows -F '#{window_index}: #{window_name}' | fzf --reverse | cut -d: -f1 | xargs -I {} tmux select-window -t {}"
    '';
  };
}
