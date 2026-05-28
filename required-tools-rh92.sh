sudo dnf update -y

sudo dnf install -y epel-release

sudo dnf install -y \
    git \
    python3 \
    python3-pip \
    python3-devel \
    clang \
    llvm \
    kernel-devel \
    kernel-headers \
    bcc \
    bcc-tools \
    libbpf