# Decoy SMB file share: real Samba, built from Debian rather than a
# third-party image. Config and bait files are mounted read-only from config/samba.
#
# Versions are pinned. Debian drops superseded security builds from its
# mirrors, so when a build fails on SAMBA_VERSION, look up the current one with
#   docker run --rm debian:<tag> sh -c 'apt-get update -qq; apt-cache policy samba'
FROM debian:bookworm-20260918-slim

ARG SAMBA_VERSION=2:4.17.12+dfsg-0+deb12u4

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      samba=${SAMBA_VERSION} \
      samba-vfs-modules=${SAMBA_VERSION} \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/samba/smb.conf

# Foreground, logs to stdout so Docker -> Alloy -> Loki picks them up.
CMD ["smbd", "--foreground", "--no-process-group", "--debug-stdout"]
