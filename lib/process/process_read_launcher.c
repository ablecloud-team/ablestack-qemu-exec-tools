/* Copyright 2026 ABLECLOUD. Apache-2.0.
 * The only entrypoint into the read-only collector SELinux domain.
 * Never forward interpreter options, paths or environment from the caller. */
#include <unistd.h>
#include <string.h>
#include <ctype.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (geteuid()!=0 || argc!=3 || strcmp(argv[1],"--request-base64")) return 2;
    size_t n=strnlen(argv[2],87385);
    if (!n || n>87384) return 2;
    for(size_t i=0;i<n;i++) {
        unsigned char c=(unsigned char)argv[2][i];
        if (!(c>='A'&&c<='Z') && !(c>='a'&&c<='z') && !(c>='0'&&c<='9') && c!='+' && c!='/' && c!='=') return 2;
    }
    long maxfd=sysconf(_SC_OPEN_MAX);
    if(maxfd<0 || maxfd>1048576) maxfd=1048576;
    for(int fd=3;fd<maxfd;fd++) close(fd);
    char *args[]={"/usr/bin/python3","-I","-B","/usr/libexec/ablestack-qemu-exec-tools/process/process_list_linux.py","--request-base64",argv[2],NULL};
    char *env[]={"PATH=/usr/bin:/bin","LC_ALL=C.UTF-8",NULL};
    execve(args[0],args,env);
    perror("collector interpreter unavailable");
    return 3;
}
