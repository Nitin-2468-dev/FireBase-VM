#div.nix
{ pkgs, ... }: {
  # Which nixpkgs channel to use
  channel = "stable-24.05"; # or "unstable"

  services.docker.enable = true;
  # Packages to be installed in the development environment
  packages = with pkgs; [
    pkgs.expect
    pkgs.vimPlugins.ncm2-bufword
    pkgs.apt
    pkgs.neofetch
    unzip
    openssh
    git
    qemu_kvm
    sudo
    cdrkit
    cloud-utils
    qemu
    python3
  ];

  # Environment variables for the workspace
  env = {
    # Example: set default editor
    EDITOR = "nano";
  };

  idx = {
    # Extensions from https://open-vsx.org (use "publisher.id")
    extensions = [
      "Dart-Code.flutter"
      "Dart-Code.dart-code"
    ];

    workspace = {
      # Runs when a workspace is first created
      onCreate = {
        
       };

      # Runs each time the workspace is (re)started
      onStart = { 
           Vm = "/home/user/vps123/VM.sh --autostart " ;
           #playit = "/home/user/vps123/playit" ;
           #auto = "python3 <(curl -s https://raw.githubusercontent.com/JishnuTheGamer/24-7/refs/heads/main/24)" ;
      };
    };

    # Disable previews completely
    previews = {
      enable = false;
    };
  };
}
            
# 34
 
