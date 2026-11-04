{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
{
  imports = [ inputs.plasma-manager.homeModules.plasma-manager ];
  # Plasma itself comes from Ubuntu (plasma in hosts/<profile>/system.yml); this declares
  # its settings and the theme candidates. Plasma's default layout is already one bottom
  # panel and no top panel.
  options.personal.desktop.plasma = lib.mkEnableOption "KDE Plasma 6 settings and themes";
  config = lib.mkIf (config.personal.desktop.enable && config.personal.desktop.plasma) {
    programs.plasma = {
      enable = true;
      # Print selects a region; nothing is taken until Enter, which copies it to the
      # clipboard and closes Spectacle without saving a file.
      spectacle.shortcuts = {
        captureRectangularRegion = "Print";
        launch = [ ];
      };
      configFile.spectaclerc = {
        General = {
          clipboardGroup = "PostScreenshotCopyImage";
          autoSaveImage = false;
          useReleaseToCapture = false;
        };
        GuiConfig.quitAfterSaveCopyExport = true;
      };
    };
    # Theme trial (migration D7): pick one in System Settings → Colors & Themes, then pin it
    # here. Their Kvantum themes use Ubuntu's qt6-style-kvantum, which matches Plasma's Qt.
    home.packages = with pkgs; [
      whitesur-kde
      catppuccin-kde
      nordic
      sweet-nova
      utterly-nord-plasma
      papirus-icon-theme
      tela-icon-theme
      bibata-cursors
    ];
  };
}
