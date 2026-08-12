################################################################################
#
# atomcam2-aicap
#
# Prebuilt continuous microphone capture daemon. It dynamically links
# the vendor libimp at runtime and therefore has to be built with the
# Ingenic uClibc toolchain, which Buildroot does not provide;
# README.md documents how to rebuild it from atomcam2-aicap.c.
#
################################################################################

# Bump when the prebuilt binary changes: local-site packages are NOT
# rebuilt on file changes alone, so a stale binary ships silently
# otherwise.
ATOMCAM2_AICAP_VERSION = 1
ATOMCAM2_AICAP_SITE = $(NERVES_DEFCONFIG_DIR)/package/atomcam2-aicap
ATOMCAM2_AICAP_SITE_METHOD = local

define ATOMCAM2_AICAP_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/atomcam2-aicap \
		$(TARGET_DIR)/usr/bin/atomcam2-aicap
endef

$(eval $(generic-package))
