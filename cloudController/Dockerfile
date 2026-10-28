# ==============================================================================
# Conexão Povos da Floresta — Cloud Controller Server (Google Cloud Run)
# TP-Link Archer BE220 / BE3600 Pro Cloud Fleet Management
# ==============================================================================
FROM php:8.2-cli-alpine

LABEL maintainer="Conexão Povos da Floresta"
LABEL description="Servidor assíncrono WebSockets / HTTP para Gestão Cloud de Roteadores"

# Instala ca-certificates e tini para gerenciamento limpo de processos
RUN apk add --no-cache ca-certificates tini

WORKDIR /app

# Copia código do servidor e arquivos estáticos
COPY server.php /app/
COPY public/ /app/public/
COPY data/ /app/data/

# Cria diretório de dados persistentes com permissão de escrita
RUN mkdir -p /app/data && chmod -R 777 /app/data

# Porta padrão do Cloud Run (injetada via ENV $PORT em runtime)
ENV PORT=8080
ENV DATA_DIR=/app/data

EXPOSE 8080

# Executa através do tini para garantir tratamento correto de sinais UNIX (SIGTERM, SIGINT)
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["php", "server.php"]
