# syntax=docker/dockerfile:1.7

FROM alpine:3.20 AS builder

RUN apk add --no-cache git ca-certificates

RUN --mount=type=secret,id=git_token,required=true \
    test -s /run/secrets/git_token && \
    git config --global user.name "usuario_test" && \
    git config --global user.token "$(cat /run/secrets/git_token)" && \
    test "$(git config --global user.name)" = "usuario_test" && \
    test -n "$(git config --global user.token)" && \
    printf 'Configuração temporária validada no estágio builder.\n' > /tmp/build-ok.txt && \
    rm -f /root/.gitconfig

FROM alpine:3.20 AS final

RUN apk add --no-cache git ca-certificates iputils
COPY --from=builder /tmp/build-ok.txt /opt/build-ok.txt

WORKDIR /workspace
CMD ["sleep", "infinity"]
