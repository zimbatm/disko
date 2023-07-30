{ nixosConfig
, diskoLib
, pkgs ? nixosConfig.pkgs
, lib ? pkgs.lib
, name ? "${nixosConfig.config.networking.hostName}-disko-images"
, extraPostVM ? ""
}:
let
  cleanedConfig = diskoLib.testLib.prepareDiskoConfig nixosConfig.config diskoLib.testLib.devices;
  systemToInstall = nixosConfig.extendModules {
    modules = [{
      disko.devices = lib.mkForce cleanedConfig.disko.devices;
      boot.loader.grub.devices = lib.mkForce cleanedConfig.boot.loader.grub.devices;
    }];
  };
  dependencies = with pkgs; [
    bash
    coreutils
    gnused
    systemdMinimal
    nixos-install-tools
    nix
    utillinux
  ];
  preVM = ''
    ${lib.concatMapStringsSep "\n" (disk: "truncate -s ${disk.imageSize} ${disk.name}.raw") (lib.attrValues nixosConfig.config.disko.devices.disk)}
  '';
  postVM = ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (disk: "cp ${disk.name}.raw $out/${disk.name}.raw") (lib.attrValues nixosConfig.config.disko.devices.disk)}
    ${extraPostVM}
  '';
  builder = ''
    # running udev, stolen from stage-1.sh
    echo "running udev..."
    ln -sfn /proc/self/fd /dev/fd
    ln -sfn /proc/self/fd/0 /dev/stdin
    ln -sfn /proc/self/fd/1 /dev/stdout
    ln -sfn /proc/self/fd/2 /dev/stderr
    mkdir -p /etc/udev
    ln -sfn ${systemToInstall.config.system.build.etc}/etc/udev/rules.d /etc/udev/rules.d
    mkdir -p /dev/.mdadm
    ${pkgs.systemdMinimal}/lib/systemd/systemd-udevd --daemon
    udevadm trigger --action=add
    udevadm settle

    # populate nix db, so nixos-install doesn't complain
    export NIX_STATE_DIR=$TMPDIR/state
    nix-store --load-db < ${pkgs.closureInfo {
      rootPaths = [ systemToInstall.config.system.build.toplevel ];
    }}/registration

    ${systemToInstall.config.system.build.diskoScript}
    ${pkgs.nixos-install-tools}/bin/nixos-install --system ${systemToInstall.config.system.build.toplevel} --keep-going --no-channel-copy -v --no-root-password --option binary-caches ""
  '';
  QEMU_OPTS = lib.concatMapStringsSep " " (disk: "-drive file=${disk.name}.raw,if=virtio,cache=unsafe,werror=report") (lib.attrValues nixosConfig.config.disko.devices.disk);
in {
  pure = pkgs.vmTools.runInLinuxVM (pkgs.runCommand name {
    buildInputs =dependencies;
    inherit preVM QEMU_OPTS;
    memSize = 1024;
  } builder);
  impure = pkgs.writeScript name ''
    set -efu
    export PATH=${lib.makeBinPath dependencies}
    showUsage() {
    cat <<USAGE
    Usage: ./\$script [options]

    Options:
    * --preDiskoFiles <src> <dst>
      copies the src to the dst on the VM, before disko is run
      This is useful to provide secrets like LUKS keys, or other files you need for formating
    * --postDiskoFiles <src> <dst>
      copies the src to the dst on the finished image.
      These end up in the images later and is useful if you want to add some extra stateful files
    USAGE
    }

    export out=$PWD
    TMPDIR=$(mktemp -d); export TMPDIR
    trap 'rm -rf "$TMPDIR"' EXIT
    mkdir -p "$TMPDIR"
    pushd "$TMPDIR"

    touch copy_to_xchg
    mkdir -p copy_before_disko
    mkdir -p copy_after_disko

    while [[ $# -gt 0 ]]; do
      case "$1" in
      --preDiskoFiles)
        src=$2
        dst=$3
        cp -r "$src" copy_before_disko/"$(echo "$dst" | base64)"
        shift 2
        ;;
      --postDiskoFiles)
        src=$2
        dst=$3
        cp -r "$src" copy_after_disko/"$(echo "$dst" | base64)"
        shift 2
        ;;
      *)
        showUsage
        exit 1
        ;;
      esac
      shift
    done

    export preVM=${pkgs.writeScript "preVM.sh" ''
      set -efu
      mv copy_before_disko xchg/
      mv copy_after_disko xchg/
      ${preVM}
    ''}
    export postVM=${pkgs.writeScript "postVM.sh" postVM}
    export origBuilder=${pkgs.writeScript "disko-builder" ''
      set -efu
      export PATH=${lib.makeBinPath dependencies}
      set +f
      for src in /tmp/xchg/copy_before_disko/*; do
        cp -r "$src" "$(basename "$src" | base64 -d)"
      done
      set -f
      ${builder}
      set +f
      for dir in /tmp/xchg/copy_after_disko/*; do
        cp -r "$src" /mnt/"$(basename "$src" | base64 -d)"
      done
      set -f
    ''}
    export QEMU_OPTS=${lib.escapeShellArg "${QEMU_OPTS} -m 1024"}
    ${pkgs.bash}/bin/sh -e ${pkgs.vmTools.vmRunCommand pkgs.vmTools.qemuCommandLinux}
    popd
  '';
}
