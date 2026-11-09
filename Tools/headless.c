// Headless test runner: boots the ROM, presses Start, dumps frames as PPM.
#include "nescore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
static void dump(const char* path, const uint32_t* fb){FILE*f=fopen(path,"wb");fprintf(f,"P6 256 240 255\n");
 for(int i=0;i<256*240;i++){uint32_t c=fb[i];fputc(c&255,f);fputc((c>>8)&255,f);fputc((c>>16)&255,f);}fclose(f);}
int main(int argc,char**argv){
 FILE*f=fopen(argv[1],"rb");fseek(f,0,2);long L=ftell(f);rewind(f);unsigned char*b=malloc(L);fread(b,1,L,f);fclose(f);
 char err[256];NES*n=nes_create(b,L,err,256);if(!n){puts(err);return 1;}
 int frames=atoi(argv[2]); const char* script=argc>3?argv[3]:"";
 float tmp[4096]; long samples=0; double sumsq=0;
 for(int i=0;i<frames;i++){
  uint8_t btn=0;
  // script: "start@120,right@200-260,..."  simple parser
  const char*s=script; while(*s){char name[16];int a,bb=-1;int k=0;while(*s&&*s!='@')name[k++]=*s++;name[k]=0;if(*s)s++;a=atoi(s);while(*s&&*s!='-'&&*s!=',')s++;if(*s=='-'){s++;bb=atoi(s);while(*s&&*s!=',')s++;} if(*s==',')s++; if(bb<0)bb=a+5;
   if(i>=a&&i<bb){ if(!strcmp(name,"start"))btn|=NES_BTN_START; if(!strcmp(name,"a"))btn|=NES_BTN_A; if(!strcmp(name,"b"))btn|=NES_BTN_B;if(!strcmp(name,"select"))btn|=NES_BTN_SELECT;
    if(!strcmp(name,"up"))btn|=NES_BTN_UP;if(!strcmp(name,"down"))btn|=NES_BTN_DOWN;if(!strcmp(name,"left"))btn|=NES_BTN_LEFT;if(!strcmp(name,"right"))btn|=NES_BTN_RIGHT;}}
  nes_set_buttons(n,0,btn);
  nes_run_frame(n);
  int got; while((got=nes_audio_read(n,tmp,2048))>0){samples+=got;for(int j=0;j<got*2;j++)sumsq+=tmp[j]*tmp[j]/2;}
  if(argc>4 && (i+1)%atoi(argv[4])==0){char p[64];sprintf(p,"out/f%05d.ppm",i+1);dump(p,nes_framebuffer(n));
    char q[64];sprintf(q,"out/l%05d.bin",i+1);FILE*g=fopen(q,"wb");fwrite(nes_layer_bg(n),1,256*240,g);fwrite(nes_layer_spr(n),1,256*240,g);fwrite(nes_layer_backdrop(n),1,240,g);fclose(g);}
 }
 printf("audio samples %ld (%.1f/frame) rms %.4f\n",samples,(double)samples/frames, samples?sqrt(sumsq/samples):0);
 return 0;}
