#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <signal.h>
#include <fcntl.h>

#define UTIL_SOCKET "/tmp/ebpf_lab/utild"
#define LOG_FILE "/tmp/ebpf_lab/ipc_logs/streamd.log"

int running = 1;

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

void dump_log() {
    FILE *f = fopen(LOG_FILE, "r");
    if (!f) return;
    
    printf("\n[utild] === Dumping %s at %ld ===\n", LOG_FILE, time(NULL));
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        printf("%s", line);
    }
    fclose(f);
    printf("[utild] === End of dump task by utild ===\n\n");
}

int main() {
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    
    int sock_fd = create_server_socket(UTIL_SOCKET);
    if (sock_fd < 0) {
        perror("create util socket");
        return 1;
    }
    
    printf("[utild] Started, dumping every 4 seconds\n");
    
    while (running) {
        // Handle commands (placeholder for marshalling)
        struct sockaddr_un client;
        socklen_t len = sizeof(client);
        int client_fd = accept(sock_fd, (struct sockaddr*)&client, &len);
        if (client_fd >= 0) {
            // Could handle commands here if needed
            close(client_fd);
        }
        
        dump_log();
        sleep(4);
    }
    
    close(sock_fd);
    unlink(UTIL_SOCKET);
    printf("[utild] Stopped\n");
    return 0;
}
