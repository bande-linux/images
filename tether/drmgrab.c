#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <drm/drm_fourcc.h>
#include <linux/dma-buf.h>

static int grab(const char *path)
{
	int fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return 1;
	struct drm_mode_card_res res = {0};
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) || !res.count_crtcs)
		return 1;
	uint32_t crtcs[64];
	res.count_fbs = res.count_connectors = res.count_encoders = 0;
	res.count_crtcs = res.count_crtcs > 64 ? 64 : res.count_crtcs;
	res.crtc_id_ptr = (uintptr_t)crtcs;
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res))
		return 1;
	for (uint32_t i = 0; i < res.count_crtcs; i++) {
		struct drm_mode_crtc crtc = { .crtc_id = crtcs[i] };
		if (ioctl(fd, DRM_IOCTL_MODE_GETCRTC, &crtc) || !crtc.fb_id)
			continue;
		struct drm_mode_fb_cmd2 fb = { .fb_id = crtc.fb_id };
		if (ioctl(fd, DRM_IOCTL_MODE_GETFB2, &fb) || !fb.handles[0]) {
			fprintf(stderr, "%s: GETFB2 failed\n", path);
			continue;
		}
		fprintf(stderr, "%s: crtc %u fb %u %ux%u format %.4s modifier 0x%llx pitch %u\n", path,
			crtcs[i], fb.fb_id, fb.width, fb.height, (char *)&fb.pixel_format,
			(unsigned long long)fb.modifier[0], fb.pitches[0]);
		struct drm_prime_handle prime = { .handle = fb.handles[0], .flags = DRM_CLOEXEC | DRM_RDWR };
		if (ioctl(fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime)) {
			prime.flags = DRM_CLOEXEC;
			if (ioctl(fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime)) {
				perror("PRIME_HANDLE_TO_FD");
				continue;
			}
		}
		size_t size = (size_t)fb.pitches[0] * fb.height + fb.offsets[0];
		uint8_t *map = mmap(NULL, size, PROT_READ, MAP_SHARED, prime.fd, 0);
		if (map == MAP_FAILED) {
			perror("mmap");
			continue;
		}
		struct dma_buf_sync sync = { .flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ };
		ioctl(prime.fd, DMA_BUF_IOCTL_SYNC, &sync);
		printf("P6\n%u %u\n255\n", fb.width, fb.height);
		uint8_t *row = malloc(fb.width * 3);
		for (uint32_t y = 0; y < fb.height; y++) {
			const uint8_t *src = map + fb.offsets[0] + (size_t)y * fb.pitches[0];
			for (uint32_t x = 0; x < fb.width; x++) {
				row[x * 3 + 0] = src[x * 4 + 2];
				row[x * 3 + 1] = src[x * 4 + 1];
				row[x * 3 + 2] = src[x * 4 + 0];
			}
			fwrite(row, 3, fb.width, stdout);
		}
		return 0;
	}
	return 1;
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++)
		if (!grab(argv[i]))
			return 0;
	return 1;
}
