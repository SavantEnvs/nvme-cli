// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 SUSE LLC
 *
 * Authors: Daniel Wagner <dwagner@suse.de>
 */

/*
 * Fuzz the I/O statistics of nvme top: libnvme parses the block layer
 * stat files of the namespaces and paths, nvme-iostat.c turns two
 * samples into rates. The sysfs tree is a captured one with a single
 * path and a multipath subsystem.
 *
 * The input is text. The first line is the time in milliseconds between
 * the two samples, the lines after it are the stat files: those of the
 * first sample, then those of the second, in the order of the topology
 * scan. A missing line leaves the file empty.
 *
 * Mayhem copy of tests/fuzz/fuzz-iostat.c. Two changes, nothing else:
 *  - the time between the samples is clamped to [0, MAX_MS]. The library
 *    reads CLOCK_MONOTONIC, which is never negative or near LONG_MAX
 *    seconds, so an unbounded value only fed it an impossible clock;
 *  - the start-up honours TMPDIR, retries the extraction and exits with a
 *    message instead of an empty abort() when the sysfs tree can't be set up.
 */
#include <dlfcn.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <sys/stat.h>

#include <libnvme.h>

#include "fuzz.h"
#include "nvme-iostat.h"

#define MAX_STATS	16
/* one day */
#define MAX_MS		86400000L

static struct libnvme_global_ctx *ctx;
static char tmpdir[PATH_MAX];
static char *stats[MAX_STATS];
static int nr_stats;

/* While set, clock_gettime() returns the fake time */
static bool fake_clock;
static struct timespec fake_now;

int clock_gettime(clockid_t clk, struct timespec *ts)
{
	static int (*real)(clockid_t, struct timespec *);

	if (fake_clock) {
		*ts = fake_now;
		return 0;
	}
	if (!real)
		real = (int (*)(clockid_t, struct timespec *))
			dlsym(RTLD_NEXT, "clock_gettime");
	return real(clk, ts);
}

/* as nvme top tells them apart */
static bool is_multipath(struct libnvme_subsystem *s)
{
	struct libnvme_path *p;
	struct libnvme_ns *n;

	libnvme_subsystem_for_each_ns(s, n)
		libnvme_namespace_for_each_path(n, p)
			return true;

	return false;
}

static void add_stat(const char *dir)
{
	if (nr_stats == MAX_STATS ||
	    asprintf(&stats[nr_stats], "%s/stat", dir) < 0)
		abort();
	/* the captured files are read-only */
	if (chmod(stats[nr_stats], 0644))
		abort();
	nr_stats++;
}

/* The stat files of the namespaces and paths of @s, as nvme top reads them */
static void add_stats(struct libnvme_subsystem *s)
{
	struct libnvme_ctrl *c;
	struct libnvme_path *p;
	struct libnvme_ns *n;

	if (!is_multipath(s)) {
		libnvme_subsystem_for_each_ctrl(s, c)
			libnvme_ctrl_for_each_ns(c, n)
				add_stat(libnvme_ns_get_sysfs_dir(n));
		return;
	}
	libnvme_subsystem_for_each_ns(s, n) {
		add_stat(libnvme_ns_get_sysfs_dir(n));
		libnvme_namespace_for_each_path(n, p)
			add_stat(libnvme_path_get_sysfs_dir(p));
	}
}

static void cleanup(void)
{
	char *cmd;

	libnvme_free_global_ctx(ctx);
	if (asprintf(&cmd, "rm -rf %s", tmpdir) >= 0) {
		if (system(cmd))
			fprintf(stderr, "failed to remove %s\n", tmpdir);
		free(cmd);
	}
	while (nr_stats)
		free(stats[--nr_stats]);
}

/* Extracts the captured sysfs tree into a fresh directory below @base */
static bool extract_tree(const char *base)
{
	char *cmd;
	int ret;

	if (snprintf(tmpdir, sizeof(tmpdir), "%s/fuzz-iostat-XXXXXX", base) >=
	    (int)sizeof(tmpdir) || !mkdtemp(tmpdir))
		return false;
	if (asprintf(&cmd, "tar -xJf %s -C %s", FUZZ_IOSTAT_TREE, tmpdir) < 0)
		return false;
	ret = system(cmd);
	free(cmd);
	if (ret) {
		fprintf(stderr, "failed to extract %s into %s\n",
			FUZZ_IOSTAT_TREE, tmpdir);
		return false;
	}
	return true;
}

static void setup_tree(void)
{
	const char *bases[] = { getenv("TMPDIR"), "/tmp", "." };
	size_t i;
	int try;

	for (try = 0; try < 3; try++) {
		for (i = 0; i < sizeof(bases) / sizeof(bases[0]); i++) {
			if (bases[i] && *bases[i] && extract_tree(bases[i]))
				return;
		}
	}
	fprintf(stderr, "fuzz-iostat: can't set up the sysfs tree\n");
	exit(1);
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	struct libnvme_subsystem *s;
	struct libnvme_host *h;

	(void)argc;
	(void)argv;
	setup_tree();

	ctx = libnvme_create_global_ctx();
	if (!ctx || libnvme_set_test_sysfs_dir(ctx, tmpdir) ||
	    libnvme_scan_topology(ctx, NULL, NULL))
		abort();
	atexit(cleanup);

	libnvme_for_each_host(ctx, h)
		libnvme_for_each_subsystem(h, s)
			add_stats(s);
	/* a namespace, and one with two paths */
	if (nr_stats != 4)
		abort();

	return 0;
}

/* Returns the next line of @data, or an empty one */
static const char *next_line(const char **data, const char *end,
			     size_t *len)
{
	const char *line = *data, *nl;

	if (line >= end) {
		*len = 0;
		return "";
	}
	nl = memchr(line, '\n', end - line);
	*len = (nl ? nl : end) - line;
	*data = nl ? nl + 1 : end;
	return line;
}

static void write_stats(const char **data, const char *end)
{
	const char *line;
	size_t len;
	FILE *f;
	int i;

	for (i = 0; i < nr_stats; i++) {
		line = next_line(data, end, &len);
		f = fopen(stats[i], "w");
		if (!f)
			abort();
		fwrite(line, 1, len, f);
		fclose(f);
	}
}

static void sample(void)
{
	struct libnvme_subsystem *s;
	struct libnvme_host *h;

	fake_clock = true;
	libnvme_for_each_host(ctx, h)
		libnvme_for_each_subsystem(h, s)
			nvme_iostat_update_subsys(s, is_multipath(s));
	fake_clock = false;
}

static void show(const struct nvme_iostat *st)
{
	char buf[16];

	nvme_iostat_format_iops(st->r_iops, buf, sizeof(buf));
	nvme_iostat_format_iops(st->w_iops, buf, sizeof(buf));
	nvme_iostat_format_bw(st->r_bw, buf, sizeof(buf));
	nvme_iostat_format_bw(st->w_bw, buf, sizeof(buf));
	nvme_iostat_format_lat(st->r_lat, buf, sizeof(buf));
	nvme_iostat_format_lat(st->w_lat, buf, sizeof(buf));
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const char *in = (const char *)data, *end = in + size, *line;
	struct nvme_iostat aggr = { 0 }, st;
	struct libnvme_subsystem *s;
	struct libnvme_host *h;
	struct libnvme_ctrl *c;
	struct libnvme_path *p;
	struct libnvme_ns *n;
	char num[32];
	size_t len;
	long ms;

	line = next_line(&in, end, &len);
	snprintf(num, sizeof(num), "%.*s", (int)(len < 31 ? len : 31), line);
	ms = strtol(num, NULL, 10);
	if (ms < 0)
		ms = 0;
	if (ms > MAX_MS)
		ms = MAX_MS;

	/* the two samples are libnvme's stat[0] and stat[1] */
	libnvme_for_each_host(ctx, h)
		libnvme_for_each_subsystem(h, s)
			nvme_iostat_reset_subsys(s, is_multipath(s));

	fake_now = (struct timespec){ .tv_sec = 1000 };
	write_stats(&in, end);
	sample();

	fake_now.tv_sec += ms / 1000;
	fake_now.tv_nsec = (ms % 1000) * 1000000;
	write_stats(&in, end);
	sample();

	libnvme_for_each_host(ctx, h) {
		libnvme_for_each_subsystem(h, s) {
			libnvme_subsystem_for_each_ctrl(s, c)
				libnvme_ctrl_for_each_ns(c, n) {
					nvme_iostat_ns(n, &st);
					show(&st);
				}
			libnvme_subsystem_for_each_ns(s, n) {
				nvme_iostat_ns(n, &st);
				nvme_iostat_aggr(&aggr, &st);
				show(&st);
				libnvme_namespace_for_each_path(n, p) {
					nvme_iostat_path(p, &st);
					nvme_iostat_aggr(&aggr, &st);
					show(&st);
				}
			}
		}
	}
	show(&aggr);

	return 0;
}
