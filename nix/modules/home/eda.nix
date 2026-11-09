# Electronics and chip design: schematics/PCBs that go to a fab, circuit simulation, HDL
# simulation and formal checks, and an open-PDK ASIC flow. Every tool here has a CLI so an agent
# can run the design, check and simulate loop without the GUIs. Per-design Python libraries
# (cocotb, skidl, gdsfactory, PySpice) and PDKs belong in each design's own uv project and
# ciel-managed PDK directory, not here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  plasmaQt = pkgs.callPackage ./plasma-qt.nix { };
in
{
  options.personal.eda.enable = lib.mkEnableOption "the electronics and chip design toolchain";
  # Some tools (Xyce, Renode) are x86_64 only; aarch64 profiles get the rest.
  config.home.packages = lib.mkIf config.personal.eda.enable (
    lib.filter (lib.meta.availableOn pkgs.stdenv.hostPlatform) (
      with pkgs;
      [
        # PCB: KiCad with its symbol, footprint and 3D model libraries. kicad-cli runs ERC, DRC
        # and exports Gerbers, drill files, BOM, pick-and-place and STEP for ordering.
        kicad
        kikit # panelization and fab-house presets (JLCPCB, PCBWay)
        interactive-html-bom
        gerbv # independent Gerber viewer to check what the fab will receive

        # Circuit simulation. ngspice is also KiCad's built-in simulator; Xyce handles large
        # circuits and vendor models ngspice rejects.
        ngspice
        xyce
        (plasmaQt qucs-s)
        openems # field solver for antennas, high-speed traces and impedance

        # Microcontroller firmware against simulated boards.
        simulide
        renode

        # Mechanical fit: enclosures around KiCad's STEP export. Its Python environment also loads
        # GTK, which reads the desktop's settings only through dconf's GIO module.
        (symlinkJoin {
          name = "freecad-${freecad.version}";
          paths = [ (plasmaQt freecad) ];
          nativeBuildInputs = [ makeWrapper ];
          postBuild = ''
            for f in $out/bin/*; do
              [ -x "$f" ] && [ ! -d "$f" ] && wrapProgram "$f" --prefix GIO_EXTRA_MODULES : ${dconf.lib}/lib/gio/modules
            done
          '';
        })

        # HDL simulation, lint, synthesis and formal verification.
        iverilog
        verilator
        ghdl
        sv-lang
        verible
        yosys
        sby
        z3
        bitwuzla
        yices
        boolector
        gtkwave
        surfer

        # FPGA place-and-route and programming.
        nextpnr
        icestorm
        trellis
        openfpgaloader

        # ASIC: schematic, layout, LVS/DRC, place-and-route and the full RTL-to-GDS flow on
        # open PDKs (SKY130, GF180MCU, IHP SG13G2) fetched with ciel.
        xschem
        magic-vlsi
        netgen-vlsi
        (plasmaQt klayout)
        openroad
        librelane
        ciel
      ]
    )
  );
}
