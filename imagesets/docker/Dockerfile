FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && \
    apt-get upgrade -y && \
    apt-get install -y git pass curl unzip jq yubioath-desktop && \
    curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip && \
    unzip awscliv2.zip && \
    aws/install && \
    apt-get install -y software-properties-common && \
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys CC86BB64 && \
    add-apt-repository ppa:rmescandon/yq && \
    apt update -y && \
    apt install -y yq && \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" >> /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
    apt-get update -y && \
    apt-get install -y google-cloud-sdk && \
    curl https://gist.githubusercontent.com/djmitche/80353576a0f389bf130bcb439f63d070/raw/75d161a3a1cac41247f0f2f19846b6f39b7a314a/signin-aws -o /usr/bin/signin-aws && \
    chmod a+x /usr/bin/signin-aws
