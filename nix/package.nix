{
  lib,
  stdenv,
  zig,
  fetchFromGitHub,
  nix-update-script,
}:

stdenv.mkDerivation {
  pname = "zyouz";
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "YutaUra";
    repo = "zyouz";
    rev = "v${version}";
    hash = "sha256-m8KTillhvWqIAACKL9k8iYVLyp9iXu5pl/AaCFvfuu8=";
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
