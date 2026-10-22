#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>
#include <limits.h>

/* Stable public libarchive ABI supplied by macOS. No private Apple APIs. */
struct archive; struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_open_filename(struct archive *,const char *,size_t);
extern int archive_read_next_header(struct archive *,struct archive_entry **);
extern int archive_read_data_skip(struct archive *);
extern long archive_read_data(struct archive *,void *,size_t);
extern int archive_read_free(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern unsigned short archive_entry_filetype(struct archive_entry *);
static uint64_t bytes=0,total=0,count=0; static double last=0;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void die(const char *msg){fprintf(stderr,"%s\n",msg?msg:"Falha ao ler o arquivo ZIP.");exit(1);}
static int safe(const char *p){
 if(!p||!*p||strlen(p)>=PATH_MAX||p[0]=='/'||strchr(p,'\\')||strchr(p,':'))return 0;
 const char *s=p;while(*s){const char *e=strchr(s,'/');size_t n=e?(size_t)(e-s):strlen(s);if(!n||(n==1&&s[0]=='.')||(n==2&&s[0]=='.'&&s[1]=='.'))return 0;if(!e)break;s=e+1;if(!*s)break;}return 1;
}
/* Every directory traversal uses a descriptor and refuses symlinks. */
static int parent(int root,const char *path,char *leaf){
 char buf[PATH_MAX];strlcpy(buf,path,sizeof(buf));size_t n=strlen(buf);if(n&&buf[n-1]=='/')buf[n-1]=0;
 char *slash=strrchr(buf,'/');int fd=dup(root);if(fd<0)die("Não foi possível abrir o destino.");
 if(!slash){strlcpy(leaf,buf,NAME_MAX+1);if(strlen(buf)>NAME_MAX)die("Nome de arquivo muito longo.");return fd;}
 *slash=0;if(strlen(slash+1)>NAME_MAX)die("Nome de arquivo muito longo.");strlcpy(leaf,slash+1,NAME_MAX+1);
 char *save,*part=strtok_r(buf,"/",&save);while(part){if(mkdirat(fd,part,0700)<0&&errno!=EEXIST)die("Não foi possível criar a pasta.");int next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(fd);if(next<0)die("Conflito entre arquivo e pasta ou link não permitido.");fd=next;part=strtok_r(NULL,"/",&save);}return fd;
}
extern int compress_main(int,char **);
int main(int argc,char **argv){
 if(argc>1&&(!strcmp(argv[1],"compress")||!strcmp(argv[1],"cscan")))return compress_main(argc,argv);
 if(argc<5)die("Uso: engine scan|extract destino both|skip arquivos.zip…");int scan=!strcmp(argv[1],"scan");int skip=!strcmp(argv[3],"skip");
 int root=open(argv[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0)die("Destino indisponível.");
 char *buffer=malloc(1024*1024);if(!buffer)die("Memória insuficiente.");setvbuf(stdout,NULL,_IOLBF,0);last=now();
 for(int i=4;i<argc;i++){
  struct archive *a=archive_read_new();archive_read_support_filter_all(a);archive_read_support_format_zip(a);
  if(archive_read_open_filename(a,argv[i],1024*1024)!=0)die(archive_error_string(a));
  struct archive_entry *e;int status;
  while((status=archive_read_next_header(a,&e))==0){
   const char *path=archive_entry_pathname(e);if(!safe(path))die("O ZIP contém um caminho inválido ou que sai da pasta de destino.");
   unsigned short type=archive_entry_filetype(e);if(archive_entry_symlink(e)||archive_entry_hardlink(e)||(type!=S_IFREG&&type!=S_IFDIR))die("Este ZIP contém links ou tipos especiais. Extração bloqueada para proteger o destino.");
   int64_t size=archive_entry_size(e);if(size<0||++count>1000000)die("Quantidade ou tamanho de entradas fora do limite seguro.");
   if(scan){if((uint64_t)size>UINT64_MAX-total)die("Tamanho total inválido.");total+=(uint64_t)size;printf("ENTRY\t%u\t%lld\t",type,(long long)size);/* Hex keeps file names from injecting protocol lines. */for(const unsigned char *c=(const unsigned char *)path;*c;c++)printf("%02x",*c);printf("\n");if(archive_read_data_skip(a)<0)die(archive_error_string(a));continue;}
   char leaf[NAME_MAX+1];int dir=parent(root,path,leaf);
   if(type==S_IFDIR){if(mkdirat(dir,leaf,0700)<0&&errno!=EEXIST)die("Não foi possível criar a pasta.");int check=openat(dir,leaf,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);if(check<0)die("Conflito entre pasta e arquivo.");close(check);close(dir);continue;}
   int out=openat(dir,leaf,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
   if(out<0&&errno==EEXIST&&skip){close(dir);if(archive_read_data_skip(a)<0)die(archive_error_string(a));continue;}
   if(out<0&&errno==EEXIST){char candidate[NAME_MAX+1];for(int k=2;k<100000;k++){char suffix[32];snprintf(suffix,sizeof(suffix)," (%d)",k);const char *dot=strrchr(leaf,'.');size_t stem=dot&&dot!=leaf?(size_t)(dot-leaf):strlen(leaf);const char *ext=dot&&dot!=leaf?dot:"";if(stem+strlen(ext)+strlen(suffix)>NAME_MAX)die("Nome repetido muito longo.");snprintf(candidate,sizeof(candidate),"%.*s%s%s",(int)stem,leaf,suffix,ext);out=openat(dir,candidate,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(out>=0||errno!=EEXIST)break;}}
   if(out<0)die("Não foi possível criar o arquivo de destino.");
   long n;uint64_t written=0;while((n=archive_read_data(a,buffer,1024*1024))>0){
    if(written+(uint64_t)n>(uint64_t)size)die("O conteúdo ultrapassou o tamanho declarado no ZIP.");
    long offset=0;while(offset<n){long w=write(out,buffer+offset,(size_t)(n-offset));if(w<=0)die("Falha de escrita. Verifique espaço livre e permissões.");offset+=w;}written+=(uint64_t)n;bytes+=(uint64_t)n;
    if(now()-last>.15){printf("PROGRESS\t%llu\n",(unsigned long long)bytes);last=now();}
   }
   if(n<0)die(archive_error_string(a));if(written!=(uint64_t)size)die("Arquivo incompleto ou ZIP corrompido.");if(close(out)<0)die("Falha ao finalizar a escrita.");close(dir);
  }
  if(status!=1)die(archive_error_string(a));archive_read_free(a);
 }
 if(scan)printf("TOTAL\t%llu\n",(unsigned long long)total);else printf("PROGRESS\t%llu\nDONE\n",(unsigned long long)bytes);
 close(root);free(buffer);return 0;
}
