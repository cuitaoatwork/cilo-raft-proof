FROM eclipse-temurin:21-jre
# TLA+ tools v1.8.0 (TLC model checker), pinned by checksum
ADD --checksum=sha256:fc6878c603f0fdc18b9fe3e5bf51860cb90ab5b1154e3c371660c036d6bdd63e \
    https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar /opt/tla2tools.jar
WORKDIR /proof
COPY CiloHA.tla MC.tla Local.cfg LeaderLocal.cfg Barrier.cfg run.sh ./
CMD ["bash", "run.sh"]
