#!/bin/bash
# Stand1 Produções — Setup do servidor VPS
# Execute como root no Ubuntu 22.04 após contratar o VPS
# Uso: bash setup.sh

set -e
DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
  echo "Uso: bash setup.sh projetos.stand1.com.br"
  exit 1
fi

echo "=== [1/6] Atualizando sistema ==="
apt update && apt upgrade -y

echo "=== [2/6] Instalando Docker ==="
apt install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "=== [3/6] Clonando/copiando arquivos Stand1 ==="
mkdir -p /opt/stand1
# Copie manualmente os arquivos para /opt/stand1 via SFTP (FileZilla, WinSCP)
# Estrutura esperada:
#   /opt/stand1/stand1_dashboard.html
#   /opt/stand1/integracao/docker-compose.yml
#   /opt/stand1/integracao/.env
#   /opt/stand1/integracao/bridge/
#   /opt/stand1/integracao/nginx/

echo "=== [4/6] Certificado SSL (Let's Encrypt) ==="
# Emite o certificado ANTES de subir o nginx com SSL
docker run --rm -p 80:80 \
  -v /opt/stand1/integracao/nginx/certbot:/etc/letsencrypt \
  certbot/certbot certonly --standalone \
  --non-interactive --agree-tos \
  --email ti@stand1.com.br \
  -d "$DOMAIN"

echo "=== [5/6] Ajustando nginx.conf com o domínio ==="
sed -i "s/COLOQUE_SEU_DOMINIO_AQUI/$DOMAIN/g" /opt/stand1/integracao/nginx/nginx.conf

echo "=== [6/6] Subindo os containers ==="
cd /opt/stand1/integracao
cp .env.example .env
echo ""
echo ">>> ATENÇÃO: Edite o arquivo /opt/stand1/integracao/.env com suas senhas antes de continuar"
echo ">>> Após editar, execute: docker compose up -d"
echo ""
echo "=== Setup concluído. Próximos passos ==="
echo "1. Editar .env com senhas e chaves"
echo "2. docker compose up -d"
echo "3. Acessar https://$DOMAIN/n8n/ para configurar o n8n"
echo "4. Importar o arquivo n8n_workflow.json no n8n"
echo "5. Na Evolution API (https://$DOMAIN/wpp/) criar instância e conectar WhatsApp"
echo "6. No dashboard, configurar a URL: https://$DOMAIN/api/entradas"
