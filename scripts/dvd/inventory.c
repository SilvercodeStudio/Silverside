/* SPDX-License-Identifier: GPL-2.0-or-later
 * Scratch libdvdread inventory experiment; not part of Silverside's engine.
 * Uses the installed public API. No implementation copied from libdvdread.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dvdread/dvd_reader.h>
#include <dvdread/ifo_read.h>
#include <dvdread/version.h>

static int seek_image(void *p, uint64_t offset) {
    return fseeko(p, (off_t)offset, SEEK_SET);
}
static int read_image(void *p, void *buf, int count) {
    return (int)fread(buf, 1, count, p);
}
static void refs(const char *name, tracks_info_table_t *table) {
    if (!table) { printf("%s unavailable\n", name); return; }
    printf("%s entries=%u\n", name, table->nr_of_titles);
    for (unsigned i = 0; i < table->nr_of_titles; ++i) {
        track_info_t *r = &table->tracks_info[i];
        printf("reference table=%s row=%u type_rank=0x%02x group=%u title=%u chapters=%u pts=%u sector=%u\n",
            name, i+1, r->type_and_rank, r->group_property, r->title_property,
            r->nr_chapters_in_title, r->len_audio_zone_pts, r->ts_pointer_relative_sector);
    }
}
int main(int argc, char **argv) {
    int device = argc == 3 && strcmp(argv[1], "--device") == 0;
    if (argc != 2 && !device) return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    FILE *file = device ? NULL : fopen(argv[1], "rb");
    if (!device && !file) { perror("open"); return 1; }
    dvd_reader_stream_cb cb = {seek_image, read_image, NULL};
    dvd_reader_t *dvd = device ? DVDOpenAudio(NULL, NULL, argv[2]) : DVDOpenStreamAudio(file, NULL, &cb);
    if (!dvd) { if (file) fclose(file); return 1; }
    printf("libdvdread=%s\n", DVDREAD_VERSION_STRING);
    ifo_handle_t *manager = ifoOpen(dvd, 0);
    if (!manager || manager->ifo_format != IFO_AUDIO || !manager->amgi_mat) {
        fprintf(stderr, "No parsed audio manager\n");
        if (manager) ifoClose(manager);
        DVDClose(dvd); if (file) fclose(file); return 1;
    }
    printf("audio_manager id=%.12s audio_title_sets=%u video_title_sets=%u\n",
        manager->amgi_mat->amg_identifier, manager->amgi_mat->amg_nr_of_title_sets,
        manager->amgi_mat->vmg_nr_of_title_sets);
    refs("first", manager->info_table_first_sector);
    refs("second", manager->info_table_second_sector);
    ifo_handle_t *simple = ifoOpenSAMG(dvd);
    if (simple && simple->samg_mat) {
        samg_mat_t *s = simple->samg_mat;
        printf("samg chapters=%u\n", s->nr_chapters);
        for (unsigned i = 0; i < s->nr_chapters; ++i) {
            samg_chapter_t *r = &s->samg_chapters[i];
            printf("samg_chapter row=%u group=%u chapter=%u pts=%u duration_pts=%u codec_raw=0x%02x bits_raw=0x%02x rate_raw=0x%02x channels_raw=0x%02x start=%u start2=%u end=%u\n",
                i+1, r->group_num, r->chapter_num, r->timestamp_pts, r->chapter_len,
                r->record_code, r->bit_depth, r->sampling_rate, r->nr_channels,
                r->start_sector_1, r->start_sector_2, r->end_sector);
        }
    } else printf("samg unavailable\n");
    if (simple) ifoClose(simple);
    int failed = 0;
    for (unsigned n = 1; n <= manager->amgi_mat->amg_nr_of_title_sets; ++n) {
        ifo_handle_t *ifo = ifoOpen(dvd, n);
        if (!ifo || ifo->ifo_format != IFO_AUDIO || !ifo->atsi_mat || !ifo->atsi_title_table) {
            printf("ats number=%u unavailable\n", n); failed = 1;
            if (ifo) ifoClose(ifo);
            continue;
        }
        atsi_title_table_t *table = ifo->atsi_title_table;
        printf("ats number=%u id=%.12s titles=%u\n", n, ifo->atsi_mat->ats_identifier, table->nr_titles);
        for (unsigned a = 0; a < ATSI_RECORD_MAX_SIZE; ++a) {
            atsi_record_t *r = &ifo->atsi_mat->atsi_record[a];
            printf("attribute ats=%u row=%u codec_raw=0x%02x bits_raw=0x%02x rate_raw=0x%02x channels_raw=0x%02x\n",
                n, a+1, r->encoding, r->bitrate, r->sampling_frequency, r->nr_channels);
        }
        for (unsigned t = 0; t < table->nr_titles; ++t) {
            atsi_title_record_t *r = &table->atsi_title_row_tables[t];
            atsi_title_index_t *idx = &table->atsi_index_rows[t];
            printf("title ats=%u row=%u index=0x%02x mode=0x%02x tracks=%u cells=%u duration_pts=%u record_offset=%u\n",
                n, t+1, idx->srp_index, idx->audio_encode_mode, r->nr_tracks, r->nr_pointer_records,
                r->length_pts, idx->offset_record_table);
            uint64_t sum = 0;
            for (unsigned k = 0; k < r->nr_tracks; ++k) {
                atsi_track_timestamp_t *p = &r->atsi_track_timestamp_rows[k];
                sum += p->length_pts_of_track;
                printf("track ats=%u title_row=%u number=%u first_cell=%u start_pts=%u duration_pts=%u\n",
                    n, t+1, k+1, p->track_number_in_title, p->first_pts_of_track, p->length_pts_of_track);
            }
            printf("duration_check ats=%u title_row=%u sum=%llu expected=%u match=%s\n",
                n,t+1,(unsigned long long)sum,r->length_pts,sum==r->length_pts?"yes":"no");
            for (unsigned k = 0; k < r->nr_pointer_records; ++k) {
                atsi_track_pointer_t *p = &r->atsi_track_pointer_rows[k];
                printf("cell ats=%u title_row=%u row=%u index=%u type=%u start=%u end=%u\n",
                    n,t+1,k+1,p->cell_index,p->cell_type,p->start_sector,p->end_sector);
            }
        }
        ifoClose(ifo);
    }
    ifoClose(manager); DVDClose(dvd); if (file) fclose(file);
    return failed;
}
