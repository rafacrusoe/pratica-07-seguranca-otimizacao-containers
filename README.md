# Prática 07 - Segurança e otimização em ambientes de contêineres

Este repositório implementa as três ações do roteiro: uso seguro de credencial temporária em Multi-Stage Build, configuração de Docker Secret em Swarm e criação de uma rede Docker isolada.

## Ação 1 - Multi-Stage Build

O `Dockerfile` usa BuildKit e monta o token fictício como secret somente durante uma instrução do estágio `builder`. A configuração temporária é validada e removida antes do fim da camada. A imagem final recebe apenas o arquivo de comprovação, sem copiar o `.gitconfig` nem o secret.

```bash
openssl rand -hex 24 > token.txt
DOCKER_BUILDKIT=1 docker build \
  --secret id=git_token,src=token.txt \
  -t imagem-teste-seguro:pratica07 .
docker history --no-trunc imagem-teste-seguro:pratica07
docker run --rm imagem-teste-seguro:pratica07 \
  git clone https://github.com/octocat/Hello-World.git /tmp/Hello-World
```

O valor do token não é impresso nos logs, não aparece no histórico e não existe na imagem final.

## Ação 2 - Docker Secret

O arquivo `docker-compose.swarm.yml` monta o secret em `/run/secrets/git_token`. O token não é definido como variável de ambiente. O serviço mantém o contêiner ativo para permitir a inspeção e o teste do clone solicitado no roteiro.

```bash
docker swarm init
cat token.txt | docker secret create git_token -
docker stack deploy -c docker-compose.swarm.yml git-stack
docker service ps git-stack_git-config
```

## Ação 3 - Rede isolada

A rede `secure_internal_network` usa o driver bridge, a sub-rede `172.20.0.0/16`, o gateway `172.20.0.1` e a opção `--internal`. Também é aplicada uma regra na cadeia `DOCKER-USER` para bloquear origens externas à sub-rede. O Compose conecta apenas a aplicação e o cliente autorizado.

```bash
docker network create --driver bridge --internal \
  --subnet 172.20.0.0/16 \
  --gateway 172.20.0.1 \
  secure_internal_network
docker compose -f docker-compose.network.yml up -d
docker exec pratica07-authorized-client ping -c 2 secure-app
```

## Execução completa

```bash
chmod +x scripts/run-all.sh
bash scripts/run-all.sh
```

O script automatiza a execução, registra 34 arquivos textuais de evidência e remove stacks, secrets, regras de firewall, contêineres e redes ao final.

## Evidências

O workflow publica o artefato `evidencias-pratica-07` em cada execução. Os arquivos contêm versões, comandos, saídas, inspeções, testes de acesso e o resumo final.
