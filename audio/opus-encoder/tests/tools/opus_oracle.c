/*
  opus_oracle.c - Oráculo de pruebas del encoder Opus (NO forma parte de la librería)

  Codifica PCM s16le crudo con libopus 1.5.2 usando los mismos parámetros que
  las pruebas del port Delphi, y escribe los paquetes en formato .opk:
      "OPK1" + por paquete: int32 LE longitud, uint32 LE final_range, bytes
  También decodifica un .opk con libopus a PCM s16le (modo "decode").

  Uso:
    opus_oracle encode in.raw out.opk clave=valor...
      fs=48000 ch=1 app=voip|audio|lowdelay ms=20 (2.5,5,10,20,40,60)
      br=32000|auto|max vbr=1 cvbr=1 cx=10 mode=auto|celt|silk|hybrid
      bw=auto|nb|mb|wb|swb|fb maxbw=fb loss=0 fec=0 dtx=0 sig=auto|voice|music
      float=0 lsb=24 pinv=0 pred=0 fch=auto
      brcyc=b1,b2,...,N   (cambia el bitrate cíclicamente cada N tramas)
    opus_oracle decode in.opk out.raw fs=48000 ch=1
    opus_oracle fecdec in.bin out.raw fs=16000 ch=1 ms=20
      in.bin: por paquete uint16 LE longitud + bytes (longitud 0 = perdido).
      Paquete perdido: si llega el siguiente se decodifica su LBRR
      (decode_fec=1), si no, PLC normal.

  Se compila con build_oracle.sh contra libopus estático (oráculo, nunca
  dependencia de la librería). libopus: Copyright Xiph.Org Foundation y otros,
  licencia BSD.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <opus.h>
#include "opus_private.h"

static const char *getarg(int argc, char **argv, const char *key, const char *def)
{
   size_t n = strlen(key);
   for (int i = 0; i < argc; i++)
      if (strncmp(argv[i], key, n) == 0 && argv[i][n] == '=')
         return argv[i] + n + 1;
   return def;
}

static int bwval(const char *s)
{
   if (!strcmp(s, "nb")) return OPUS_BANDWIDTH_NARROWBAND;
   if (!strcmp(s, "mb")) return OPUS_BANDWIDTH_MEDIUMBAND;
   if (!strcmp(s, "wb")) return OPUS_BANDWIDTH_WIDEBAND;
   if (!strcmp(s, "swb")) return OPUS_BANDWIDTH_SUPERWIDEBAND;
   if (!strcmp(s, "fb")) return OPUS_BANDWIDTH_FULLBAND;
   return OPUS_AUTO;
}

static void put32(FILE *f, unsigned v)
{
   unsigned char b[4] = {v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255};
   fwrite(b, 1, 4, f);
}

static int get32(FILE *f, unsigned *v)
{
   unsigned char b[4];
   if (fread(b, 1, 4, f) != 4) return 0;
   *v = b[0] | (b[1] << 8) | (b[2] << 16) | ((unsigned)b[3] << 24);
   return 1;
}

static int do_encode(int argc, char **argv)
{
   int fs = atoi(getarg(argc, argv, "fs", "48000"));
   int ch = atoi(getarg(argc, argv, "ch", "1"));
   const char *apps = getarg(argc, argv, "app", "audio");
   int app = !strcmp(apps, "voip") ? OPUS_APPLICATION_VOIP :
             !strcmp(apps, "lowdelay") ? OPUS_APPLICATION_RESTRICTED_LOWDELAY : OPUS_APPLICATION_AUDIO;
   double ms = atof(getarg(argc, argv, "ms", "20"));
   int frame = (int)(fs * ms / 1000 + 0.5);
   const char *brs = getarg(argc, argv, "br", "auto");
   int br = !strcmp(brs, "auto") ? OPUS_AUTO : !strcmp(brs, "max") ? OPUS_BITRATE_MAX : atoi(brs);
   const char *modes = getarg(argc, argv, "mode", "auto");
   int mode = !strcmp(modes, "celt") ? MODE_CELT_ONLY : !strcmp(modes, "silk") ? MODE_SILK_ONLY :
              !strcmp(modes, "hybrid") ? MODE_HYBRID : OPUS_AUTO;
   const char *sigs = getarg(argc, argv, "sig", "auto");
   int sig = !strcmp(sigs, "voice") ? OPUS_SIGNAL_VOICE : !strcmp(sigs, "music") ? OPUS_SIGNAL_MUSIC : OPUS_AUTO;
   const char *fchs = getarg(argc, argv, "fch", "auto");
   int fch = !strcmp(fchs, "auto") ? OPUS_AUTO : atoi(fchs);
   int use_float = atoi(getarg(argc, argv, "float", "0"));
   int maxbytes = atoi(getarg(argc, argv, "maxbytes", "1276"));
   int brcyc[16], nbrcyc = 0, brperiod = 0;
   {
      char tmp[256];
      snprintf(tmp, sizeof(tmp), "%s", getarg(argc, argv, "brcyc", ""));
      for (char *t = strtok(tmp, ","); t && nbrcyc < 16; t = strtok(NULL, ","))
         brcyc[nbrcyc++] = atoi(t);
      if (nbrcyc >= 2) brperiod = brcyc[--nbrcyc];
   }
   int err;
   OpusEncoder *enc = opus_encoder_create(fs, ch, app, &err);
   if (err != OPUS_OK) { fprintf(stderr, "create: %d\n", err); return 1; }
   opus_encoder_ctl(enc, OPUS_SET_BITRATE(br));
   opus_encoder_ctl(enc, OPUS_SET_VBR(atoi(getarg(argc, argv, "vbr", "1"))));
   opus_encoder_ctl(enc, OPUS_SET_VBR_CONSTRAINT(atoi(getarg(argc, argv, "cvbr", "1"))));
   opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(atoi(getarg(argc, argv, "cx", "10"))));
   opus_encoder_ctl(enc, OPUS_SET_FORCE_MODE(mode));
   opus_encoder_ctl(enc, OPUS_SET_BANDWIDTH(bwval(getarg(argc, argv, "bw", "auto"))));
   opus_encoder_ctl(enc, OPUS_SET_MAX_BANDWIDTH(bwval(getarg(argc, argv, "maxbw", "fb"))));
   opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(atoi(getarg(argc, argv, "loss", "0"))));
   opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(atoi(getarg(argc, argv, "fec", "0"))));
   opus_encoder_ctl(enc, OPUS_SET_DTX(atoi(getarg(argc, argv, "dtx", "0"))));
   opus_encoder_ctl(enc, OPUS_SET_SIGNAL(sig));
   opus_encoder_ctl(enc, OPUS_SET_LSB_DEPTH(atoi(getarg(argc, argv, "lsb", "24"))));
   opus_encoder_ctl(enc, OPUS_SET_PHASE_INVERSION_DISABLED(atoi(getarg(argc, argv, "pinv", "0"))));
   opus_encoder_ctl(enc, OPUS_SET_PREDICTION_DISABLED(atoi(getarg(argc, argv, "pred", "0"))));
   opus_encoder_ctl(enc, OPUS_SET_FORCE_CHANNELS(fch));

   FILE *fi = fopen(argv[2], "rb");
   FILE *fo = fopen(argv[3], "wb");
   if (!fi || !fo) { fprintf(stderr, "no puedo abrir archivos\n"); return 1; }
   fwrite("OPK1", 1, 4, fo);
   short *pcm = malloc(sizeof(short) * frame * ch);
   float *pcmf = malloc(sizeof(float) * frame * ch);
   unsigned char pkt[1500];
   long total = 0;
   int n = 0;
   for (;;)
   {
      size_t got = fread(pcm, sizeof(short) * ch, frame, fi);
      if (got == 0) break;
      if ((int)got < frame) memset(pcm + got * ch, 0, sizeof(short) * ch * (frame - got));
      if (brperiod > 0 && n % brperiod == 0)
         opus_encoder_ctl(enc, OPUS_SET_BITRATE(brcyc[(n / brperiod) % nbrcyc]));
      int len;
#ifndef ORACLE_NO_FLOAT
      if (use_float)
      {
         for (int i = 0; i < frame * ch; i++) pcmf[i] = pcm[i] * (1.0f / 32768);
         len = opus_encode_float(enc, pcmf, frame, pkt, maxbytes);
      }
      else
#else
      (void)use_float; (void)pcmf;
#endif
         len = opus_encode(enc, pcm, frame, pkt, maxbytes);
      if (len < 0) { fprintf(stderr, "encode: %d\n", len); return 1; }
      opus_uint32 rng;
      opus_encoder_ctl(enc, OPUS_GET_FINAL_RANGE(&rng));
      put32(fo, len);
      put32(fo, rng);
      fwrite(pkt, 1, len, fo);
      total += len;
      n++;
   }
   fclose(fi);
   fclose(fo);
   fprintf(stderr, "%d paquetes, %ld bytes, %.1f kbps\n", n, total,
           n ? total * 8.0 / (n * ms) : 0.0);
   opus_encoder_destroy(enc);
   return 0;
}

static int do_decode(int argc, char **argv)
{
   int fs = atoi(getarg(argc, argv, "fs", "48000"));
   int ch = atoi(getarg(argc, argv, "ch", "1"));
   int err;
   OpusDecoder *dec = opus_decoder_create(fs, ch, &err);
   if (err != OPUS_OK) { fprintf(stderr, "create: %d\n", err); return 1; }
   FILE *fi = fopen(argv[2], "rb");
   FILE *fo = fopen(argv[3], "wb");
   if (!fi || !fo) { fprintf(stderr, "no puedo abrir archivos\n"); return 1; }
   char magic[4];
   if (fread(magic, 1, 4, fi) != 4 || memcmp(magic, "OPK1", 4)) { fprintf(stderr, "no es OPK1\n"); return 1; }
   short *pcm = malloc(sizeof(short) * 5760 * ch);
   unsigned char pkt[1500];
   unsigned len, rng;
   int n = 0, bad = 0;
   while (get32(fi, &len) && get32(fi, &rng))
   {
      if (len > sizeof(pkt) || fread(pkt, 1, len, fi) != len) { fprintf(stderr, "truncado\n"); return 1; }
      int r = opus_decode(dec, len ? pkt : NULL, len, pcm, 5760, 0);
      if (r < 0) { fprintf(stderr, "paquete %d: error %d\n", n, r); bad++; continue; }
      opus_uint32 drng;
      opus_decoder_ctl(dec, OPUS_GET_FINAL_RANGE(&drng));
      if (len > 1 && drng != rng) { fprintf(stderr, "paquete %d: final_range %08x != %08x\n", n, drng, rng); bad++; }
      fwrite(pcm, sizeof(short) * ch, r, fo);
      n++;
   }
   fclose(fi);
   fclose(fo);
   fprintf(stderr, "%d paquetes decodificados, %d con error\n", n, bad);
   opus_decoder_destroy(dec);
   return bad ? 2 : 0;
}

static int do_fecdec(int argc, char **argv)
{
   int fs = atoi(getarg(argc, argv, "fs", "16000"));
   int ch = atoi(getarg(argc, argv, "ch", "1"));
   double ms = atof(getarg(argc, argv, "ms", "20"));
   int frame = (int)(fs * ms / 1000 + 0.5);
   int err, n = 0, nfec = 0, nplc = 0;
   OpusDecoder *dec = opus_decoder_create(fs, ch, &err);
   if (err != OPUS_OK) { fprintf(stderr, "create: %d\n", err); return 1; }
   FILE *fi = fopen(argv[2], "rb");
   FILE *fo = fopen(argv[3], "wb");
   if (!fi || !fo) { fprintf(stderr, "no puedo abrir archivos\n"); return 1; }
   /* lee todos los paquetes */
   int cap = 1024, cnt = 0;
   unsigned char **pk = malloc(sizeof(*pk) * cap);
   int *pl = malloc(sizeof(int) * cap);
   unsigned char b2[2];
   while (fread(b2, 1, 2, fi) == 2)
   {
      int len = b2[0] | (b2[1] << 8);
      if (cnt == cap) { cap *= 2; pk = realloc(pk, sizeof(*pk) * cap); pl = realloc(pl, sizeof(int) * cap); }
      pk[cnt] = malloc(len ? len : 1);
      if (len && fread(pk[cnt], 1, len, fi) != (size_t)len) { fprintf(stderr, "truncado\n"); return 1; }
      pl[cnt++] = len;
   }
   short *pcm = malloc(sizeof(short) * 5760 * ch);
   for (int k = 0; k < cnt; k++)
   {
      int r;
      if (pl[k] > 0)
         r = opus_decode(dec, pk[k], pl[k], pcm, 5760, 0);
      else if (k + 1 < cnt && pl[k + 1] > 0)
      {
         r = opus_decode(dec, pk[k + 1], pl[k + 1], pcm, frame, 1);
         nfec++;
      }
      else
      {
         r = opus_decode(dec, NULL, 0, pcm, frame, 0);
         nplc++;
      }
      if (r < 0) { fprintf(stderr, "paquete %d: error %d\n", k, r); return 2; }
      fwrite(pcm, sizeof(short) * ch, r, fo);
      n++;
   }
   fclose(fi);
   fclose(fo);
   fprintf(stderr, "%d tramas, %d recuperadas con FEC, %d con PLC\n", n, nfec, nplc);
   opus_decoder_destroy(dec);
   return 0;
}

int main(int argc, char **argv)
{
   if (argc < 4) { fprintf(stderr, "uso: opus_oracle encode|decode in out clave=valor...\n"); return 1; }
   if (!strcmp(argv[1], "encode")) return do_encode(argc, argv);
   if (!strcmp(argv[1], "decode")) return do_decode(argc, argv);
   if (!strcmp(argv[1], "fecdec")) return do_fecdec(argc, argv);
   fprintf(stderr, "modo desconocido\n");
   return 1;
}
