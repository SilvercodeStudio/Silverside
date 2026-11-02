/* SPDX-License-Identifier: GPL-2.0-or-later
 * Scratch read-only video inventory through libdvdread's public API.
 */
#include <stdio.h>
#include <dvdread/dvd_reader.h>
#include <dvdread/ifo_read.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    dvd_reader_t *dvd=DVDOpen(argv[1]);
    if (!dvd) return 1;
    ifo_handle_t *m=ifoOpen(dvd,0);
    if (!m || m->ifo_format != IFO_VIDEO || !m->tt_srpt) return 1;
    printf("video titles=%u title_sets=%u\n",m->tt_srpt->nr_of_srpts,m->vmgi_mat->vmg_nr_of_title_sets);
    for (unsigned i=0;i<m->tt_srpt->nr_of_srpts;++i) {
        title_info_t *t=&m->tt_srpt->title[i];
        printf("title number=%u vts=%u title_in_set=%u chapters=%u angles=%u\n",
            i+1,t->title_set_nr,t->vts_ttn,t->nr_of_ptts,t->nr_of_angles);
    }
    int failed=0;
    for (unsigned n=1;n<=m->vmgi_mat->vmg_nr_of_title_sets;++n) {
        ifo_handle_t *v=ifoOpen(dvd,n);
        if (!v || !v->vtsi_mat) { failed=1; if(v) ifoClose(v); continue; }
        for (unsigned i=0;i<v->vtsi_mat->nr_of_vts_audio_streams;++i) {
            audio_attr_t *a=&v->vtsi_mat->vts_audio_attr[i];
            printf("stream vts=%u number=%u format_raw=%u channels=%u frequency_raw=%u quantization_raw=%u language_raw=%04x\n",
                n,i+1,a->audio_format,a->channels+1,a->sample_frequency,a->quantization,a->lang_code);
        }
        if(v->vts_ptt_srpt) for(unsigned t=0;t<v->vts_ptt_srpt->nr_of_srpts;++t) {
            ttu_t *title=&v->vts_ptt_srpt->title[t];
            for(unsigned k=0;k<title->nr_of_ptts;++k)
                printf("chapter vts=%u title=%u number=%u pgc=%u program=%u\n",n,t+1,k+1,title->ptt[k].pgcn,title->ptt[k].pgn);
        }
        if(v->vts_pgcit) for(unsigned g=0;g<v->vts_pgcit->nr_of_pgci_srp;++g) {
            pgc_t *pgc=v->vts_pgcit->pgci_srp[g].pgc;
            if(!pgc) continue;
            printf("pgc vts=%u number=%u programs=%u cells=%u\n",n,g+1,pgc->nr_of_programs,pgc->nr_of_cells);
            for(unsigned k=0;k<pgc->nr_of_programs;++k)
                printf("program vts=%u pgc=%u number=%u first_cell=%u\n",n,g+1,k+1,pgc->program_map[k]);
            for(unsigned k=0;k<pgc->nr_of_cells;++k) {
                cell_playback_t *c=&pgc->cell_playback[k];
                printf("cell vts=%u pgc=%u number=%u start=%u end=%u block_type=%u interleaved=%u discontinuity=%u time_bcd=%02x:%02x:%02x:%02x\n",
                    n,g+1,k+1,c->first_sector,c->last_sector,c->block_type,c->interleaved,c->stc_discontinuity,
                    c->playback_time.hour,c->playback_time.minute,c->playback_time.second,c->playback_time.frame_u);
            }
        }
        ifoClose(v);
    }
    ifoClose(m); DVDClose(dvd); return failed;
}
