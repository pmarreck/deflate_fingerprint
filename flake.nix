{
  description = "deflate_fingerprint — identify which DEFLATE encoder produced a given compressed stream";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pname = "deflate_fingerprint";
        version = "0.1.0";
        # Pinned to the 0.16 series by attribute name; flake.lock pins the
        # exact build. Use nixpkgs' source-built Zig rather than a prebuilt
        # binary: nixpkgs compiles its coreutils `env` path into the
        # compiler's native-ABI probe. A prebuilt compiler probes
        # /usr/bin/env, which the Linux build sandbox lacks, then silently
        # targets musl and emits test binaries whose /lib/ld-musl interpreter
        # does not exist (zig build test: FileNotFound).
        zigPkg = pkgs.zig_0_16;
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
        # `checks.${system} = ...` produces checks.<sys>.<sys>, which CI
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
          # ruby generates deterministic Info-ZIP fixture inputs in
          # tests/integration/infozip_roundtrip.sh.
          packages = [ zigPkg pkgs.hyperfine pkgs.zlib pkgs.zip pkgs.ruby ];
        };
      });
}
