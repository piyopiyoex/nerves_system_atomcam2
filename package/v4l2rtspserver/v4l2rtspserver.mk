################################################################################
#
# v4l2rtspserver
#
# RTSP server that publishes the already-encoded frames the vendor camera
# runtime writes into the v4l2loopback devices. Upstream's ALSA audio
# path is not built (0002-video-only-makefile.patch): the control
# kernel provides OSS rather than ALSA. Audio is instead published via
# an ALSA-free FIFO source (0004-fifo-audio-source.patch) fed by the
# atomcam2-aicap daemon (package/atomcam2-aicap/), which does the
# actual IMP_AI microphone capture. See
# docs/20260812_RTSP_音声追加_提案書.md.
#
# 0005-sprop-startup-race-fix.patch: waits (bounded) for the capture
# source to have SPS/PPS before building the SDP's sprop-parameter-sets
# line, since the very first DESCRIBE can otherwise race the encoder's
# first frame and leave it permanently empty for that process's
# lifetime. See docs/20260813_video信頼性_sprop捕捉機構特定_技術相談.md.
#
################################################################################

V4L2RTSPSERVER_VERSION = ce808915edfd9ec934af351efe739dd9a07a07e5
V4L2RTSPSERVER_SITE = https://github.com/mpromonet/v4l2rtspserver.git
V4L2RTSPSERVER_SITE_METHOD = git
V4L2RTSPSERVER_LICENSE = Unlicense
V4L2RTSPSERVER_LICENSE_FILES = LICENSE
V4L2RTSPSERVER_DEPENDENCIES = live555 v4l2cpp
V4L2RTSPSERVER_CFLAGS = $(TARGET_CFLAGS) -DVERSION=1

define V4L2RTSPSERVER_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) CC="$(TARGET_CC)" CXX="$(TARGET_CXX)" \
		EXTRA_CXXFLAGS="$(V4L2RTSPSERVER_CFLAGS)" \
		PREFIX="$(STAGING_DIR)/usr" -C $(@D) all
endef

define V4L2RTSPSERVER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/v4l2rtspserver \
		$(TARGET_DIR)/usr/bin/v4l2rtspserver
endef

$(eval $(generic-package))
