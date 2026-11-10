# vkms, built out of tree as `vkmsdesk` with one addition: a module parameter
# `connector_types` giving each connector's DRM type in creation order
# (10 = DisplayPort, 11 = HDMI-A). Upstream makes every connector Virtual-N;
# with DP, DP, HDMI-A the kernel names them DP-1, DP-2, HDMI-A-1, as on a
# typical desktop. It also takes its modes from drm.edid_firmware when one is
# given, which upstream vkms never does. Renamed so it never collides with the
# in-tree vkms.ko.
{
  stdenv,
  kernel,
  python3,
  kernelModuleMakeFlags,
}:
stdenv.mkDerivation {
  pname = "vkmsdesk";
  inherit (kernel) version;
  src = kernel.src;
  nativeBuildInputs = kernel.moduleBuildDependencies ++ [python3];
  unpackPhase = ''
    tar xf $src --strip-components=5 --wildcards '*/drivers/gpu/drm/vkms/*'
  '';
  postPatch = ''
    python3 - <<'EOF'
    p = "vkms_connector.c"
    s = open(p).read()
    anchor = "struct vkms_connector *vkms_connector_init(struct vkms_device *vkmsdev)\n{\n"
    assert s.count(anchor) == 1
    s = s.replace(anchor, """static int connector_types[16];
    static int num_connector_types;
    module_param_array(connector_types, int, &num_connector_types, 0444);
    MODULE_PARM_DESC(connector_types, "DRM connector type per connector, in creation order");

    """ + anchor + """\tint idx = vkmsdev->drm.mode_config.num_connector;
    \tint type = idx < num_connector_types ? connector_types[idx] : DRM_MODE_CONNECTOR_VIRTUAL;
    """)
    old = "DRM_MODE_CONNECTOR_VIRTUAL, NULL);"
    assert s.count(old) == 1
    s = s.replace(old, "type, NULL);")
    # Take modes from an EDID override (drm.edid_firmware) when there is one.
    # The probe helper only falls back to it when .get_modes finds nothing,
    # and vkms always finds its built-in list.
    old = "\t/* Use the default modes list from DRM */\n"
    assert s.count(old) == 1
    s = s.replace(old, "\tcount = drm_edid_override_connector_update(connector);\n\tif (count > 0)\n\t\treturn count;\n\n" + old)
    open(p, "w").write(s)
    EOF
    rm -rf tests
    cat > Kbuild <<'EOF'
    obj-m := vkmsdesk.o
    vkmsdesk-y := vkms_drv.o vkms_plane.o vkms_output.o vkms_formats.o vkms_crtc.o \
      vkms_composer.o vkms_writeback.o vkms_connector.o vkms_config.o \
      vkms_configfs.o vkms_colorop.o vkms_luts.o
    EOF
  '';
  makeFlags =
    kernelModuleMakeFlags
    ++ [
      "-C"
      "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
      "M=$(PWD)"
    ];
  buildFlags = ["modules"];
  installPhase = ''
    install -Dm444 vkmsdesk.ko $out/lib/modules/${kernel.modDirVersion}/extra/vkmsdesk.ko
  '';
}
