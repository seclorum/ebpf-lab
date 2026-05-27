#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#include <sys/wait.h>
#include <errno.h>

#define CONTROL_SOCKET "/tmp/controld"
#define STREAM_SOCKET "/tmp/streamd"
#define UTIL_SOCKET "/tmp/utild"

pid_t pid_stream = -1;
pid_t pid_util = -1;

void cleanup_sockets() {
    unlink(CONTROL_SOCKET);
    unlink(STREAM_SOCKET);
    unlink(UTIL_SOCKET);
}

void handle_signal(int sig) {
    if (sig == SIGHUP) {
        printf("[controld] Received HUP, stopping children...\n");
        if (pid_stream > 0) kill(pid_stream, SIGTERM);
        if (pid_util > 0) kill(pid_util, SIGTERM);
        sleep(1);
        cleanup_sockets();
        exit(0);
    }
}

int create_server_socket(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path)-1);
    
    unlink(path);
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 5) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int send_command(const char *sock_path, const char *cmd) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path)-1);
    
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    write(fd, cmd, strlen(cmd));
    close(fd);
    return 0;
}

int main() {
    signal(SIGHUP, handle_signal);
    atexit(cleanup_sockets);
    
    printf("[controld] Starting...\n");
    
    // Fork and exec streamd
    pid_stream = fork();
    if (pid_stream == 0) {
        execl("./streamd", "streamd", NULL);
        perror("execl streamd");
        exit(1);
    }
    
    // Fork and exec utild
    pid_util = fork();
    if (pid_util == 0) {
        execl("./utild", "utild", NULL);
        perror("execl utild");
        exit(1);
    }
    
    sleep(1); // Give time for children to start sockets
    
    int control_fd = create_server_socket(CONTROL_SOCKET);
    if (control_fd < 0) {
        perror("create control socket");
        exit(1);
    }
    
    printf("[controld] Listening on %s. Children started (pids: %d, %d)\n", 
           CONTROL_SOCKET, pid_stream, pid_util);
    
    // Simple control loop - accept connections and forward commands
    while (1) {
        struct sockaddr_un client_addr;
        socklen_t len = sizeof(client_addr);
        int client = accept(control_fd, (struct sockaddr*)&client_addr, &len);
        if (client < 0) continue;
        
        char buf[128] = {0};
        int n = read(client, buf, sizeof(buf)-1);
        if (n > 0) {
            buf[n] = 0;
            printf("[controld] Received command: %s\n", buf);
            
            if (strstr(buf, "start")) {
                send_command(STREAM_SOCKET, "start");
            } else if (strstr(buf, "stop")) {
                send_command(STREAM_SOCKET, "stop");
            } else if (strstr(buf, "faster")) {
                send_command(STREAM_SOCKET, "faster");
            } else if (strstr(buf, "slower")) {
                send_command(STREAM_SOCKET, "slower");
            }
        }
        close(client);
    }
    
    close(control_fd);
    return 0;
}
