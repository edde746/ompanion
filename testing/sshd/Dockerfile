# SSH test machine for omp_core: bastion and target run this image with different names.
FROM ubuntu:24.04

# curl and wget serve the download install route. Stock Ubuntu has neither; tests that need that machine
# hide them from PATH.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server ca-certificates curl wget \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd

# omp: key-only user (password "*": no password, but not locked, so sshd allows key logins).
# pw: password user. kbd: same password, offered only as a keyboard-interactive prompt.
# nopw: empty password, so `none` authentication succeeds (sshd_config: PermitEmptyPasswords).
RUN useradd --create-home --shell /bin/bash omp \
 && usermod --password '*' omp \
 && install -d -m 700 -o omp -g omp /home/omp/.ssh /home/omp/.local /home/omp/.local/bin \
 && useradd --create-home --shell /bin/bash pw \
 && useradd --create-home --shell /bin/bash kbd \
 && printf 'pw:omp-test-password\nkbd:omp-test-password\n' | chpasswd \
 && useradd --create-home --shell /bin/bash nopw \
 && passwd -d nopw

COPY sshd_config /etc/ssh/sshd_config.d/00-omp-test.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
