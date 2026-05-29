FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y \
    file findutils grep coreutils git make gcc wget cpanminus \
    postgresql postgresql-client \
    apache2 \
    perl libcgi-pm-perl libdbd-pg-perl libdbi-perl \
    libnet-dns-perl libnet-ip-perl libnetaddr-ip-perl \
    libnet-netmask-perl libtext-table-perl \
    libcryptx-perl libjson-perl libjson-maybexs-perl \
    libpath-tiny-perl libpg-perl libparse-recdescent-perl \
    libdate-manip-perl libhtml-parser-perl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN a2enmod cgi rewrite && \
    rm -f /usr/lib/cgi-bin/*

WORKDIR /srv/sauron

COPY . .

RUN ./configure && make install && \
    ln -sf DB-DBI.pm /srv/sauron/Sauron/DB.pm

RUN printf "\
SetEnv PERL5LIB /srv/sauron\n\
\n\
Alias /sauron/icons/ /srv/sauron/icons/\n\
ScriptAlias /sauron/ /srv/sauron/cgi/\n\
\n\
<Directory /srv/sauron/cgi>\n\
    Options +ExecCGI\n\
    AddHandler cgi-script .cgi\n\
    Require all granted\n\
</Directory>\n\
\n\
<Directory /srv/sauron/icons>\n\
    Require all granted\n\
</Directory>\n\
" > /etc/apache2/conf-available/sauron.conf && \
    a2enconf sauron

ENV PERL5LIB=/srv/sauron

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 80

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2ctl", "-D", "FOREGROUND"]
