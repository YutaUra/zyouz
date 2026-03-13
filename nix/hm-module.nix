{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.zyouz;
in
{
  options.programs.zyouz = {
    enable = lib.mkEnableOption "zyouz terminal multiplexer";

    package = lib.mkPackageOption pkgs "zyouz" { };

    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        .{
            .layouts = .{
                .{
                    .name = "default",
                    .root = .{ .command = .{"/bin/bash"} },
                },
            },
        }
      '';
      description = "ZON configuration for zyouz. Written to {file}`~/.config/zyouz/config.zon`.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    xdg.configFile."zyouz/config.zon" = lib.mkIf (cfg.config != "") {
      text = cfg.config;
    };
  };
}
