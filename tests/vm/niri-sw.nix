# niri with its refusal of software EGL renderers (llvmpipe) removed, so it
# can drive vkms in a VM without a GPU. Only for this test.
{niri}:
niri.overrideAttrs (old: {
  postPatch =
    (old.postPatch or "")
    + ''
      substituteInPlace src/backend/tty.rs \
        --replace-fail '!egl_device.is_software(),' 'true || !egl_device.is_software(),'
    '';
  doCheck = false;
})
