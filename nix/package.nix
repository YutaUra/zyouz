{
  lib,
  stdenv,
  zig,
  fetchFromGitHub,
  nix-update-script,
}:

stdenv.mkDerivation {
  pname = "zyouz";
  version = "0.3.0";

  src = fetchFromGitHub {
    owner = "YutaUra";
    repo = "zyouz";
    rev = "v${version}";
    hash = "sha256-VURZD3416vxtPDohvv6PPsLaReckil0TrSOJiCoUvtI=";
  };

  nativeBuildInputs = [ zig.hook ];

  # zig test requires a TTY, which is unavailable in the Nix sandbox
  dontUseZigCheck = true;

  passthru.updateScript = nix-update-script { };

  meta = with lib; {
    description = "A terminal multiplexer driven by a static config file";
    homepage = "https://github.com/YutaUra/zyouz";
    license = licenses.mit;
    maintainers = with maintainers; [ yutaura ];
    mainProgram = "zyouz";
    platforms = platforms.unix;
  };
}
