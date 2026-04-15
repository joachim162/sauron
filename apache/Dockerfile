FROM httpd:2.4-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    libapache2-mod-auth-openidc \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Enable required modules by editing httpd.conf
RUN sed -i 's/^#\(LoadModule ssl_module\)/\1/' /usr/local/apache2/conf/httpd.conf && \
    sed -i 's/^#\(LoadModule socache_shmcb_module\)/\1/' /usr/local/apache2/conf/httpd.conf && \
    sed -i 's/^#\(LoadModule rewrite_module\)/\1/' /usr/local/apache2/conf/httpd.conf && \
    sed -i 's/^#\(LoadModule proxy_module\)/\1/' /usr/local/apache2/conf/httpd.conf && \
    sed -i 's/^#\(LoadModule proxy_http_module\)/\1/' /usr/local/apache2/conf/httpd.conf && \
    sed -i 's/^#\(LoadModule headers_module\)/\1/' /usr/local/apache2/conf/httpd.conf && \
    sed -i 's/^#\(Include conf\/extra\/httpd-ssl.conf\)/#\1/' /usr/local/apache2/conf/httpd.conf && \
    sed -i 's/^LoadModule slotmem_shm_module/#\0/' /usr/local/apache2/conf/httpd.conf && \
    echo "LoadModule auth_openidc_module /usr/lib/apache2/modules/mod_auth_openidc.so" >> /usr/local/apache2/conf/httpd.conf

# Create a placeholder config file (will be regenerated at startup)
RUN echo "# Placeholder - will be generated at startup" > /usr/local/apache2/conf/extra/httpd-oidc.conf

COPY apache/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Include our config
RUN echo "Include conf/extra/httpd-oidc.conf" >> /usr/local/apache2/conf/httpd.conf

EXPOSE 80 443

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
