#
# @id			tests-debian-jessie
# @desc			docker image for testing purposes
# @author 		tupadr3
# @date 		07.12.16
# @version 		1.0.0-SNAPSHOT
#
# Build Instructions: 
# docker build -t tests-debian-jessie .

# base 
FROM debian:jessie

# labels
LABEL version="1.0.0-SNAPSHOT" id="tests-debian-jessie" description="docker image for testing purposes"

# author 
MAINTAINER tupadr3

# deps
RUN echo "===> basics ..." && \  
    apt-get update -y  && \
    apt-get install --no-install-recommends -y openssh-client curl ca-certificates && \
    echo "alias ll='ls $LS_OPTIONS -lha'" >> /root/.bashrc

# user & group
RUN echo "===> app user ..." && \  
    mkdir /data && \
    groupadd -r app -g 1000 && \
    useradd -u 1000 -r -g app -m -d /data/app -s /sbin/nologin -c "app user" app && \
    chmod 755 /data/app

# cleanup
RUN echo "===> housekeeping ..." && \  
    apt-get autoclean -y && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# user & working dir 
WORKDIR /data/app  
USER app

# command.
CMD ["bash"] 