{
  description = "C23 development environment — GCC 15 / LLVM 22, GNU ld / mold / lld";

  # Pinned to the exact revision this host's system closure was built from: every
  # store path the shells need is then already local or already on
  # cache.nixos.org, and locking costs no network round trip.
  # To follow a channel instead: github:NixOS/nixpkgs/nixos-26.05
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/293d6abedf0478e681a4dfcfcb35b30fc796a32f";

  outputs =
    { self, nixpkgs, ... }:
    let
      # poop needs perf_event_open and mold cannot emit Mach-O, so the matrix is
      # Linux by construction rather than silently degraded on Darwin.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # flake-utils' eachSystem, in one line of nixpkgs' own lib. Hand-rolling it
      # with builtins.listToAttrs to avoid forcing nixpkgs.lib measured identical
      # (+1.1k values out of 3.3M): the package sets below force lib regardless.
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # One package set per system, memoised across every output: without this,
      # devShells and formatter each instantiate nixpkgs separately and
      # `nix flake check` costs 1.7x the CPU and heap.
      # `config` and `overlays` are pinned rather than using
      # nixpkgs.legacyPackages, which layers pkgs/top-level/impure-overlays.nix on
      # top and would read ~/.config/nixpkgs/overlays under `--impure`.
      pkgsFor = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          config = { };
          overlays = [ ];
        }
      );
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
          inherit (pkgs) lib;

          # Newest *released* LLVM in this pin. llvmPackages_23 is a pre-release
          # git snapshot: not in the binary cache, so it would build from source.
          llvm = pkgs.llvmPackages_22;

          # The compiler is chosen by replacing the stdenv, never by adding a
          # second compiler to `packages`: that would leave $CC/$CXX on the
          # default stdenv and put two `cc`s on PATH.
          compilers = {
            gcc = pkgs.gcc15Stdenv; # 15.2.0 — already defaults to -std=gnu23
            clang = llvm.stdenv; # 22.1.5 — libstdc++; llvm.libcxxStdenv for libc++
          };

          # Alternative linkers. Both drivers resolve `-fuse-ld=NAME` to `ld.NAME`
          # on PATH, and cc-wrapper restores the caller's PATH before exec'ing the
          # real compiler, so listing the package is all that is required. Neither
          # ships a bare `ld`, so the stdenv's own linker is never shadowed.
          # This is the mechanism stdenvAdapters.useMoldLinker uses
          # (env.NIX_CFLAGS_LINK), minus the cc/bintools wrapper fork — which lets
          # all three shells of a toolchain share one gcc-wrapper and one stdenv.
          linkers = {
            mold = pkgs.mold;
            lld = llvm.lld;
          };

          tools = [
            # build drivers
            pkgs.cmake
            pkgs.meson
            pkgs.ninja
            pkgs.pkg-config
            # compilation database + compiler cache
            pkgs.bear
            pkgs.ccache
            # correctness
            pkgs.gdb
            pkgs.valgrind
            # benchmarking and profiling
            pkgs.hyperfine
            pkgs.poop
            pkgs.samply # needs kernel.perf_event_paranoid <= 1; poop works at the default 2
            # Tracy 0.13.1: profiler UI, tracy-capture/-csvexport, *and* the client
            # (include/tracy, libTracyClient — both already on the compiler search
            # paths). Instrumentation stays opt-in: defining TRACY_ENABLE here would
            # instrument the benchmark builds too. By hand it is
            #   cc -DTRACY_ENABLE app.c -lTracyClient   with <tracy/tracy/TracyC.h>
            # and find_package(Tracy) / meson dependency('Tracy', method: 'cmake')
            # — capital T — resolve through the CMAKE_PREFIX_PATH below and define it
            # for you. TRACY_NO_EXIT=1 is a *runtime* variable: it makes a program
            # that finishes in microseconds wait for the profiler to attach.
            # Bumping past tracy 0.14 needs -DTRACY_ENABLE=ON — upstream flipped that
            # CMake default to OFF and nixpkgs does not pass it.
            pkgs.tracy
            # clangd / clang-format / clang-tidy, kept on the LLVM chosen above.
            # nixpkgs wraps clangd so it turns $NIX_CFLAGS_COMPILE into
            # $C_INCLUDE_PATH: start the editor from inside the shell (direnv) and
            # it resolves glibc headers with no --query-driver.
            llvm.clang-tools
          ];

          mkToolchainShell =
            ccName: stdenv: ldName:
            (pkgs.mkShell.override { inherit stdenv; }) {
              name = "c23-${ccName}${lib.optionalString (ldName != null) "-${ldName}"}";

              packages = tools ++ lib.optional (ldName != null) linkers.${ldName};

              # This is where you build -O0 -g for gdb/valgrind and -O2 for
              # hyperfine/poop. nixpkgs' default hardening injects
              # -D_FORTIFY_SOURCE=3 (which warns on every -O0 compile),
              # -fstack-protector-strong and -fzero-call-used-regs into both.
              # Off, so the compiler does exactly what the command line says and
              # measurements mean something; release builds re-enable hardening in
              # their own derivation.
              hardeningDisable = [ "all" ];

              env = {
                # Two spellings of one default, because they cover different holes.
                # CFLAGS is what make/cmake/meson/configure read, so it reaches
                # compile_commands.json — without it clangd parses C17 and reports
                # constexpr/nullptr/auto as errors.
                CFLAGS = "-std=gnu23";
                # ...and cc-wrapper reads this one, which catches build systems
                # that assign over CFLAGS. _BEFORE places it ahead of the caller's
                # own flags, so an explicit -std=c17 still wins.
                # gcc 15 already defaults to gnu23; clang 22 still defaults to gnu17.
                NIX_CFLAGS_COMPILE_BEFORE = "-std=gnu23";

                # clangd needs a compilation database. meson always writes one;
                # this makes cmake do the same; `bear -- make` covers handwritten
                # Makefiles (and records the wrapper-injected flags with it).
                CMAKE_EXPORT_COMPILE_COMMANDS = "1";

                # ccache is otherwise just a binary on PATH. cmake reads these two;
                # meson and make do not look for ccache at all, so they need an
                # explicit CC="ccache $CC" (or a meson native file).
                CMAKE_C_COMPILER_LAUNCHER = "ccache";
                CMAKE_CXX_COMPILER_LAUNCHER = "ccache";
              }
              // lib.optionalAttrs (ldName != null) {
                NIX_CFLAGS_LINK = "-fuse-ld=${ldName}";
              };

              shellHook = ''
                # nixpkgs' cmake hook fills NIXPKGS_CMAKE_PREFIX_PATH but only reads
                # it inside cmakeConfigurePhase. Exporting it is what lets a
                # hand-run `cmake` find the shell's own libraries — find_package(Tracy).
                export CMAKE_PREFIX_PATH="''${NIXPKGS_CMAKE_PREFIX_PATH-}''${CMAKE_PREFIX_PATH:+:''${CMAKE_PREFIX_PATH}}"

                # stderr, so `nix develop -c cmd | ...` keeps a clean stdout.
                echo 'c23 · ${ccName} ${stdenv.cc.cc.version} · ld.${
                  if ldName == null then "bfd" else "${ldName} ${lib.getVersion linkers.${ldName}}"
                } · -std=gnu23 · nixpkgs hardening off' >&2
              '';
            };

          # {gcc,clang} x {stdenv default, mold, lld}. Nix is lazy, so the shells
          # you never enter cost nothing: all six evaluate to ~2.8k values on top
          # of the package set they share.
          shells = lib.concatMapAttrs (
            ccName: stdenv:
            {
              ${ccName} = mkToolchainShell ccName stdenv null;
            }
            // lib.mapAttrs' (
              ldName: _: lib.nameValuePair "${ccName}-${ldName}" (mkToolchainShell ccName stdenv ldName)
            ) linkers
          ) compilers;
        in
        shells // { default = shells.gcc; }
      );

      # Everything the release workflow verifies is a flake check, so `nix flake
      # check` locally and on GitHub run the same derivations with the same
      # pinned tools. Building `dev-shells` realises every shell from the lock
      # file alone (the ~700 MiB toolchain closure comes from cache.nixos.org).
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
          inherit (pkgs) lib;
        in
        {
          dev-shells = pkgs.linkFarm "dev-shells" (
            lib.mapAttrsToList (name: path: { inherit name path; }) self.devShells.${system}
          );

          # Formatters rewrite files in place, so they get a writable copy.
          format = pkgs.runCommand "check-format" { nativeBuildInputs = [ self.formatter.${system} ]; } ''
            cp -r ${self} src && chmod -R u+w src && cd src
            treefmt --ci --walk filesystem --tree-root .
            touch "$out"
          '';

          lint =
            pkgs.runCommand "check-lint"
              {
                nativeBuildInputs = [
                  pkgs.actionlint
                  pkgs.shellcheck
                  pkgs.zizmor
                ];
              }
              ''
                cd ${self}
                actionlint .github/workflows/*.yml
                zizmor --no-online-audits --persona pedantic --min-severity low .github/workflows .github/actions/*/action.yml
                shellcheck --shell=bash --external-sources scripts/*.sh tests/*.sh
                touch "$out"
              '';
        }
      );

      # `nix run .#release` / `nix run .#verify-release` run scripts/*.sh with
      # their dependencies pinned to this flake's nixpkgs, so a maintainer, the
      # release workflow and a recipient use identical git/jq/gh/cosign builds.
      # `nix` itself is deliberately not wrapped: the caller's nix must match the
      # caller's daemon.
      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
          inherit (pkgs) lib;
          mkApp = name: description: runtimeInputs: {
            type = "app";
            program = lib.getExe (
              pkgs.writeShellApplication {
                inherit name runtimeInputs;
                text = ''exec ${self}/scripts/${name}.sh "$@"'';
              }
            );
            meta = { inherit description; };
          };
          common = [
            pkgs.coreutils
            pkgs.curl
            pkgs.git
            pkgs.gnupg
            pkgs.jq
            pkgs.openssh
          ];
        in
        {
          release = mkApp "release" "Verify, package and publish a release of this flake" (
            common ++ [ pkgs.gh ]
          );
          verify-release = mkApp "verify-release" "Verify a published release of this flake as a recipient" (
            common
            ++ [
              pkgs.cosign
              pkgs.gh
            ]
          );
        }
      );

      formatter = forAllSystems (system: pkgsFor.${system}.nixfmt-tree);
    };
}
