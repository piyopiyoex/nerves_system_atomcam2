/*
 * Continuously capture the Atom Cam 2 microphone via libimp IMP_AI and
 * write raw S16_BE (network byte order) mono PCM into a named pipe, for
 * v4l2rtspserver's FifoAudioCapture (package/v4l2rtspserver) to publish
 * as an RTP "audio/L16" subsession. See docs/20260812_RTSP_音声追加_提案書.md.
 *
 * This is airec.c's IMP_AI setup turned into an always-on daemon: instead
 * of recording a fixed duration to a file, it runs forever and pushes
 * every captured frame to the FIFO, byte-swapped to big-endian (RTP L16
 * is defined as 16-bit signed, network byte order; IMP_AI delivers
 * little-endian on this SoC, matching aoplay/airec's existing S16LE
 * convention).
 *
 * Usage: aicap [fifo] [rate] [gain]
 *   default: /tmp/camd-audio.fifo 8000 (gain: -1 = leave at default)
 *
 * Build: mips-linux-uclibc-gnu-gcc -O2 -march=mips32r2 -I<sdk111> \
 *   -Wl,--dynamic-linker=/atom/lib/ld-uClibc.so.0 \
 *   atomcam2-aicap.c -L lib -limp -lalog -lpthread -lm -lrt -o atomcam2-aicap
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <imp/imp_audio.h>

#define NUM_PER_FRM 400
#define FRM_NUM 40

static int step(const char *label, int rc)
{
	fprintf(stderr, "aicap: %-22s = %d\n", label, rc);
	fflush(stderr);
	return rc;
}

/* RTP L16 is 16-bit signed samples in network (big-endian) byte order;
 * IMP_AI delivers native (little-endian) samples on this SoC. */
static void swap16_to_be(uint8_t *buf, size_t len)
{
	size_t i;
	for (i = 0; i + 1 < len; i += 2) {
		uint8_t tmp = buf[i];
		buf[i] = buf[i + 1];
		buf[i + 1] = tmp;
	}
}

static int open_fifo_writer(const char *path)
{
	int fd;

	if (mkfifo(path, 0600) != 0 && errno != EEXIST) {
		fprintf(stderr, "aicap: mkfifo %s failed: %s\n", path, strerror(errno));
		return -1;
	}

	/* Blocks until a reader (v4l2rtspserver's FifoAudioCapture) opens
	 * the other end -- standard FIFO semantics, no polling needed. */
	fprintf(stderr, "aicap: waiting for a reader on %s\n", path);
	fflush(stderr);
	fd = open(path, O_WRONLY);
	if (fd < 0) {
		fprintf(stderr, "aicap: open %s for write failed: %s\n", path, strerror(errno));
		return -1;
	}

	fprintf(stderr, "aicap: reader connected on %s\n", path);
	fflush(stderr);
	return fd;
}

int main(int argc, char **argv)
{
	const char *path = (argc > 1) ? argv[1] : "/tmp/camd-audio.fifo";
	int rate = (argc > 2) ? atoi(argv[2]) : 8000;
	int gain = (argc > 3) ? atoi(argv[3]) : -1;   /* IMP_AI_SetGain, -1 = skip */
	/* The mic is AI device 1 (the speaker DAC is AO device 0). */
	int dev = 1, chn = 0;
	IMPAudioIOAttr attr;
	IMPAudioIChnParam chnParam;
	int fifo_fd;
	long total = 0;
	int frames = 0;

	/* A reader closing its end must not kill this process with SIGPIPE;
	 * write() reports EPIPE instead and we reopen (blocking again until
	 * the next reader, e.g. v4l2rtspserver restarting). */
	signal(SIGPIPE, SIG_IGN);

	fifo_fd = open_fifo_writer(path);
	if (fifo_fd < 0) return 1;

	memset(&attr, 0, sizeof(attr));
	attr.samplerate = rate;
	attr.bitwidth = AUDIO_BIT_WIDTH_16;
	attr.soundmode = AUDIO_SOUND_MODE_MONO;
	attr.frmNum = FRM_NUM;
	attr.numPerFrm = NUM_PER_FRM;
	attr.chnCnt = 1;

	if (step("IMP_AI_SetPubAttr", IMP_AI_SetPubAttr(dev, &attr)) != 0) return 1;
	if (step("IMP_AI_Enable", IMP_AI_Enable(dev)) != 0) return 1;

	memset(&chnParam, 0, sizeof(chnParam));
	chnParam.usrFrmDepth = 20;
	if (step("IMP_AI_SetChnParam", IMP_AI_SetChnParam(dev, chn, &chnParam)) != 0) return 1;
	if (step("IMP_AI_EnableChn", IMP_AI_EnableChn(dev, chn)) != 0) return 1;
	step("IMP_AI_SetVol(100)", IMP_AI_SetVol(dev, chn, 100));
	if (gain >= 0) {
		char label[32];
		snprintf(label, sizeof(label), "IMP_AI_SetGain(%d)", gain);
		step(label, IMP_AI_SetGain(dev, chn, gain));
	}

	fprintf(stderr, "aicap: streaming to %s (rate=%d)\n", path, rate);
	fflush(stderr);

	for (;;) {
		IMPAudioFrame frm;

		if (IMP_AI_PollingFrame(dev, chn, 1000) != 0) continue;

		memset(&frm, 0, sizeof(frm));
		if (IMP_AI_GetFrame(dev, chn, &frm, BLOCK) != 0) {
			fprintf(stderr, "aicap: IMP_AI_GetFrame failed, retrying\n");
			continue;
		}

		if (frm.len > 0 && frm.virAddr) {
			swap16_to_be((uint8_t *)frm.virAddr, frm.len);

			ssize_t written = write(fifo_fd, (void *)frm.virAddr, frm.len);
			if (written < 0 && errno == EPIPE) {
				fprintf(stderr, "aicap: reader gone, reopening %s\n", path);
				close(fifo_fd);
				fifo_fd = open_fifo_writer(path);
				if (fifo_fd < 0) {
					IMP_AI_ReleaseFrame(dev, chn, &frm);
					break;
				}
			} else if (written != (ssize_t)frm.len) {
				fprintf(stderr, "aicap: short write %zd/%u\n", written, frm.len);
			} else {
				total += frm.len;
				frames++;
			}
		}

		IMP_AI_ReleaseFrame(dev, chn, &frm);
	}

	fprintf(stderr, "aicap: exiting after %d frames, %ld bytes\n", frames, total);

	IMP_AI_DisableChn(dev, chn);
	IMP_AI_Disable(dev);
	close(fifo_fd);
	return 1;
}
