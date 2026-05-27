#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <signal.h>
#include <fcntl.h>

#define STREAM_SOCKET "/tmp/streamd"
#define LOG_FILE "/tmp/streamd.log"

int running = 1;
double interval = 1.0; // seconds

void handle_signal(int sig) {
    if (sig == SIGTERM || sig == SIGINT) running = 0;
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
    fcntl(fd, F_SETFL, O_NONBLOCK);
    return fd;
}

int main() {
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    
    FILE *log = fopen(LOG_FILE, "w");
    if (!log) {
        perror("fopen log");
        return 1;
    }
    fclose(log);
    
    int sock_fd = create_server_socket(STREAM_SOCKET);
    if (sock_fd < 0) {
        perror("create stream socket");
        return 1;
    }
    
    printf("[streamd] Started, logging to %s, interval %.2fs\n", LOG_FILE, interval);
    
    while (running) {
        // Handle incoming commands non-blockingly
        struct sockaddr_un client;
        socklen_t len = sizeof(client);
        int client_fd = accept(sock_fd, (struct sockaddr*)&client, &len);
        if (client_fd >= 0) {
            char buf[64] = {0};
            read(client_fd, buf, sizeof(buf)-1);
            
            if (strstr(buf, "start")) {
                running = 1;
            } else if (strstr(buf, "stop")) {
                running = 0;
            } else if (strstr(buf, "faster")) {
                interval = 0.25;
                printf("[streamd] Speed increased to %.2fs\n", interval);
            } else if (strstr(buf, "slower")) {
                interval = 1.0;
                printf("[streamd] Speed decreased to %.2fs\n", interval);
            }
            close(client_fd);
        }
        
        if (running) {
            time_t now = time(NULL);
            struct tm *tm = localtime(&now);
            char datetime[64];
            strftime(datetime, sizeof(datetime), "%Y-%m-%d %H:%M:%S", tm);
            
            log = fopen(LOG_FILE, "a");
            if (log) {
                fprintf(log, "[%s: stream message]\n", datetime);
                fclose(log);
            }
        }
        
        usleep((useconds_t)(interval * 1000000));
    }
    
    close(sock_fd);
    unlink(STREAM_SOCKET);
    printf("[streamd] Stopped\n");
    return 0;
}
