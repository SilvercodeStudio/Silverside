/* SPDX-License-Identifier: GPL-2.0-or-later
 * Experimental public-libdvdread client. Read-only source, exclusive new output.
 * Usage: read_blocks audio|video SOURCE TITLE_SET START COUNT OUTPUT
 * Offsets are relative to the logical concatenation of title AOBs/VOBs.
 */
#include <dvdread/dvd_reader.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void timed_out(int signal_number) {
    (void)signal_number;
    const char message[] = "DVD operation timed out; output is incomplete\n";
    (void)write(STDERR_FILENO, message, sizeof(message)-1);
    _exit(124);
}

static long number(const char *s) {
    char *end;
    errno = 0;
    long n = strtol(s, &end, 10);
    if (errno || !*s || *end || n < 0 || n > INT_MAX) {
        fprintf(stderr, "Invalid numeric argument\n"); exit(2);
    }
    return n;
}
int main(int argc, char **argv) {
    if (argc != 7 || (strcmp(argv[1], "audio") && strcmp(argv[1], "video"))) return 2;
    int title = (int)number(argv[3]), start = (int)number(argv[4]);
    long count = number(argv[5]);
    if (!title || !count || count > INT_MAX-start) return 2;
    int fd = open(argv[6], O_WRONLY|O_CREAT|O_EXCL, 0600);
    if (fd < 0) { perror("output"); return 1; }
    struct sigaction action = {0};
    action.sa_handler = timed_out;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGALRM, &action, NULL)) { perror("sigaction"); close(fd); return 1; }
    alarm(120);
    dvd_reader_t *dvd = !strcmp(argv[1], "audio") ? DVDOpenAudio(NULL,NULL,argv[2]) : DVDOpen(argv[2]);
    if (!dvd) { close(fd); return 1; }
    dvd_file_t *file = DVDOpenFile(dvd, title, DVD_READ_TITLE_VOBS);
    if (!file) { DVDClose(dvd); close(fd); return 1; }
    unsigned char buffer[32*2048];
    int failed = 0;
    time_t last_progress = time(NULL);
    for (long done=0; done<count;) {
        alarm(120);
        int blocks = count-done > 32 ? 32 : (int)(count-done);
        ssize_t got = DVDReadBlocks(file,start+(int)done,(size_t)blocks,buffer);
        if (got != blocks) { fprintf(stderr,"short read at %ld: %zd/%d\n",start+done,got,blocks); failed=1; break; }
        size_t remaining = (size_t)got*2048, offset = 0;
        while (remaining) {
            ssize_t written = write(fd,buffer+offset,remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { perror("write"); failed=1; break; }
            offset += (size_t)written; remaining -= (size_t)written;
        }
        if (failed) break;
        done += got;
        time_t now = time(NULL);
        if (now-last_progress >= 10 || done == count) {
            fprintf(stderr,"read %ld/%ld sectors (%.1f%%)\n",done,count,100.0*(double)done/(double)count);
            last_progress = now;
        }
    }
    alarm(120);
    DVDCloseFile(file); DVDClose(dvd);
    alarm(0);
    if (close(fd)) failed=1;
    return failed;
}
