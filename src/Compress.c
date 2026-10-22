#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <fts.h>
#include <sys/stat.h>
#include <limits.h>
#include <locale.h>
#include <errno.h>
#include <time.h>
struct archive;struct archive_entry;
extern struct archive *archive_write_new(void);
extern int archive_write_set_format_zip(struct archive *);
extern int archive_write_set_options(struct archive *,const char *);
extern int archive_write_open_fd(struct archive *,int);
extern int archive_write_header(struct archive *,struct archive_entry *);
extern long archive_write_data(struct archive *,const void *,size_t);
extern int archive_write_close(struct archive *);
extern int archive_write_free(struct archive *);
extern const char *archive_error_string(struct archive *);
extern struct archive_entry *archive_entry_new(void);
extern void archive_entry_free(struct archive_entry *);
extern void archive_entry_set_pathname(struct archive_entry *,const char *);
extern void archive_entry_set_size(struct archive_entry *,int64_t);
extern void archive_entry_set_filetype(struct archive_entry *,unsigned short);
extern void archive_entry_set_perm(struct archive_entry *,unsigned short);
extern void archive_entry_set_mtime(struct archive_entry *,time_t,long);
static void fail(const char *s){fprintf(stderr,"%s\n",s?s:"Falha na compactação.");exit(1);}
static double timestamp(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
int compress_main(int argc,char **argv){
 if(!setlocale(LC_CTYPE,"en_US.UTF-8"))fail("Não foi possível configurar nomes UTF-8.");
 if(argc<5)fail("Selecione arquivos ou pastas para compactar.");int scan=!strcmp(argv[1],"cscan");
 struct archive *a=NULL;int output=-1;
 if(!scan){output=open(argv[2],O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600);if(output<0)fail("O destino temporário não está disponível.");a=archive_write_new();archive_write_set_format_zip(a);if(archive_write_set_options(a,"zip:compression=deflate,zip:compression-level=1,zip:hdrcharset=UTF-8")!=0)fail(archive_error_string(a));if(archive_write_open_fd(a,output)!=0)fail(archive_error_string(a));}
 char **paths=calloc((size_t)argc,sizeof(char *));for(int i=4;i<argc;i++)paths[i-4]=argv[i];
 FTS *tree=fts_open(paths,FTS_PHYSICAL|FTS_NOCHDIR,NULL);if(!tree)fail("Não foi possível percorrer os arquivos.");
 char *buffer=malloc(1024*1024);if(!buffer)fail("Memória insuficiente.");uint64_t total=0,count=0;double last=timestamp();setvbuf(stdout,NULL,_IOLBF,0);
 FTSENT *e;
 while(1){
  errno=0;e=fts_read(tree);if(!e){if(errno)fail("Falha ao percorrer os arquivos de origem.");break;}
  if(!strcmp(e->fts_path,argv[2])){if(e->fts_info==FTS_D)fts_set(tree,e,FTS_SKIP);continue;}
  if(e->fts_info==FTS_DP)continue;
  if(e->fts_info!=FTS_D&&e->fts_info!=FTS_F)fail("Links, arquivos especiais ou itens sem permissão não podem ser compactados.");
  if(++count>1000000)fail("Quantidade de itens fora do limite seguro.");
  uint64_t size=e->fts_info==FTS_F?(uint64_t)e->fts_statp->st_size:0;
  if(scan){if(size>UINT64_MAX-total)fail("Tamanho total inválido.");total+=size;continue;}
  FTSENT *root=e;while(root->fts_level>0)root=root->fts_parent;
  const char *base=root->fts_name;
  char name[PATH_MAX];const char *suffix=e->fts_path+root->fts_pathlen;if(snprintf(name,sizeof(name),"%s%s",base,suffix)>=(int)sizeof(name))fail("Caminho muito longo.");
  struct archive_entry *entry=archive_entry_new();archive_entry_set_pathname(entry,name);archive_entry_set_filetype(entry,e->fts_info==FTS_D?S_IFDIR:S_IFREG);archive_entry_set_perm(entry,(unsigned short)(e->fts_statp->st_mode&0777));archive_entry_set_size(entry,(int64_t)size);archive_entry_set_mtime(entry,e->fts_statp->st_mtime,0);
  if(archive_write_header(a,entry)!=0)fail(archive_error_string(a));archive_entry_free(entry);
  if(e->fts_info==FTS_F){int fd=open(e->fts_path,O_RDONLY|O_NOFOLLOW);if(fd<0)fail("Não foi possível abrir um arquivo de origem.");uint64_t used=0;long n;
   while((n=read(fd,buffer,1024*1024))>0){used+=(uint64_t)n;if(used>size)fail("Um arquivo mudou durante a compactação. Tente novamente.");long off=0;while(off<n){long w=archive_write_data(a,buffer+off,(size_t)(n-off));if(w<=0)fail(archive_error_string(a));off+=w;}total+=(uint64_t)n;if(timestamp()-last>.15){printf("PROGRESS\t%llu\n",(unsigned long long)total);last=timestamp();}}
   if(n<0||used!=size)fail("Falha de leitura ou arquivo alterado durante a compactação.");close(fd);
  }
 }
 fts_close(tree);free(paths);free(buffer);
 if(scan){printf("TOTAL\t%llu\n",(unsigned long long)total);return 0;}
 if(archive_write_close(a)!=0)fail(archive_error_string(a));archive_write_free(a);if(close(output)!=0)fail("Falha ao finalizar o ZIP.");printf("PROGRESS\t%llu\nDONE\n",(unsigned long long)total);return 0;
}
