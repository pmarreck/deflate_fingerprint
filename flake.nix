{
  description = "deflate_fingerprint — identify which DEFLATE encoder produced a given compressed stream";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Pin Zig explicitly via mitchellh/zig-overlay, which exposes every
    # release as a named attr. Even though nixpkgs-unstable currently
    # tracks 0.16 too, pinning here insulates this project from upstream
    # nixpkgs jumping again unannounced.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pname = "deflate_fingerprint";
        version = "0.1.0";
        # Pinned to 0.16.0 ("Juicy Main", April 2026).
        zigPkg = zig-overlay.packages.${system}."0.16.0";
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export HOME=$TMPDIR
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
            zig build -Doptimize=ReleaseFast --prefix $out
          '';
          dontInstall = true;
        };

        # NOTE: don't key on ${system} here — flake-utils.eachDefaultSystem
        # already wraps the returned attrs in ${system}. Writing
        # `checks.${system} = ...` produces checks.<sys>.<sys>, which Garnix
        # silently skips. The same applies to packages/devShells (already
        # correctly bare above).
        checks = {
          build = self.packages.${system}.default;
          test = pkgs.stdenv.mkDerivation {
            pname = "${pname}-test";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ zigPkg ];
            # zlib is the test-time oracle for byte-exact fingerprinting against
            # real zlib output. It is NOT a runtime dep of the library or CLI.
            buildInputs = [ pkgs.zlib ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              timeout 600 zig build test || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          # zlib is test-time only (oracle for byte-exact comparison against
          # real zlib output); never a runtime dep of the library or CLI.
          packages = [ zigPkg pkgs.hyperfine pkgs.zlib ];
        };
      });
}
