FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y \
    file findutils grep coreutils git make gcc wget cpanminus \
    postgresql postgresql-client \
    perl libmojolicious-perl libmojolicious-plugin-openapi-perl libopenapi-client-perl libcgi-pm-perl libdbd-pg-perl libdbi-perl \
    libnet-dns-perl libnet-ip-perl libnetaddr-ip-perl \
    libnet-netmask-perl libtext-table-perl \
    libcryptx-perl libjson-perl libjson-maybexs-perl \
    libpath-tiny-perl libpg-perl libparse-recdescent-perl \
    libdate-manip-perl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN cpanm Mojolicious::Plugin::SwaggerUI

# Redocly CLI for OpenAPI spec validation & bundling
RUN apt-get update -qq && apt-get install -y nodejs npm \
    && npm install -g @redocly/cli \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/sauron

COPY . .

RUN ./configure \
    && make install \
    && ln -sf DB-DBI.pm /srv/sauron/Sauron/DB.pm

ENV PERL5LIB=/srv/sauron

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["morbo", "-l", "http://*:3000", "/srv/sauron/sauron_api/script/sauron_api"]
