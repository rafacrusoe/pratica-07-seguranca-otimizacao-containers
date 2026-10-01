#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="$ROOT_DIR/evidencias"
TOKEN_FILE="$ROOT_DIR/token.txt"
IMAGE_NAME="imagem-teste-seguro:pratica07"
STACK_NAME="git-stack"
NETWORK_NAME="secure_internal_network"

mkdir -p "$EVIDENCE_DIR"
rm -f "$EVIDENCE_DIR"/*.txt
cd "$ROOT_DIR"

capture() {
  local file="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  } 2>&1 | tee "$EVIDENCE_DIR/$file"
}

cleanup() {
  local exit_code=$?
  docker compose -f docker-compose.network.yml down --remove-orphans >/dev/null 2>&1 || true
  if sudo iptables -C DOCKER-USER -d 172.20.0.0/16 ! -s 172.20.0.0/16 -j DROP >/dev/null 2>&1; then
    sudo iptables -D DOCKER-USER -d 172.20.0.0/16 ! -s 172.20.0.0/16 -j DROP >/dev/null 2>&1 || true
  fi
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
  sleep 3
  docker secret rm git_token >/dev/null 2>&1 || true
  if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
    docker swarm leave --force >/dev/null 2>&1 || true
  fi
  rm -f "$TOKEN_FILE"
  if (( exit_code != 0 )); then
    printf 'A execução terminou com erro. Código: %s\n' "$exit_code" | tee "$EVIDENCE_DIR/erro.txt"
  fi
  exit "$exit_code"
}
trap cleanup EXIT

{
  docker --version
  docker compose version
  git --version
  printf 'buildkit=habilitado\n'
} | tee "$EVIDENCE_DIR/00-versoes.txt"

openssl rand -hex 24 > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
{
  printf 'arquivo=token.txt\n'
  printf 'permissoes='
  stat -c '%a' "$TOKEN_FILE"
  printf 'conteudo_exibido=não\n'
  printf 'uso=secret temporário de build e Docker Secret\n'
} | tee "$EVIDENCE_DIR/01-token-ficticio.txt"

printf 'AÇÃO 1 - MULTI-STAGE BUILD COM SECRET\n' | tee "$EVIDENCE_DIR/02-acao1-inicio.txt"
DOCKER_BUILDKIT=1 docker build \
  --secret id=git_token,src="$TOKEN_FILE" \
  --progress=plain \
  --tag "$IMAGE_NAME" \
  . 2>&1 | tee "$EVIDENCE_DIR/03-docker-build.txt"

capture 04-imagem-final.txt docker image inspect "$IMAGE_NAME" --format 'imagem={{.RepoTags}} id={{.Id}} tamanho={{.Size}} bytes'
capture 05-docker-history.txt docker history --no-trunc "$IMAGE_NAME"

if grep -Fq "$(cat "$TOKEN_FILE")" "$EVIDENCE_DIR/05-docker-history.txt"; then
  printf 'token_exposto=sim\n' | tee "$EVIDENCE_DIR/06-verificacao-token.txt"
  exit 1
else
  {
    printf 'token_exposto=não\n'
    printf 'resultado=O valor do secret não aparece no histórico da imagem final.\n'
    printf 'gitconfig_final='
    docker run --rm "$IMAGE_NAME" sh -lc 'test ! -e /root/.gitconfig && echo ausente'
  } | tee "$EVIDENCE_DIR/06-verificacao-token.txt"
fi

docker run --rm "$IMAGE_NAME" sh -lc \
  'rm -rf /tmp/Hello-World && git clone https://github.com/octocat/Hello-World.git /tmp/Hello-World && test -f /tmp/Hello-World/README && echo clone_publico=sucesso' \
  2>&1 | tee "$EVIDENCE_DIR/07-clone-container.txt"

printf 'AÇÃO 2 - DOCKER SECRET EM SWARM\n' | tee "$EVIDENCE_DIR/08-acao2-inicio.txt"
capture 09-swarm-init.txt docker swarm init
capture 10-secret-create.txt sh -lc "cat '$TOKEN_FILE' | docker secret create git_token -"
capture 11-secret-inspect.txt docker secret inspect git_token --pretty
capture 12-stack-deploy.txt docker stack deploy -c docker-compose.swarm.yml "$STACK_NAME"

service_container_id=""
for _ in $(seq 1 60); do
  service_container_id="$(docker ps -q --filter 'label=com.docker.swarm.service.name=git-stack_git-config' | head -n 1)"
  if [[ -n "$service_container_id" ]] && docker exec "$service_container_id" git --version >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

if [[ -z "$service_container_id" ]]; then
  docker service ps --no-trunc git-stack_git-config | tee "$EVIDENCE_DIR/erro-servico-swarm.txt"
  docker service logs git-stack_git-config | tee "$EVIDENCE_DIR/erro-logs-swarm.txt"
  exit 1
fi

capture 13-service-ps.txt docker service ps git-stack_git-config
{
  printf 'container_id=%s\n' "$service_container_id"
  docker exec "$service_container_id" sh -lc \
    'printf "git_user="; git config --global user.name; test -s /run/secrets/git_token && echo secret_montado=sim; env | grep -q git_token && echo token_no_ambiente=sim || echo token_no_ambiente=não; stat -c "gitconfig_permissoes=%a" "$HOME/.gitconfig"'
} | tee "$EVIDENCE_DIR/14-secret-no-container.txt"

docker exec "$service_container_id" sh -lc \
  'rm -rf /tmp/Hello-World && git clone https://github.com/octocat/Hello-World.git /tmp/Hello-World && test -f /tmp/Hello-World/README && echo clone_com_servico=sucesso' \
  2>&1 | tee "$EVIDENCE_DIR/15-clone-swarm.txt"

capture 16-stack-services.txt docker stack services "$STACK_NAME"
capture 17-stack-rm.txt docker stack rm "$STACK_NAME"
for _ in $(seq 1 30); do
  docker service inspect git-stack_git-config >/dev/null 2>&1 || break
  sleep 1
done
capture 18-secret-rm.txt docker secret rm git_token
capture 19-swarm-leave.txt docker swarm leave --force

printf 'AÇÃO 3 - REDE DOCKER ISOLADA\n' | tee "$EVIDENCE_DIR/20-acao3-inicio.txt"
capture 21-network-create.txt docker network create \
  --driver bridge \
  --internal \
  --subnet 172.20.0.0/16 \
  --gateway 172.20.0.1 \
  "$NETWORK_NAME"

sudo iptables -C DOCKER-USER -d 172.20.0.0/16 ! -s 172.20.0.0/16 -j DROP >/dev/null 2>&1 || \
  sudo iptables -I DOCKER-USER -d 172.20.0.0/16 ! -s 172.20.0.0/16 -j DROP
capture 22-iptables.txt sudo iptables -S DOCKER-USER

capture 23-compose-network-up.txt docker compose -f docker-compose.network.yml up -d
capture 24-containers-rede.txt docker compose -f docker-compose.network.yml ps
capture 25-network-ls.txt docker network ls --filter "name=$NETWORK_NAME"
capture 26-network-inspect.txt docker network inspect "$NETWORK_NAME"

{
  printf '$ docker exec pratica07-authorized-client ping -c 2 secure-app\n'
  docker exec pratica07-authorized-client ping -c 2 secure-app
  printf 'conectividade_autorizada=sucesso\n'
} 2>&1 | tee "$EVIDENCE_DIR/27-conectividade-autorizada.txt"

{
  printf '$ docker run --rm alpine:3.20 ping -c 1 -W 1 secure-app\n'
  if docker run --rm alpine:3.20 ping -c 1 -W 1 secure-app; then
    printf 'isolamento_dns=falhou\n'
    exit 1
  else
    printf 'isolamento_dns=confirmado\n'
    printf 'resultado=Contêiner sem autorização não resolve o alias da rede privada.\n'
  fi
} 2>&1 | tee "$EVIDENCE_DIR/28-bloqueio-nao-autorizado.txt"

{
  printf '$ docker exec pratica07-authorized-client wget -q -T 3 https://example.com\n'
  if docker exec pratica07-authorized-client wget -q -T 3 https://example.com; then
    printf 'acesso_externo=bloqueio_falhou\n'
    exit 1
  else
    printf 'acesso_externo=bloqueado\n'
    printf 'resultado=A rede --internal não possui rota de saída para a internet.\n'
  fi
} 2>&1 | tee "$EVIDENCE_DIR/29-bloqueio-internet.txt"

capture 30-compose-network-down.txt docker compose -f docker-compose.network.yml down --remove-orphans
capture 31-iptables-rm.txt sudo iptables -D DOCKER-USER -d 172.20.0.0/16 ! -s 172.20.0.0/16 -j DROP
capture 32-network-rm.txt docker network rm "$NETWORK_NAME"

{
  printf 'PRÁTICA 07 CONCLUÍDA\n'
  printf 'multi_stage_build=validado\n'
  printf 'secret_no_historico=não_exposto\n'
  printf 'clone_em_container=sucesso\n'
  printf 'docker_secret_swarm=validado\n'
  printf 'token_em_variavel_de_ambiente=não\n'
  printf 'rede_privada=validada\n'
  printf 'comunicacao_autorizada=sucesso\n'
  printf 'acesso_nao_autorizado=bloqueado\n'
  printf 'acesso_externo=bloqueado\n'
  printf 'limpeza_final=concluída\n'
} | tee "$EVIDENCE_DIR/33-resumo.txt"

rm -f "$TOKEN_FILE"
trap - EXIT
