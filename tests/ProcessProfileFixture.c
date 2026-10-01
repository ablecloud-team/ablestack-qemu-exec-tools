/* Copyright 2026 ABLECLOUD. Apache-2.0. Disposable process profile fixture. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <limits.h>
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 if(access("fail-next-start",F_OK)==0)return 7;
 char cwd[PATH_MAX];if(!getcwd(cwd,sizeof cwd))return 3;
 FILE *out=fopen(argv[1],"w");if(!out)return 4;
 fprintf(out,"{\"pid\":%ld,\"uid\":%ld,\"cwd\":\"%s\",\"environmentReferenceApplied\":%s}\n",(long)getpid(),(long)getuid(),cwd,getenv("PROFILE_SECRET")?"true":"false");fclose(out);
 for(;;)sleep(1);
}
