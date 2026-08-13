################################################################################
#
# atomcam2-camera
#
# Prebuilt native camera daemon. It dynamically links the vendor libimp
# at runtime and therefore has to be built with the Ingenic uClibc
# toolchain, which Buildroot does not provide; README.md documents how to
# rebuild it from camd.c.
#
################################################################################

# Bump when the prebuilt binary changes: local-site packages are NOT
# rebuilt on file changes alone, so a stale binary ships silently
# otherwise.
ATOMCAM2_CAMERA_VERSION = 37
ATOMCAM2_CAMERA_SITE = $(NERVES_DEFCONFIG_DIR)/package/atomcam2-camera
ATOMCAM2_CAMERA_SITE_METHOD = local

# gc2053-t31.bin: the vendor ISP calibration blob libimp looks for at
# /etc/sensor/gc2053-t31.bin (open() logged as "ISP: open ... failed" on
# every boot otherwise). It is model-wide, not per-unit -- verified
# byte-identical (sha256 68f12813...) between two independent devices,
# pulled from their /atom/system/etc/sensor/gc2053-t31.bin (vendor
# partition). Without it the ISP's AWB has no reference point and can
# converge to a strong magenta/purple cast, confirmed both by a live
# bind-mount test (installing it live fixed the color with no other
# change) and by a vendor-firmware boot on the same physical unit
# rendering correctly. See docs/20260806_RTSPとWebダッシュボード競合_技術相談.md
# for the investigation that led here (unrelated conflict, same session).
define ATOMCAM2_CAMERA_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/atomcam2-camd \
		$(TARGET_DIR)/usr/bin/atomcam2-camd
	$(INSTALL) -D -m 0644 $(@D)/gc2053-t31.bin \
		$(TARGET_DIR)/etc/sensor/gc2053-t31.bin
endef

$(eval $(generic-package))
